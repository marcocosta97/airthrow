import AppKit

// Original geometric application icon, generated from vector paths at each size.
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (points, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let pixels = points * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()
    NSColor(calibratedRed: 0.07, green: 0.33, blue: 0.78, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 56, y: 56, width: 912, height: 912), xRadius: 200, yRadius: 200).fill()
    NSColor.white.setStroke()
    let screen = NSBezierPath(roundedRect: NSRect(x: 230, y: 344, width: 564, height: 380), xRadius: 36, yRadius: 36)
    screen.lineWidth = 38
    screen.stroke()
    NSColor(calibratedRed: 0.07, green: 0.33, blue: 0.78, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 374, y: 300, width: 276, height: 85)).fill()
    NSColor.white.setFill()
    let triangle = NSBezierPath()
    triangle.move(to: NSPoint(x: 512, y: 430))
    triangle.line(to: NSPoint(x: 377, y: 264))
    triangle.line(to: NSPoint(x: 647, y: 264))
    triangle.close()
    triangle.fill()
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
}
