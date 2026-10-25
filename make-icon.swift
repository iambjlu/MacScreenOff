// 產生 AppIcon.icns:swiftc make-icon.swift -o /tmp/make-icon && /tmp/make-icon
import AppKit

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)

    // macOS 圖示規格:824/1024 的圓角方塊,四周留白
    let body = NSRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)
    let path = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGraphicsContext.current?.cgContext.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                                                   color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill(); path.fill()
    NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.28, alpha: 1),
                        NSColor(calibratedRed: 0.28, green: 0.20, blue: 0.62, alpha: 1)])!
        .draw(in: path, angle: -60)

    // 白色螢幕符號
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .regular)
    if let sym = NSImage(systemSymbolName: "display", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: sym.size, flipped: false) { r in
            sym.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
        }
        let w = tinted.size.width, h = tinted.size.height
        tinted.draw(in: NSRect(x: (s - w) / 2, y: (s - h) / 2 + s * 0.02, width: w, height: h))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: dir)
try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(size: base).write(to: URL(fileURLWithPath: "\(dir)/icon_\(base)x\(base).png"))
    try! render(size: base * 2).write(to: URL(fileURLWithPath: "\(dir)/icon_\(base)x\(base)@2x.png"))
}
