// Original Spice Client artwork. MIT, copyright 2026 nlink-jp.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let directory = root.appendingPathComponent("dist/AppIcon.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let artwork = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
    let tile = NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 200, yRadius: 200)
    NSGradient(starting: NSColor(red: 0.09, green: 0.22, blue: 0.31, alpha: 1),
               ending: NSColor(red: 0.02, green: 0.08, blue: 0.14, alpha: 1))!.draw(in: tile, angle: -60)
    let screen = NSBezierPath(roundedRect: NSRect(x: 220, y: 350, width: 584, height: 420), xRadius: 40, yRadius: 40)
    NSColor(red: 0.37, green: 0.94, blue: 0.82, alpha: 1).setStroke()
    screen.lineWidth = 30; screen.stroke()
    let stem = NSBezierPath()
    stem.move(to: NSPoint(x: 512, y: 350)); stem.line(to: NSPoint(x: 512, y: 238))
    stem.move(to: NSPoint(x: 385, y: 238)); stem.line(to: NSPoint(x: 639, y: 238))
    stem.lineWidth = 30; stem.lineCapStyle = .round; stem.stroke()
    let link = NSBezierPath()
    link.move(to: NSPoint(x: 360, y: 555)); link.line(to: NSPoint(x: 664, y: 555))
    link.lineWidth = 22; link.stroke()
    for x in [360.0, 664.0] {
        NSColor(red: 1, green: 0.68, blue: 0.30, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 44, y: 511, width: 88, height: 88)).fill()
    }
    return true
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        artwork.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
