// Draws the app icon (a ring gauge on a dark squircle) into an .iconset folder.
// Usage: swift Tools/MakeIcon.swift build/AppIcon.iconset

import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let bg = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset),
                          xRadius: s * 0.18, yRadius: s * 0.18)
    NSColor(red: 0.106, green: 0.106, blue: 0.122, alpha: 1).setFill()
    bg.fill()

    let c = NSPoint(x: s / 2, y: s / 2), r = s * 0.24, w = s * 0.075
    let track = NSBezierPath()
    track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
    track.lineWidth = w
    NSColor.white.withAlphaComponent(0.12).setStroke()
    track.stroke()

    let arc = NSBezierPath()
    arc.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - 360 * 0.68, clockwise: true)
    arc.lineWidth = w
    arc.lineCapStyle = .round
    NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1).setStroke()   // Claude orange
    arc.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        if let d = draw(base * scale) { try? d.write(to: URL(fileURLWithPath: "\(out)/\(name)")) }
    }
}
