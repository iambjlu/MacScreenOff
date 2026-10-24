import SwiftUI
import ServiceManagement
import CoreGraphics
import IOKit.hid
import IOKit.pwr_mgt

/// 重新啟用顯示器(看門狗與主程式共用)。
func enableDisplays(_ ids: [CGDirectDisplayID]) {
    typealias EnableFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    guard !ids.isEmpty,
          let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSConfigureDisplayEnabled") else { return }
    let enable = unsafeBitCast(sym, to: EnableFn.self)
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { return }
    for id in ids { _ = enable(config, id, true) }
    CGCompleteDisplayConfiguration(config, .forSession)
}

/// 看門狗:獨立行程,盯著主程式 PID;主程式以任何方式結束(含 SIGKILL)就恢復內建面板。
/// 用 `so-watchdog` 這個獨立檔名,避免被 `pkill ScreenOff` 一起殺掉。
func runWatchdogIfRequested() {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--watchdog"), args.count > i + 2,
          let pid = pid_t(args[i + 1]) else { return }
    let ids = args[i + 2].split(separator: ",").compactMap { CGDirectDisplayID($0) }
    while kill(pid, 0) == 0 { sleep(1) }
    enableDisplays(ids)
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 上次被 pkill / 崩潰而沒恢復時,啟動就把記錄中被停用的內建面板重新啟用
        PanelController.shared.restore()
        Task { @MainActor in
            Model.shared.bootstrap()
            Model.shared.applyLaunchBehavior()
        }
        // 由「登入項目」啟動時隱藏視窗(Dock 圖示仍在,點它可再顯示)。
        // 以啟動事件的 'prdt' 屬性是否為 'lgit'(launched as login item)判斷。
        let event = NSAppleEventManager.shared().currentAppleEvent
        if event?.paramDescriptor(forKeyword: 0x70726474)?.enumCodeValue == 0x6C676974 {
            for delay in [0.3, 1.0, 2.5] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { NSApp.hide(nil) } }
        }
        // pkill(SIGTERM)不會呼叫 applicationWillTerminate,所以自己攔截並先恢復螢幕
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { PanelController.shared.restore(); exit(0) }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationWillTerminate(_ notification: Notification) { PanelController.shared.restore() }

    // 關閉視窗不退出:Dock 圖示常駐,面板停用期間監聽仍在執行
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let off = PanelController.shared.isActive
        let item = NSMenuItem(title: off ? "重新開啟螢幕" : "關閉內建螢幕", action: #selector(toggleFromDock), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func toggleFromDock() { Task { @MainActor in Model.shared.toggle() } }
}

/// 讀取選項;尚未設定過時,沿用舊版「自動模式」的值。
private func initialFlag(_ key: String) -> Bool {
    let d = UserDefaults.standard
    return (d.object(forKey: key) as? Bool) ?? d.bool(forKey: "autoMode")
}

/// 開啟 App 時的螢幕狀態。
enum LaunchBehavior: String, CaseIterable, Identifiable {
    case restoreLast, screenOn, screenOff
    var id: String { rawValue }
    var title: String {
        switch self {
        case .restoreLast: "恢復上次退出時的狀態"
        case .screenOn: "開啟螢幕"
        case .screenOff: "關閉螢幕"
        }
    }
}

/// 狀態與動作,視窗、Dock 選單與實體滑鼠偵測共用。
@MainActor
final class Model: ObservableObject {
    static let shared = Model()
    /// 記住最後一次的狀態,供「恢復上次退出時的狀態」使用(退出時雖然會恢復面板,記錄仍保留關閉狀態)。
    @Published var isOff = false { didSet { UserDefaults.standard.set(isOff, forKey: "lastWasOff") } }
    @Published var busy = false
    @Published var message: String?
    /// 實體操作(或手動)恢復螢幕後,在下一次裝置連上 / 移除之前,不會因「斷線」而自動關閉螢幕。
    private var suppressAutoOff = false
    /// 實體滑鼠 / 觸控板從無到有(連線)時是否自動開啟螢幕。
    @Published var onConnectWake = initialFlag("onConnectWake") {
        didSet { UserDefaults.standard.set(onConnectWake, forKey: "onConnectWake"); updateMonitoring() }
    }
    /// 實體滑鼠 / 觸控板全部斷線時是否自動關閉螢幕。
    @Published var offOnDisconnect = initialFlag("offOnDisconnect") {
        didSet { UserDefaults.standard.set(offOnDisconnect, forKey: "offOnDisconnect"); updateMonitoring() }
    }
    @Published var launchBehavior = LaunchBehavior(rawValue: UserDefaults.standard.string(forKey: "launchBehavior") ?? "") ?? .restoreLast {
        didSet { UserDefaults.standard.set(launchBehavior.rawValue, forKey: "launchBehavior") }
    }
    private var syncingLogin = false
    /// 登入時開啟 App(以 SMAppService 註冊登入項目;登入啟動時視窗會隱藏)。
    @Published var launchAtLogin = (SMAppService.mainApp.status == .enabled) {
        didSet {
            guard !syncingLogin, launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                if SMAppService.mainApp.status == .requiresApproval {
                    message = "請到「系統設定 > 一般 > 登入項目與延伸功能」允許 ScreenOff。"
                    SMAppService.openSystemSettingsLoginItems()
                }
            } catch {
                message = "設定登入時開啟失敗:\(error.localizedDescription)"
                syncingLogin = true; launchAtLogin = oldValue; syncingLogin = false
            }
        }
    }

    func toggle() {
        guard !busy else { return }
        message = nil
        if isOff {
            wake()
        } else {
            // 必要條件:能用實體滑鼠 / 觸控板喚醒。監聽啟動失敗就不關螢幕(手動與自動皆同)。
            guard MouseWatcher.shared.start() else {
                message = "無法監聽實體滑鼠 / 觸控板,已取消關閉(否則無法在本機喚醒螢幕)。"
                return
            }
            busy = true
            PanelController.shared.activate { [self] error in
                busy = false
                message = error
                isOff = PanelController.shared.isActive
                if !isOff { MouseWatcher.shared.stop() }
            }
        }
    }

    /// 啟動時依「開啟 App 時」的設定決定螢幕狀態。AppDelegate 已先恢復面板,這裡延遲 2 秒再套用。
    func applyLaunchBehavior() {
        let shouldTurnOff: Bool
        switch launchBehavior {
        case .screenOn: shouldTurnOff = false
        case .screenOff: shouldTurnOff = true
        case .restoreLast: shouldTurnOff = UserDefaults.standard.bool(forKey: "lastWasOff")
        }
        guard shouldTurnOff else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.isOff else { return }
            self.toggle()
        }
    }

    // MARK: 連線偵測:實體滑鼠 / 觸控板連線時開螢幕、全部斷線時關螢幕(給遠端使用)

    private var monitoring = false
    private var armed = false
    private var lastPresent = false

    /// 啟動時依記住的設定開始監控。
    func bootstrap() { updateMonitoring() }

    private func updateMonitoring() {
        if onConnectWake || offOnDisconnect { startMonitoring() } else { stopMonitoring() }
    }

    private func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        armed = false
        suppressAutoOff = false
        PointerPresence.shared.onChange = { [weak self] in Task { @MainActor in self?.presenceChanged() } }
        PointerPresence.shared.start()
        // 啟動初期的裝置列舉事件一律忽略(否則「開啟 App 時關閉螢幕」會被誤判為連線而又開回來);
        // 4 秒後以當時的狀態為基準,只對之後真正的變化(有到無、無到有)反應。
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            Task { @MainActor in
                guard let self, self.monitoring else { return }
                self.lastPresent = PointerPresence.shared.isPresent
                self.armed = true
                // 一個裝置都沒有時不會有連上 / 移除事件,所以依斷線設定評估一次
                if !self.lastPresent { self.turnOffForDisconnect() }
            }
        }
    }

    private func stopMonitoring() {
        monitoring = false
        armed = false
        PointerPresence.shared.stop()
    }

    private func presenceChanged() {
        guard monitoring, armed else { return }
        let present = PointerPresence.shared.isPresent
        guard present != lastPresent else { return }
        lastPresent = present
        suppressAutoOff = false
        if present {
            if onConnectWake { wake() }
        } else {
            turnOffForDisconnect()
        }
    }

    private func turnOffForDisconnect() {
        guard offOnDisconnect, !isOff, !suppressAutoOff else { return }
        toggle()
    }

    /// 還原內建螢幕(視窗、Dock 選單、實體滑鼠皆走這裡)。
    func wake() {
        guard isOff else { return }
        suppressAutoOff = true
        MouseWatcher.shared.stop()
        PanelController.shared.restore()
        isOff = false
    }
}

/// 滑鼠(含 Magic Mouse)與觸控板(含 Magic Trackpad)的 HID 配對條件。
enum PointerDevices {
    static let matching: [[String: Any]] = [
        [kIOHIDDeviceUsagePageKey: Int(kHIDPage_GenericDesktop), kIOHIDDeviceUsageKey: Int(kHIDUsage_GD_Mouse)],
        [kIOHIDDeviceUsagePageKey: Int(kHIDPage_GenericDesktop), kIOHIDDeviceUsageKey: Int(kHIDUsage_GD_Pointer)],
        [kIOHIDDeviceUsagePageKey: Int(kHIDPage_Digitizer), kIOHIDDeviceUsageKey: Int(kHIDUsage_Dig_TouchPad)],
    ]
}

/// 監控實體滑鼠 / 觸控板(藍牙或有線)是否連線:以 HID 裝置的連上 / 移除事件即時偵測。
/// Magic Mouse 2(0x004C/0x0269)、Magic Trackpad 2(0x004C/0x0265)等藍牙裝置連線後都會成為 HID 裝置。
/// 裝置數量變動後延遲 3 秒才通知,避免瞬間斷線造成誤動作。
final class PointerPresence {
    static let shared = PointerPresence()
    private var manager: IOHIDManager?
    private var devices = Set<Int>()
    private var pending: DispatchWorkItem?
    var onChange: (() -> Void)?

    var isPresent: Bool { !devices.isEmpty }

    func start() {
        guard manager == nil else { return }
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(mgr, PointerDevices.matching as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<PointerPresence>.fromOpaque(ctx).takeUnretainedValue().changed(device, added: true)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<PointerPresence>.fromOpaque(ctx).takeUnretainedValue().changed(device, added: false)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr
    }

    func stop() {
        if let mgr = manager {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        devices.removeAll()
        pending?.cancel()
        pending = nil
    }

    private func changed(_ device: IOHIDDevice, added: Bool) {
        let key = Int(bitPattern: Unmanaged.passUnretained(device).toOpaque())
        if added {
            if IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String == "Virtual" { return }
            devices.insert(key)
        } else {
            devices.remove(key)
        }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange?() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}

/// 監聽實體 HID 滑鼠。螢幕共享的遠端操作是系統層級注入的事件,不會經過 HID 裝置,
/// 因此只有真的碰到本機滑鼠時才會觸發。
final class MouseWatcher {
    static let shared = MouseWatcher()
    private var manager: IOHIDManager?
    private var armedAt = Date.distantFuture

    /// grace:啟動後的緩衝秒數,避免按下按鈕時的滑鼠動作立刻觸發還原。
    /// 回傳 false 代表無法監聽實體裝置。此時不應該關閉螢幕,否則無法在本機喚醒。
    @discardableResult
    func start(grace: TimeInterval = 3) -> Bool {
        stop()
        armedAt = Date().addingTimeInterval(grace)
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(mgr, PointerDevices.matching as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(mgr, { ctx, _, sender, value in
            guard let ctx else { return }
            Unmanaged<MouseWatcher>.fromOpaque(ctx).takeUnretainedValue().handle(sender: sender, value: value)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        guard IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            return false
        }
        manager = mgr
        return true
    }

    func stop() {
        if let mgr = manager {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        armedAt = .distantFuture
    }

    private func handle(sender: UnsafeMutableRawPointer?, value: IOHIDValue) {
        guard Date() >= armedAt else { return }
        var isTrackpad = false
        if let sender {
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            if IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String == "Virtual" { return }
            let primaryPage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int
            let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? ""
            isTrackpad = primaryPage == Int(kHIDPage_Digitizer) || product.localizedCaseInsensitiveContains("trackpad")
        }
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element), usage = IOHIDElementGetUsage(element)
        guard IOHIDValueGetIntegerValue(value) != 0 else { return }

        if isTrackpad {
            // 觸控板只在有觸控時才送報告;排除恆為非零的 Scan Time(Digitizer 0x56)
            if page == UInt32(kHIDPage_Digitizer) && usage == 0x56 { return }
        } else {
            let isMotion = page == UInt32(kHIDPage_GenericDesktop)
                && [UInt32(kHIDUsage_GD_X), UInt32(kHIDUsage_GD_Y), UInt32(kHIDUsage_GD_Wheel)].contains(usage)
            let isButton = page == UInt32(kHIDPage_Button)
            guard isMotion || isButton else { return }
        }
        Task { @MainActor in Model.shared.wake() }
    }
}

@main
struct ScreenOffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = Model.shared

    init() { runWatchdogIfRequested() }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: model.isOff ? "display.slash" : "display")
                .font(.system(size: 44))
            Text(model.isOff ? "內建螢幕已關閉" : "內建螢幕開啟中")
                .font(.title3.bold())

            Button(model.isOff ? "重新開啟螢幕" : "關閉內建螢幕") { model.toggle() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(model.busy)

            if let m = model.message {
                Text(m)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                Section {
                    Toggle("連線時自動開啟螢幕", isOn: $model.onConnectWake)
                    Toggle("斷線時自動關閉螢幕", isOn: $model.offOnDisconnect)
                } header: {
                    Text("連線偵測")
                } footer: {
                    Text("依實體滑鼠 / 觸控板(藍牙或有線)的連線狀態自動切換。")
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    Toggle("登入時開啟 App(隱藏視窗)", isOn: $model.launchAtLogin)
                    Picker("開啟 App 時", selection: $model.launchBehavior) {
                        ForEach(LaunchBehavior.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("啟動")
                }
            }
            .formStyle(.grouped)
            .toggleStyle(.switch)
            .scrollDisabled(true)
            .frame(height: 300)

            Text("無論自動或手動關閉,移動實體滑鼠或觸控板都會恢復螢幕;結束 App 也會恢復。運作期間不會自動熄屏。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 400)
    }
}

final class PanelController {
    static let shared = PanelController()

    private typealias EnableFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    private let enableFn: EnableFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSConfigureDisplayEnabled") else { return nil }
        return unsafeBitCast(sym, to: EnableFn.self)
    }()

    private static let savedKey = "disabledBuiltInIDs"
    private var watchdog: Process?
    private var sleepAssertion: IOPMAssertionID = 0

    /// 停用面板期間阻止閒置熄屏(同時也避免系統因閒置而睡眠,遠端才連得上)。
    private func holdAwake() {
        guard sleepAssertion == 0 else { return }
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "ScreenOff: built-in display disabled" as CFString,
                                    &sleepAssertion)
    }

    private func releaseAwake() {
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0 }
    }

    private func startWatchdog(_ ids: [CGDirectDisplayID]) {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/so-watchdog")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return }
        let p = Process()
        p.executableURL = url
        p.arguments = ["--watchdog", String(getpid()), ids.map(String.init).joined(separator: ",")]
        try? p.run()
        watchdog = p
    }
    private var disabledIDs: [CGDirectDisplayID] = []

    var isActive: Bool { !disabledIDs.isEmpty }

    private var builtInDisplays: [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.filter { CGDisplayIsBuiltin($0) != 0 }
    }

    /// 直接停用內建面板,不建立虛擬顯示器。實體滑鼠有動作時由 MouseWatcher 觸發 restore()。
    func activate(completion: @escaping (String?) -> Void) {
        guard let enableFn else { return completion("找不到 CGSConfigureDisplayEnabled,無法停用面板") }
        let builtIns = builtInDisplays
        guard !builtIns.isEmpty else { return completion("找不到內建顯示器") }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return completion("無法開始顯示器設定") }
        for id in builtIns { _ = enableFn(config, id, false) }
        if CGCompleteDisplayConfiguration(config, .forAppOnly) == .success {
            disabledIDs = builtIns
            UserDefaults.standard.set(builtIns.map(Int.init), forKey: Self.savedKey)
            startWatchdog(builtIns)
            holdAwake()
            completion(nil)
        } else {
            CGCancelDisplayConfiguration(config)
            completion("停用內建面板失敗(系統可能不允許停用最後一個顯示器)")
        }
    }

    func restore() {
        let saved = (UserDefaults.standard.array(forKey: Self.savedKey) as? [Int] ?? []).map { CGDirectDisplayID($0) }
        let ids = disabledIDs.isEmpty ? saved : disabledIDs
        if let enableFn, !ids.isEmpty {
            var config: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&config) == .success {
                for id in ids { _ = enableFn(config, id, true) }
                // 用 forSession:被 kill 時不依賴 forAppOnly 的自動還原
                CGCompleteDisplayConfiguration(config, .forSession)
            }
        }
        watchdog?.terminate()
        watchdog = nil
        releaseAwake()
        UserDefaults.standard.removeObject(forKey: Self.savedKey)
        disabledIDs = []
    }
}

