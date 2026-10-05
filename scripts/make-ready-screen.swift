import AppKit
import ImageIO

// Render still frames at integral pixels. Encoding is performed offline by
// make-ready-stream.py; the app only publishes the bundled HLS segments.
// Usage: swift scripts/make-ready-screen.swift ICON.icns OUTPUT_DIRECTORY
let args = CommandLine.arguments
guard args.count == 3, let icon = NSImage(contentsOfFile: args[1]) else {
    fatalError("Usage: ICON.icns OUTPUT_DIRECTORY")
}
let output = URL(fileURLWithPath: args[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let width = 1920, height = 1080
let positions: [(CGFloat, CGFloat)] = [(0, 0), (-380, 180), (380, -180), (380, 180)]
for (index, offset) in positions.enumerated() {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.translateBy(x: offset.0, y: offset.1)
    context.interpolationQuality = .high
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    icon.draw(in: NSRect(x: 880, y: 566, width: 160, height: 160), from: .zero,
              operation: .sourceOver, fraction: 0.9)
    func text(_ value: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, brightness: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(white: brightness, alpha: 1)
        ]
        let string = value as NSString
        let x = ((CGFloat(width) - string.size(withAttributes: attributes).width) / 2).rounded()
        string.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
    }
    text("AirThrow", y: 494, size: 44, weight: .semibold, brightness: 0.72)
    text("Ready to play", y: 450, size: 26, weight: .regular, brightness: 0.48)
    NSGraphicsContext.restoreGraphicsState()
    let url = output.appendingPathComponent("frame\(index).png")
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { fatalError("Cannot create frame") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Frame write failed") }
}
