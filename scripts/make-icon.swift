// Draws the app icon into an .iconset folder for iconutil.
// Usage: swift scripts/make-icon.swift <out.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let top = NSColor(srgbRed: 1.0, green: 0.835, blue: 0.290, alpha: 1)
let bottom = NSColor(srgbRed: 1.0, green: 0.698, blue: 0.118, alpha: 1)
let graphite = NSColor(srgbRed: 0.122, green: 0.149, blue: 0.200, alpha: 1)

/// Drawn on a 1024 grid, scaled to each size.
func draw(in size: CGFloat) {
    let s = size / 1024
    // Apple's icon grid: 824pt body, centred, like macpeek's.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    bottom.setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: bottom, ending: top)?.draw(in: squircle, angle: 90)

    func stroke(_ path: NSBezierPath, width: CGFloat) {
        path.lineWidth = width * s
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        graphite.setStroke()
        path.stroke()
    }

    // The ⇧⌘4 selection corners.
    let near: CGFloat = 280, far: CGFloat = 744, arm: CGFloat = 130
    for (x, y, dx, dy) in [(near, far, 1.0, -1.0), (far, far, -1, -1), (near, near, 1, 1), (far, near, -1, 1)] {
        let corner = NSBezierPath()
        corner.move(to: NSPoint(x: x * s, y: (y + dy * arm) * s))
        corner.line(to: NSPoint(x: x * s, y: y * s))
        corner.line(to: NSPoint(x: (x + dx * arm) * s, y: y * s))
        stroke(corner, width: 56)
    }

    // Sent away.
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 512 * s, y: 400 * s))
    arrow.line(to: NSPoint(x: 512 * s, y: 630 * s))
    arrow.move(to: NSPoint(x: 432 * s, y: 550 * s))
    arrow.line(to: NSPoint(x: 512 * s, y: 630 * s))
    arrow.line(to: NSPoint(x: 592 * s, y: 550 * s))
    stroke(arrow, width: 60)
}

let sizes = [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
             ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
             ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)]
for (name, pixels) in sizes {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { continue }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(in: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: output.appending(path: "\(name).png"))
}
