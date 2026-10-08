import AppKit
import Foundation

let target = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 208, yRadius: 208)
        NSGradient(starting: NSColor(srgbRed: 0.18, green: 0.57, blue: 0.50, alpha: 1), ending: NSColor(srgbRed: 0.06, green: 0.29, blue: 0.28, alpha: 1))!.draw(in: background, angle: -90)
        NSColor.white.withAlphaComponent(0.95).setFill()
        for (i, height) in [160, 290, 450, 340, 200].enumerated() {
            NSBezierPath(roundedRect: NSRect(x: 282 + i * 96, y: 512 - height / 2, width: 56, height: height), xRadius: 28, yRadius: 28).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: target.appendingPathComponent(name))
    }
}
