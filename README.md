# ScreenOff

用 SwiftUI 寫的 macOS 小工具:**直接停用 iMac 的內建螢幕面板(面板斷電、省電)**,同時保留螢幕共享的遠端操作。
移動實體滑鼠時自動恢復螢幕。

> ⚠️ 這個專案使用 **私有 API**(`CGSConfigureDisplayEnabled`),適合自用
> 也不保證在每個 macOS 版本上都有效。使用前請務必在 Mac 前面親自測試。
> 尚未在實機驗證觸控板和滑鼠的偵測,但已實測可以關閉和開啟顯示器。

## 運作方式

| 元件 | 說明 |
| --- | --- |
| `PanelController` | 呼叫 `CGSConfigureDisplayEnabled` 停用內建面板,並以 `IOPMAssertion` 阻止閒置熄屏 |
| `MouseWatcher` | 用 `IOHIDManager` 監聽**實體** HID 滑鼠與觸控板(含 Magic Mouse / Magic Trackpad),有動作就恢復螢幕(遠端注入的事件不經過 HID 裝置,不會誤觸發) |
| `PointerPresence` | 即時追蹤實體滑鼠 / 觸控板(藍牙或有線)是否連線,供自動模式使用 |
| 看門狗 `so-watchdog` | `.app` 內的獨立行程,盯著主程式 PID;主程式以任何方式結束(包含 Force Quit / `kill -9`)都會把面板重新啟用 |
| 啟動自救 | 停用的顯示器 ID 會存進 `UserDefaults`,下次啟動時先重新啟用 |

為什麼不用 `pmset displaysleepnow`?顯示器睡眠後 WindowServer 不再繪製畫面,螢幕共享會變黑、無法操作。

## 需求

- macOS 13 以上(arm64 / x86_64 universal)
- Xcode Command Line Tools(需要 `swiftc`、`iconutil`、`codesign`)

## 建置與執行

```sh
./build.sh
open ScreenOff.app
```

`build.sh` 會編譯 arm64 與 x86_64、合併為 universal、複製看門狗執行檔、放入圖示,並以 ad-hoc 簽署。

## 使用

1. 開啟 App,按「關閉內建螢幕」(或在 Dock 圖示上按右鍵選同樣的項目)。
   也可以勾選「自動模式」(給遠端使用):實體滑鼠 / 觸控板連線時自動開啟螢幕;
   「斷線時自動關閉螢幕」可另外選擇開或關(預設開)。
   即使系統沒偵測到連線,只要有實體滑鼠 / 觸控板的操作,也會開啟(之後要等下一次裝置連上或移除才會再自動關閉)。
   無論自動或手動關閉,都必須能用實體滑鼠 / 觸控板恢復,所以關閉前會先確認實體裝置監聽可以啟動,失敗就不會關閉。
2. 面板關閉後,仍可由螢幕共享連線操作。運作期間不會自動熄屏。
3. 移動實體滑鼠即可恢復;也可從遠端按「重新開啟螢幕」,或結束 App。
4. 關閉視窗不會退出 App,Dock 圖示會常駐。
5. 從 Dock 結束 App 會恢復螢幕。

## 緊急恢復

- 動一下實體滑鼠。
- 從遠端或 SSH:`pkill ScreenOff`(會先恢復螢幕再結束),或直接 Force Quit,看門狗會在約 1 秒內恢復。
- 重新開啟 App(啟動時會恢復上次被停用的面板)。
- 最後手段:重新開機。

## 已知限制

- macOS 可能拒絕停用最後一個顯示器;失敗時 App 會顯示錯誤訊息,螢幕維持不變。
- 面板停用後沒有螢幕,選單列與 Dock 都看不到,因此恢復只能靠實體滑鼠、遠端操作或結束 App。
- 觸控板的偵測依賴其 HID 回報格式,尚未在實機驗證;若觸控板沒有反應,請先改用滑鼠並告知。

## 檔案

```
ScreenOffApp.swift   App 本體(UI、PanelController、MouseWatcher、看門狗)
build.sh             編譯、打包、簽署
make-icon.swift      產生 AppIcon.icns 的腳本
AppIcon.icns         App 圖示
Readme_Architecture.md  專案架構說明(逐檔案)
CLAUDE.md            專案規則
```

重新產生圖示:

```sh
swiftc make-icon.swift -o /tmp/make-icon && /tmp/make-icon && iconutil -c icns AppIcon.iconset -o AppIcon.icns
```
