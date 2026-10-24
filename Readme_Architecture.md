# ScreenOff 專案架構

ScreenOff 是一個 macOS SwiftUI App:直接停用內建螢幕面板(面板斷電、省電),同時保留螢幕共享的遠端操作;
實體滑鼠有動作時自動恢復。使用私有 API,僅供自用。

整個專案沒有 Xcode 專案檔,以 `build.sh` 直接呼叫 `swiftc` 編譯並手動打包 `.app`。

## 目錄結構

```
ScreenOffApp.swift     App 本體(全部執行期程式碼)
build.sh               編譯、打包、簽署
make-icon.swift        產生 AppIcon.icns 的腳本
AppIcon.icns           App 圖示(由 make-icon.swift 產生後提交)
README.md              使用說明
Readme_Architecture.md 本文件
CLAUDE.md              專案規則
.gitignore             忽略 .app、暫存建置檔、.DS_Store
```

## ScreenOffApp.swift

單一檔案,由上而下依序為以下區塊。

### enableDisplays(_:)
- 全域函式,看門狗與 `PanelController` 以外的流程共用的「重新啟用顯示器」實作。
- 以 `dlsym(RTLD_DEFAULT, "CGSConfigureDisplayEnabled")` 取得私有函式,`CGBeginDisplayConfiguration` →
  對每個 ID 設為啟用 → `CGCompleteDisplayConfiguration(.forSession)`。
- 找不到符號或 ID 清單為空時直接返回。

### runWatchdogIfRequested()
- 看門狗模式入口,在 `ScreenOffApp.init()` 最先被呼叫。
- 命令列為 `--watchdog <主程式PID> <顯示器ID,以逗號分隔>` 時進入看門狗模式:每秒以 `kill(pid, 0)` 檢查主程式,
  主程式消失(含 SIGKILL / Force Quit)後呼叫 `enableDisplays` 並 `exit(0)`;沒有該參數時直接返回,App 正常啟動。
- 看門狗是 `.app/Contents/MacOS/so-watchdog`(與主程式相同的執行檔副本),
  使用不同檔名,避免被 `pkill ScreenOff` 一併殺掉。

### AppDelegate
- `applicationDidFinishLaunching`:先呼叫 `PanelController.restore()`(依 `UserDefaults` 記錄恢復上次被停用的面板),
  再攔截 SIGTERM / SIGINT / SIGHUP:收到時先 `restore()` 再 `exit(0)`
  (因為 `pkill` 的 SIGTERM 不會觸發 `applicationWillTerminate`)。
- `applicationWillTerminate`:呼叫 `restore()`。
- `applicationShouldTerminateAfterLastWindowClosed` 回傳 `false`:關閉視窗不退出,Dock 圖示與滑鼠監聽常駐。
- `applicationDockMenu`:Dock 右鍵選單,單一項目依 `PanelController.isActive` 顯示「關閉內建螢幕 / 重新開啟螢幕」,
  觸發 `Model.shared.toggle()`。

### Model(`@MainActor`,`ObservableObject`,單例 `Model.shared`)
- UI 狀態:`isOff`、`busy`、`message`。
- `toggle()`:`busy` 時忽略;目前為關閉狀態則走 `wake()`;否則呼叫 `PanelController.activate`,
  成功後 `isOff = true` 並啟動 `MouseWatcher`,失敗則把錯誤訊息放進 `message`。
- `wake()`:停止 `MouseWatcher`、呼叫 `PanelController.restore()`、`isOff = false`。
  視窗按鈕、Dock 選單、實體滑鼠偵測都走這裡。

### MouseWatcher(單例)
- 以 `IOHIDManager` 配對三種裝置並註冊 input value callback,掛在主 run loop:GenericDesktop/Mouse、
  GenericDesktop/Pointer、Digitizer/TouchPad(涵蓋 Magic Mouse 與 Magic Trackpad)。
- 只有「實體」HID 裝置會產生事件;螢幕共享是系統層級注入的事件,不經過 HID 裝置,因此不會誤觸發。
  另外過濾 `kIOHIDTransportKey == "Virtual"` 的裝置。
- 裝置分兩類:主要 usage page 為 Digitizer、或產品名稱含 "trackpad" 的視為觸控板,其餘視為滑鼠。
- 滑鼠的有效事件:X / Y / 滾輪非零位移,或任一按鈕按下。
- 觸控板的有效事件:任何非零的輸入值(觸控板只在有觸控時才送報告),但排除恆為非零的 Digitizer Scan Time(0x56)。
- 觸發後以 `Task { @MainActor }` 呼叫 `Model.shared.wake()`。
- `start(grace: 3)`:啟動後 3 秒內忽略事件,避免按下按鈕時的滑鼠動作立刻觸發還原。`stop()` 關閉並重置。
- 可能需要「輸入監控」權限。

### ScreenOffApp 與 ContentView
- `ScreenOffApp`(`@main`):`init()` 先跑 `runWatchdogIfRequested()`;場景為 `WindowGroup`(固定內容大小視窗),
  不再使用選單列項目。以 `@NSApplicationDelegateAdaptor` 掛上 `AppDelegate`。
- `ContentView`:顯示狀態圖示(`display` / `display.slash`)、狀態文字、切換按鈕(忙碌時停用)、錯誤訊息與操作提示。

### PanelController(單例)
- 停用 / 恢復內建面板的核心,不建立虛擬顯示器。
- `activate(completion:)`:取得 `CGDisplayIsBuiltin` 的作用中顯示器 → `CGSConfigureDisplayEnabled(false)` →
  `CGCompleteDisplayConfiguration(.forAppOnly)`。成功時:記錄 `disabledIDs`、把 ID 存進 `UserDefaults`
  (key `disabledBuiltInIDs`)、啟動看門狗、`holdAwake()`;失敗(例如系統不允許停用最後一個顯示器)則取消設定並回報錯誤。
- `restore()`:ID 取自 `disabledIDs`,為空時改讀 `UserDefaults`;以 `.forSession` 重新啟用,
  再終止看門狗、`releaseAwake()`、清除記錄。可重複呼叫。
- `holdAwake()` / `releaseAwake()`:停用面板期間持有 `IOPMAssertion`(`PreventUserIdleDisplaySleep`),
  阻止閒置熄屏,同時避免系統因閒置睡眠;恢復時釋放。
- `startWatchdog(_:)`:以 `Process` 啟動 `so-watchdog`,傳入自己的 PID 與被停用的 ID;找不到執行檔時略過。
- `isActive`:`disabledIDs` 是否非空。

## build.sh
1. 清掉舊 `ScreenOff.app`,建立 `Contents/MacOS` 與 `Contents/Resources`。
2. 對 arm64 與 x86_64 各跑一次 `swiftc`(部署目標 macOS 13.0,`-parse-as-library -O`),以 `lipo` 合併為 universal。
3. 把主程式複製為 `so-watchdog`,複製 `AppIcon.icns` 到 `Resources`。
4. 寫入 `Info.plist`:`CFBundleIdentifier = local.screenoff`、`CFBundleIconFile = AppIcon`、
   `LSMinimumSystemVersion = 13.0`;沒有 `LSUIElement`,所以有 Dock 圖示。
5. `codesign --force --deep --sign -`(ad-hoc,`--deep` 讓 `so-watchdog` 一併簽署)。
- 已知:同一個 `swiftc` 指令帶了兩個 `-target`(先 arm64-macosx13.0,再 `$ARCH-apple-macos13.0`),後者生效,不影響結果。
- 每次重新編譯 ad-hoc 簽章都會改變,「輸入監控」授權可能需要重新給。

## make-icon.swift
- 以 AppKit 繪製 1024 規格的圖示:824/1024 的圓角方塊、深藍到紫的漸層、SF Symbol `display` 染成白色、右下角紅色電源鈕。
- 輸出 `AppIcon.iconset`(16 到 512,含 @2x),再用 `iconutil -c icns AppIcon.iconset -o AppIcon.icns` 轉成圖示檔。

## 執行流程摘要
1. 啟動 → `runWatchdogIfRequested()`(非看門狗模式直接返回)→ `AppDelegate` 啟動時先 `restore()`、安裝訊號攔截。
2. 按「關閉內建螢幕」→ `Model.toggle()` → `PanelController.activate` 停用面板、啟動看門狗、持有防熄屏斷言
   → 成功後 `MouseWatcher.start()`。
3. 實體滑鼠有動作 → `Model.wake()` → 停止監聽、`restore()`(重新啟用面板、終止看門狗、釋放斷言)。
4. 主程式被 Force Quit / `kill -9` → 看門狗偵測到 PID 消失,重新啟用面板。
5. 下次啟動 → `restore()` 依 `UserDefaults` 記錄再恢復一次(保險)。
