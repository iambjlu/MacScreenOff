# ScreenOff 專案架構

ScreenOff 是一個 macOS SwiftUI App:直接停用選定的螢幕(預設是內建螢幕面板;面板斷電、省電),同時保留螢幕共享的遠端操作;
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
- 啟動時呼叫 `Model.bootstrap()`(連線偵測監控)與 `Model.applyLaunchBehavior()`(「開啟 App 時」的設定)。
- 由登入項目啟動時隱藏視窗:檢查啟動 Apple Event 的 `prdt` 屬性是否為 `lgit`,是就在 0.3 / 1.0 / 2.5 秒各呼叫一次
  `NSApp.hide(nil)`(Dock 圖示仍在,點擊可再顯示)。此判斷依賴系統的啟動事件,尚未在實機驗證。
- `applicationWillTerminate`:呼叫 `restore()`。
- `applicationShouldTerminateAfterLastWindowClosed` 回傳 `false`:關閉視窗不退出,Dock 圖示與滑鼠監聽常駐。
- `applicationDockMenu`:Dock 右鍵選單,單一項目依 `PanelController.isActive` 顯示「關閉選定的螢幕 / 重新開啟螢幕」,
  觸發 `Model.shared.toggle()`。

### Model(`@MainActor`,`ObservableObject`,單例 `Model.shared`)
- UI 狀態:`isOff`、`busy`、`message`。
- `toggle()`:`busy` 時忽略;目前為關閉狀態則走 `wake()`;否則先 `MouseWatcher.start()`
  (「能用實體滑鼠 / 觸控板喚醒」是必要條件(`keepOffOnInput` 開啟時除外),手動、連線偵測與開啟 App 時的設定都一樣;失敗就把原因放進 `message` 並取消),
  再呼叫 `PanelController.activate`;成功後 `isOff = true`,失敗則停止 `MouseWatcher` 並顯示錯誤訊息。
- 連線偵測(給遠端使用的情境)由兩個獨立選項控制,任一開啟就會啟動 `PointerPresence` 監控,兩者都關閉就停止:
  - `onConnectWake`(`UserDefaults` 的 `onConnectWake`,視窗「連線時自動開啟螢幕」):實體滑鼠 / 觸控板從無到有時 `wake()`。
    把它從開啟切到關閉時不會直接生效:`ContentView` 以自訂 `Binding` 攔截,先設 `confirmDisableConnectWake = true`
    跳出確認對話框,按「關閉」才真的寫入 `false`,「取消」維持開啟(從關閉切到開啟不需要確認)。
  - `offOnDisconnect`(`UserDefaults` 的 `offOnDisconnect`,視窗「斷線時自動關閉螢幕」):全部斷線時 `toggle()` 關閉螢幕。
  - 兩者尚未設定過時沿用舊版 `autoMode` 的值(`initialFlag`),預設都是關閉。
- 只對「真正的狀態變化」反應:`startMonitoring()` 先忽略啟動初期的裝置列舉事件,4 秒後記下當時是否有裝置(`lastPresent`)並開始處理事件;
  `presenceChanged()` 只在有 / 無狀態與 `lastPresent` 不同時才動作。這避免「開啟 App 時關閉螢幕」被誤判為連線而又開回來。
  一個裝置都沒有時不會有事件,所以 4 秒時若沒有裝置就依 `offOnDisconnect` 評估一次。
- `suppressAutoOff`:`wake()` 成功時設為 true(實體滑鼠 / 觸控板操作、手動按鈕都算),斷線關閉在它為 true 時不動作,
  直到下一次有 / 無狀態變化才清除,避免「有人實際操作但系統判定沒有裝置」時來回開關。
- `keepOffOnInput`(`UserDefaults` 的 `keepOffOnInput`,預設關閉,視窗「滑鼠移動或連線時也不開啟螢幕」):開啟後
  實體操作不會觸發還原(`MouseWatcher` 改呼叫 `wakeByInput()`,它在此選項開啟時直接返回)、連線也不會 `wake()`
  (`presenceChanged()` 檢查),且 `toggle()` 不再要求 `MouseWatcher.start()` 成功。這是刻意放寬「必須能用實體裝置喚醒」的選項,
  所以開啟(關閉到開啟)必須通過 `KeepOffConfirmView` 的三步確認 sheet(`showKeepOffConfirm`),任一步可取消;
  關閉(開啟到關閉)直接生效,並且若此時 `isOff` 為 true,會立刻 `MouseWatcher.start()` 接回本機喚醒,失敗則顯示訊息。
  - 安全閥:`toggle()` 成功關閉螢幕時記下 `hadOtherDisplayAtOff = !activeDisplayIDs().isEmpty`(還有沒被關閉的其他螢幕)。
    `displaysChanged()` 在 `isOff`、`keepOffOnInput`、`hadOtherDisplayAtOff` 都成立、但作用中的顯示器已經一個都不剩時,
    顯示「其餘螢幕已移除,已恢復被關閉的螢幕」並 `wake()`,避免變成沒有任何螢幕。選項沒開、或關螢幕時本來就沒有其他螢幕,都不會觸發。
    已知風險:螢幕共享期間系統若建立虛擬顯示器,可能被當成其他螢幕。
- 要關閉的螢幕:`selectedDisplays`(以顯示器 UUID 記憶,存於 `UserDefaults` 的 `selectedDisplays`;尚未設定過時預設為內建螢幕)。
  UUID 取自 `CGDisplayCreateUUIDFromDisplayID`,因為 `CGDirectDisplayID` 在重新連接或重開機後可能改變。
  - `targetDisplayIDs()`:目前作用中、且 UUID 在選定集合內的顯示器 ID;`toggle()` 關閉時使用,結果為空就不關閉並顯示原因
    (沒有選擇任何螢幕 / 選定的螢幕目前沒有連接)。手動按鈕、「斷線時自動關閉螢幕」、「開啟 App 時」、「外接顯示器連接時」都走 `toggle()`,
    所以全部套用同一份選擇。
  - `refreshDisplays()`:重建視窗列表 `displays`(`DisplayInfo`):作用中的螢幕,加上選定但目前未啟用(已被關閉或沒連接)的螢幕。
    名稱(`NSScreen.localizedName`)與是否內建會記在 `UserDefaults`(`displayNames`、`displayBuiltin`),因為被關閉的螢幕查不到名稱。
    在 `bootstrap()`、視窗出現、`displaysChanged()`、關閉流程完成時呼叫。
  - `setSelected(_:_:)`:更改選擇並存檔。視窗在螢幕關閉期間停用這些開關,避免「關了 A,卻把選擇改成 B」造成記錄不一致。
- `closeSelectedWithExternal`(`UserDefaults` 的 key 仍是 `closeBuiltInWithExternal`,沿用舊設定;預設關閉,視窗「外接顯示器」區的開關
  「外接顯示器連接時,關閉選定的螢幕」):接上外接顯示器時自動關閉選定的螢幕,移除時自動恢復。
  - `displaysChanged()`(由 `DisplayWatcher` 在顯示器組態變動後呼叫)比較 `activeExternalDisplayExists()` 與上次的 `lastExternal`,
    只對外接顯示器的有 / 無「變化」反應:從無到有 → `closeForExternal()`;從有到無且 `isOff && closedForExternal` → `wake()`。
    不能在每次組態變動都檢查,否則手動喚醒螢幕後會立刻又被關掉。
  - `applyExternalRuleNow()`:狀態式的一次處理,在選項從關到開時、以及 `bootstrap()` 啟動 3 秒後(外接顯示器已連著、
    讓「開啟 App 時」的設定先套用)呼叫;因此「開啟 App 時 = 開啟螢幕」遇到已連接的外接顯示器仍會被這個選項關閉。
  - `closeForExternal()`:設 `closedForExternal = true` 後呼叫 `toggle()`(與手動關閉相同,仍要求 `MouseWatcher` 可啟動,
    除非 `keepOffOnInput` 開啟);關閉失敗就清掉旗標。`closedForExternal` 記錄「是這個選項關的」,任何 `wake()` 都會清除,
    所以手動關閉的螢幕不會在外接顯示器移除時被自動開回來。關閉選項時只清旗標,不改變目前的螢幕狀態。
- `isOff` 每次變動都寫入 `UserDefaults` 的 `lastWasOff`;結束 App 時面板雖會被恢復,但這個記錄不會被清掉,
  供「恢復上次退出時的狀態」使用。
- `launchBehavior`(`LaunchBehavior`:`restoreLast` / `screenOn` / `screenOff`,存於 `UserDefaults` 的 `launchBehavior`,
  預設 `restoreLast`)與 `applyLaunchBehavior()`:啟動時 `AppDelegate` 先恢復面板,再依設定決定是否在 2 秒後呼叫 `toggle()` 關閉螢幕
  (`restoreLast` 讀 `lastWasOff`;`screenOn` 不動作;`screenOff` 一定關閉)。關閉仍走 `toggle()`,所以同樣受「必須能用實體裝置喚醒」限制。
- `launchAtLogin`:以 `SMAppService.mainApp` 註冊 / 取消登入項目。狀態為 `requiresApproval` 時顯示提示並開啟系統設定的登入項目頁;
  失敗時顯示錯誤並還原開關(用 `syncingLogin` 避免 `didSet` 遞迴)。
- `wake()`:停止 `MouseWatcher`、呼叫 `PanelController.restore()`、`isOff = false`。
  視窗按鈕、Dock 選單、實體滑鼠偵測都走這裡。

### PointerDevices 與 PointerPresence
- `PointerDevices.matching`:HID 配對條件(GenericDesktop/Mouse、GenericDesktop/Pointer、Digitizer/TouchPad),
  `MouseWatcher` 與 `PointerPresence` 共用。
- `PointerPresence`(單例):以 `IOHIDManager` 的 device matching / removal callback 即時追蹤實體指標裝置是否連線
  (Magic Mouse 2 的 0x004C/0x0269、Magic Trackpad 2 的 0x004C/0x0265 等藍牙裝置連線後都會成為 HID 裝置;有線裝置同樣算)。
  `Virtual` 傳輸的裝置不計。`isPresent` 表示目前是否至少有一個裝置;裝置數量變動後延遲 3 秒才呼叫 `onChange`,
  避免瞬間斷線誤動作。`start()` / `stop()` 負責建立與釋放監控。

### 顯示器輔助函式與 DisplayWatcher
- `activeDisplayIDs()`:`CGGetActiveDisplayList` 的結果(已被停用的顯示器不在其中)。
- `activeExternalDisplayExists()`:作用中顯示器是否有 `CGDisplayIsBuiltin == 0` 的。
- `displayUUID(_:)` / `displayName(_:)`:穩定識別(`CGDisplayCreateUUIDFromDisplayID`)與顯示名稱(`NSScreen.localizedName`,
  查不到時用「顯示器 <ID>」);`DisplayInfo`:視窗列表的一筆資料(uuid、名稱、是否內建、是否作用中)。
- `DisplayWatcher.start()`:註冊 `CGDisplayRegisterReconfigurationCallback`,組態變動結束後(略過 `beginConfigurationFlag`)
  延遲 1.5 秒呼叫 `Model.displaysChanged()`;`AppDelegate` 啟動時呼叫一次。

### MouseWatcher(單例)
- 以 `IOHIDManager` 依 `PointerDevices.matching` 配對裝置(涵蓋 Magic Mouse 與 Magic Trackpad)
  並註冊 input value callback,掛在主 run loop。
- 只有「實體」HID 裝置會產生事件;螢幕共享是系統層級注入的事件,不經過 HID 裝置,因此不會誤觸發。
  另外過濾 `kIOHIDTransportKey == "Virtual"` 的裝置。
- 裝置分兩類:主要 usage page 為 Digitizer、或產品名稱含 "trackpad" 的視為觸控板,其餘視為滑鼠。
- 滑鼠的有效事件:X / Y / 滾輪非零位移,或任一按鈕按下。
- 觸控板的有效事件:任何非零的輸入值(觸控板只在有觸控時才送報告),但排除恆為非零的 Digitizer Scan Time(0x56)。
- 觸發後以 `Task { @MainActor }` 呼叫 `Model.shared.wakeByInput()`(`keepOffOnInput` 開啟時忽略)。
- `start(grace: 3) -> Bool`:`IOHIDManagerOpen` 失敗時回傳 false;成功後 3 秒內忽略事件,
  避免按下按鈕時的滑鼠動作立刻觸發還原。`stop()` 關閉並重置。不需要「輸入監控」授權。
- 回傳 false 時 `Model.toggle()` 不會關閉螢幕,確保任何關閉方式都能由實體裝置恢復。

### ScreenOffApp 與 ContentView
- `ScreenOffApp`(`@main`):`init()` 先跑 `runWatchdogIfRequested()`;場景為 `WindowGroup`(固定內容大小視窗),
  不再使用選單列項目。以 `@NSApplicationDelegateAdaptor` 掛上 `AppDelegate`。
- `ContentView`:上方是狀態圖示(`display` / `display.slash`)、狀態文字、切換按鈕(忙碌時停用)與錯誤訊息;
  下方是分組列表(`Form` + `.formStyle(.grouped)` + `.toggleStyle(.switch)`):「要關閉的螢幕」區為每個螢幕一個開關(`Model.displays`,螢幕關閉期間停用),「連線偵測」區有「連線時自動開啟螢幕」、「斷線時自動關閉螢幕」與「滑鼠移動或連線時也不開啟螢幕」(後者啟用時彈出三步確認的 `KeepOffConfirmView`),「外接顯示器」區有「外接顯示器連接時,關閉選定的螢幕」開關,「啟動」區有「登入時開啟 App(隱藏視窗)」開關與「開啟 App 時」選單。
  說明文字都加上 `fixedSize(horizontal: false, vertical: true)` 以換行顯示,避免被截成「…」;視窗寬 400,列表固定高 380(內容多時可捲動),列表出現時重新整理螢幕清單。

### PanelController(單例)
- 停用 / 恢復指定顯示器的核心(預設是內建面板),不建立虛擬顯示器。
- `activate(targets:completion:)`:對傳入的顯示器 ID(由 `Model.targetDisplayIDs()` 決定)呼叫 `CGSConfigureDisplayEnabled(false)` →
  `CGCompleteDisplayConfiguration(.forAppOnly)`;清單為空就回報「找不到要關閉的螢幕」。成功時:記錄 `disabledIDs`、把 ID 存進
  `UserDefaults`(key 仍叫 `disabledBuiltInIDs`,以便舊版殘留的記錄也能在啟動時恢復)、啟動看門狗、`holdAwake()`;
  失敗(例如系統不允許停用最後一個顯示器)則取消設定並回報錯誤。
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

## make-icon.swift
- 以 AppKit 繪製 1024 規格的圖示:824/1024 的圓角方塊、深藍到紫的漸層、SF Symbol `display` 染成白色、右下角紅色電源鈕。
- 輸出 `AppIcon.iconset`(16 到 512,含 @2x),再用 `iconutil -c icns AppIcon.iconset -o AppIcon.icns` 轉成圖示檔。

## 執行流程摘要
1. 啟動 → `runWatchdogIfRequested()`(非看門狗模式直接返回)→ `AppDelegate` 啟動時先 `restore()`、安裝訊號攔截。
2. 按「關閉選定的螢幕」(或「斷線時自動關閉螢幕」偵測到裝置全部斷線)→ `Model.toggle()` → `MouseWatcher.start()`
   (失敗則取消)→ `PanelController.activate` 停用面板、啟動看門狗、持有防熄屏斷言。
3. 實體滑鼠 / 觸控板有動作(或「連線時自動開啟螢幕」偵測到裝置連線)→ `Model.wake()` → 停止監聽、`restore()`(重新啟用面板、終止看門狗、釋放斷言)。
4. 主程式被 Force Quit / `kill -9` → 看門狗偵測到 PID 消失,重新啟用面板。
5. 下次啟動 → `restore()` 依 `UserDefaults` 記錄再恢復一次(保險)。
6. `keepOffOnInput` 開啟時,實體操作與裝置連線都不會觸發 `wake()`;能恢復的只剩視窗 / Dock 的按鈕、結束 App、
   看門狗與下次啟動時的 `restore()`;另外,關螢幕時若還有其他螢幕、而它們之後全被移除,`displaysChanged()` 會自動恢復被關閉的螢幕。
7. 「外接顯示器連接時,關閉選定的螢幕」開啟時:外接顯示器連上(或啟動 / 開啟選項時已連著)→ `closeForExternal()` → `toggle()` 關閉選定的螢幕;
   外接顯示器移除且螢幕是被這個選項關閉的 → `wake()` 恢復。
