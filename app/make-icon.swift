// Draws the app icon and writes app/AppIcon.icns.   swift app/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icon grid: an 824/1024 rounded square, centered, with a soft shadow
    let inset = s * 100 / 1024
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(red: 0.10, green: 0.11, blue: 0.16, alpha: 1), NSColor(red: 0.02, green: 0.02, blue: 0.04, alpha: 1)])!
        .draw(in: path, angle: -90)

    // progress ring, like the timer in the notch
    let c = NSPoint(x: tile.midX, y: tile.midY)
    let r = tile.width * 0.30, w = tile.width * 0.075
    let track = NSBezierPath()
    track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
    track.lineWidth = w
    NSColor.white.withAlphaComponent(0.12).setStroke()
    track.stroke()
    let arc = NSBezierPath()
    arc.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - 360 * 0.72, clockwise: true)
    arc.lineWidth = w
    arc.lineCapStyle = .round
    NSColor(red: 0.20, green: 0.84, blue: 0.47, alpha: 1).setStroke()
    arc.stroke()
    // center dot
    let d = tile.width * 0.085
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! render(1024).write(to: dir.appendingPathComponent("../docs/icon.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", dir.appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print("wrote app/AppIcon.icns and docs/icon.png")
