// Draws the app icon and writes Resources/AppIcon.icns.
// Run from the repository root: swift Scripts/make-icon.swift
import AppKit

/// The icon at `size` pixels: a dark metal tile with a frame-time trace and a record dot.
func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    // Everything below is laid out on a 1024-point canvas.
    context.scaleBy(x: size / 1024, y: size / 1024)

    func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // The tile follows the macOS icon grid: 824 points wide, centred, with a soft shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    context.addPath(shape)
    context.setFillColor(color(0x1C1E22))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0x3A3F47), color(0x15171A)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Faint horizontal grid lines, like a chart.
    context.setStrokeColor(color(0xFFFFFF, 0.07))
    context.setLineWidth(4)
    for y in stride(from: CGFloat(300), through: 700, by: 133) {
        context.move(to: CGPoint(x: 100, y: y))
        context.addLine(to: CGPoint(x: 924, y: y))
    }
    context.strokePath()

    // The frame-time trace: steady, one tall spike, steady again.
    let trace: [CGPoint] = [
        CGPoint(x: 100, y: 388), CGPoint(x: 250, y: 388), CGPoint(x: 300, y: 430), CGPoint(x: 350, y: 372),
        CGPoint(x: 420, y: 388), CGPoint(x: 492, y: 388), CGPoint(x: 548, y: 700), CGPoint(x: 612, y: 300),
        CGPoint(x: 668, y: 440), CGPoint(x: 720, y: 388), CGPoint(x: 924, y: 388),
    ]
    let line = CGMutablePath()
    line.addLines(between: trace)

    // A glow under the trace, then the trace itself.
    let area = CGMutablePath()
    area.addLines(between: trace + [CGPoint(x: 924, y: 100), CGPoint(x: 100, y: 100)])
    area.closeSubpath()
    context.saveGState()
    context.addPath(area)
    context.clip()
    let glow = CGGradient(colorsSpace: space, colors: [color(0x3987E5, 0.38), color(0x3987E5, 0)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(glow, start: CGPoint(x: 512, y: 640), end: CGPoint(x: 512, y: 130), options: [])
    context.restoreGState()

    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(40)
    context.addPath(line)
    context.replacePathWithStrokedPath()
    context.clip()
    let stroke = CGGradient(colorsSpace: space, colors: [color(0x6DB1FF), color(0x2A78D6)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(stroke, start: CGPoint(x: 100, y: 700), end: CGPoint(x: 924, y: 300), options: [])
    context.restoreGState()

    // The record dot.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.setShadow(offset: .zero, blur: 36, color: color(0xFF453A, 0.7))
    context.setFillColor(color(0xFF453A))
    context.fillEllipse(in: CGRect(x: 716, y: 716, width: 104, height: 104))
    context.restoreGState()

    // A thin highlight along the top edge gives the tile its metal rim.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.addPath(CGPath(roundedRect: tile.insetBy(dx: 3, dy: 3), cornerWidth: 183, cornerHeight: 183, transform: nil))
    context.setLineWidth(6)
    context.replacePathWithStrokedPath()
    context.clip()
    let rim = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(rim, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 520), options: [])
    context.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

let fileManager = FileManager.default
let iconset = fileManager.temporaryDirectory.appendingPathComponent("MetalCap-\(UUID().uuidString).iconset")
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let png = drawIcon(size: CGFloat(points * scale)).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent(name))
    }
}

try fileManager.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(1) }

// A preview for the README and for checking the result by eye.
try drawIcon(size: 512).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))
print("Wrote Resources/AppIcon.icns and Resources/AppIcon.png")
