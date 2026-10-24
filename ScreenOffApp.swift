import SwiftUI
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
        Task { @MainActor in Model.shared.bootstrap() }
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

/// 狀態與動作,視窗、Dock 選單與實體滑鼠偵測共用。
@MainActor
final class Model: ObservableObject {
    static let shared = Model()
    @Published var isOff = false
    @Published var busy = false
    @Published var message: String?
    /// 實體操作(或手動)恢復螢幕後,在下一次裝置連上 / 移除事件之前,自動模式不再關閉螢幕。
    private var suppressAutoOff = false
    @Published var autoMode = UserDefaults.standard.bool(forKey: "autoMode") {
        didSet {
            UserDefaults.standard.set(autoMode, forKey: "autoMode")
            if autoMode { startAuto() } else { PointerPresence.shared.stop() }
        }
    }

    func toggle() {
        guard !busy else { return }
        message = nil
        if isOff {
            wake()
        } else {
            busy = true
            PanelController.shared.activate { [self] error in
                busy = false
                message = error
                isOff = PanelController.shared.isActive
                if isOff { MouseWatcher.shared.start() }
            }
        }
    }

    // MARK: 自動模式:有實體滑鼠 / 觸控板連線就開螢幕,沒有就關螢幕(給遠端使用)

    /// 啟動時依記住的設定開始監控。
    func bootstrap() { if autoMode { startAuto() } }

    private func startAuto() {
        PointerPresence.shared.onChange = { [weak self] in
            Task { @MainActor in self?.suppressAutoOff = false; self?.applyAuto() }
        }
        suppressAutoOff = false
        PointerPresence.shared.start()
        // 一個裝置都沒有時不會有連上事件,所以主動評估一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            Task { @MainActor in self?.applyAuto() }
        }
    }

    private func applyAuto() {
        guard autoMode, !busy else { return }
        if PointerPresence.shared.isPresent { wake() } else if !isOff && !suppressAutoOff { toggle() }
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
/// 因此只有真的碰到本機滑鼠時才會觸發。(可能需要「輸入監控」權限)
final class MouseWatcher {
    static let shared = MouseWatcher()
    private var manager: IOHIDManager?
    private var armedAt = Date.distantFuture

    /// grace:啟動後的緩衝秒數,避免按下按鈕時的滑鼠動作立刻觸發還原。
    func start(grace: TimeInterval = 3) {
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
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr
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
        VStack(spacing: 14) {
            Image(systemName: model.isOff ? "display.slash" : "display")
                .font(.system(size: 44))
            Text(model.isOff ? "內建螢幕已關閉" : "內建螢幕開啟中")
                .font(.title3.bold())

            Button(model.isOff ? "重新開啟螢幕" : "關閉內建螢幕") { model.toggle() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(model.busy)

            Toggle("自動模式", isOn: $model.autoMode)
            Text("沒有滑鼠 / 觸控板連線時自動關閉螢幕,連線時自動開啟。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let m = model.message { Text(m).font(.caption).foregroundStyle(.red) }
            Text("運作期間不會自動熄屏。\n移動實體滑鼠即可恢復螢幕;結束 App 也會恢復。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(width: 320)
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

