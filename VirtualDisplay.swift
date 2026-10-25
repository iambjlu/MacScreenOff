import SwiftUI
import CoreGraphics

/// 一個解析度選項。`ppi >= 200` 視為 Retina(HiDPI)。
struct ResolutionOption: Identifiable {
    let title: String
    let width: Int
    let height: Int
    let ppi: Double
    var id: String { "\(width)x\(height)@\(Int(ppi))" }
    var isRetina: Bool { ppi >= 200 }
}

/// 一種長寬比與其支援的解析度。
struct AspectGroup: Identifiable {
    let name: String
    let retina: [ResolutionOption]
    let standard: [ResolutionOption]
    var id: String { name }
}

enum ResolutionCatalog {
    private static let retinaTitles = ["Retina 2K", "Retina 3K", "Retina 4K", "Retina 5K", "Retina 8K"]
    private static let retinaWidths = [2880, 3360, 3840, 5120, 7680]
    private static let standardWidths = [960, 1280, 1440, 1680, 1920, 2560, 3200, 3840, 5120, 7680]
    private static let suffixesWide: [Int: String] = [1920: "HD", 2560: "2K", 3840: "4K", 5120: "5K", 7680: "8K"]
    private static let suffixes43: [Int: String] = [5120: "5K", 7680: "8K"]

    private static func group(_ name: String, retina: [Int], standard: [Int],
                              suffixes: [Int: String] = [:]) -> AspectGroup {
        AspectGroup(
            name: name,
            retina: zip(zip(retinaTitles, retinaWidths), retina).map { pair, h in
                ResolutionOption(title: pair.0, width: pair.1, height: h, ppi: 255)
            },
            standard: zip(standardWidths, standard).map { w, h in
                ResolutionOption(title: "\(w)×\(h)" + (suffixes[w].map { " \($0)" } ?? ""),
                                 width: w, height: h, ppi: 105)
            })
    }

    static let groups: [AspectGroup] = [
        group("16:9", retina: [1620, 1890, 2160, 2880, 4320],
              standard: [540, 720, 810, 945, 1080, 1440, 1800, 2160, 2880, 4320], suffixes: suffixesWide),
        group("16:10", retina: [1800, 2100, 2400, 3200, 4800],
              standard: [600, 800, 900, 1050, 1200, 1600, 2000, 2400, 3200, 4800], suffixes: suffixesWide),
        group("4:3", retina: [2160, 2520, 2880, 3840, 5760],
              standard: [720, 960, 1080, 1260, 1440, 1920, 2400, 2880, 3840, 5760], suffixes: suffixes43),
        group("21:9 (UltraWide)", retina: [1234, 1440, 1646, 2194, 3292],
              standard: [412, 548, 618, 720, 822, 1098, 1372, 1646, 2194, 3292]),
        group("32:9 (UltraWide)", retina: [810, 945, 1080, 1440, 2160],
              standard: [270, 360, 406, 472, 540, 720, 900, 1080, 1440, 2160]),
        group("10.5:9 (UltraWide 分割)", retina: [2468, 2880, 3292, 4388, 6582],
              standard: [822, 1098, 1234, 1440, 1646, 2194, 2742, 3292, 4388, 6582]),
    ]
}

/// 建立一個虛擬顯示器,並讓主要顯示器鏡像它(虛擬顯示器為主,所以畫面與螢幕共享都用虛擬顯示器的解析度)。
/// 虛擬顯示器隸屬於本行程,App 結束(含被殺掉)時系統會自動移除並解除鏡像。
/// 同一個行程內釋放虛擬顯示器不會讓它消失,而且重建後鏡像會失敗,
/// 所以只建立一次;換解析度時先解除鏡像、套用新模式、再重新鏡像。
@MainActor
final class VirtualDisplayController: ObservableObject {
    static let shared = VirtualDisplayController()

    @Published private(set) var current: ResolutionOption?
    @Published var message: String?

    private var display: CGVirtualDisplay?
    private var baseID: CGDirectDisplayID = 0

    /// 目前虛擬顯示器的 ID,沒有時為 nil。其他功能用它排除虛擬顯示器。
    nonisolated static var activeID: CGDirectDisplayID? { activeIDStorage.value }
    private nonisolated static let activeIDStorage = IDBox()

    var isActive: Bool { display != nil }

    /// 建立虛擬顯示器,或換成新的解析度。
    func updateResolution(_ option: ResolutionOption) {
        message = nil
        if display == nil {
            baseID = CGMainDisplayID()
            display = makeDisplay()
            VirtualDisplayController.activeIDStorage.value = display?.displayID
        } else {
            _ = mirror(baseID, of: kCGNullDirectDisplay)
        }
        guard let virtual = display else {
            message = "無法建立虛擬螢幕。"
            current = nil
            return
        }

        // HiDPI 的模式以點(邏輯像素)表示:像素尺寸的一半,背板是 2 倍。
        let scale = option.isRetina ? 2 : 1
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = option.isRetina ? 1 : 0
        settings.modes = [CGVirtualDisplayMode(width: UInt(option.width / scale),
                                               height: UInt(option.height / scale), refreshRate: 60)]
        guard virtual.apply(settings) else {
            message = "無法套用這個解析度。"
            current = nil
            return
        }
        current = option
        if !mirror(baseID, of: virtual.displayID) {
            message = "虛擬螢幕已建立,但無法與主要顯示器綁定。"
        }
    }

    /// 解除綁定並移除虛擬螢幕。虛擬顯示器只有行程結束才會消失,所以解除鏡像後重新啟動 App。
    func remove() {
        _ = mirror(baseID, of: kCGNullDirectDisplay)
        current = nil
        display = nil
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// 以最大尺寸建立虛擬顯示器,各解析度都由模式決定。
    private func makeDisplay() -> CGVirtualDisplay? {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = "MacDisplayManager 虛擬螢幕"
        descriptor.vendorID = 0x3456
        descriptor.productID = 0x1234
        descriptor.serialNum = 1
        descriptor.queue = DispatchQueue.main
        descriptor.maxPixelsWide = 7680
        descriptor.maxPixelsHigh = 6582
        descriptor.sizeInMillimeters = CGSize(width: 7680.0 / 255 * 25.4, height: 6582.0 / 255 * 25.4)
        return CGVirtualDisplay(descriptor: descriptor)
    }

    /// 讓 `slave` 鏡像 `master`;`master` 為 kCGNullDirectDisplay 時解除鏡像。
    private func mirror(_ slave: CGDirectDisplayID, of master: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayMirrorOfDisplay(config, slave, master)
        guard CGCompleteDisplayConfiguration(config, .forSession) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return true
    }
}

/// 讓非 MainActor 的程式碼也能讀取虛擬顯示器 ID。
final class IDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CGDirectDisplayID?
    var value: CGDirectDisplayID? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

/// 「虛擬螢幕」頁:左邊選長寬比,右邊選解析度(兩層清單)。
struct VirtualDisplayView: View {
    @ObservedObject private var controller = VirtualDisplayController.shared
    @State private var groupID = ResolutionCatalog.groups[0].id

    private var group: AspectGroup {
        ResolutionCatalog.groups.first { $0.id == groupID } ?? ResolutionCatalog.groups[0]
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "display.2")
                .font(.system(size: 44))
            Text(verbatim: controller.current.map { "虛擬螢幕:\(String($0.width))×\(String($0.height))" } ?? "尚未建立虛擬螢幕")
                .font(.title3.bold())

            HStack(spacing: 0) {
                List(ResolutionCatalog.groups, selection: $groupID) { g in
                    Text(g.name).tag(g.id)
                }
                .frame(width: 130)

                List {
                    Section("Retina(請至系統設定調整縮放)") {
                        ForEach(group.retina) { row($0) }
                    }
                    Section("標準解析度") {
                        ForEach(group.standard) { row($0) }
                    }
                }
            }
            .frame(height: 300)
            .border(Color.secondary.opacity(0.3))

            if let m = controller.message {
                Text(m)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("移除虛擬螢幕(會重新啟動 App)") { controller.remove() }
                .disabled(!controller.isActive)

            Text("選擇解析度會新增虛擬螢幕並與主要顯示器綁定(鏡像);已存在時則換成新的解析度。結束 App 會自動移除。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 400)
    }

    private func row(_ option: ResolutionOption) -> some View {
        Button {
            controller.updateResolution(option)
        } label: {
            HStack {
                Text(option.isRetina ? "\(option.title)  \(option.width)×\(option.height)" : option.title)
                Spacer()
                if controller.current?.id == option.id { Image(systemName: "checkmark") }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
