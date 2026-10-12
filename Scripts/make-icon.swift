import AppKit

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

for (name, pixels) in sizes {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fputs("Could not create bitmap\n", stderr)
        exit(1)
    }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)
    let colors = [
        NSColor(srgbRed: 0.208, green: 0.690, blue: 0.898, alpha: 1).cgColor,
        NSColor(srgbRed: 0.153, green: 0.455, blue: 0.616, alpha: 1).cgColor
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    let context = NSGraphicsContext.current!.cgContext
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: size, y: 0),
        options: []
    )
    let points = [
        CGPoint(x: size * 0.28, y: size * 0.34),
        CGPoint(x: size * 0.52, y: size * 0.70),
        CGPoint(x: size * 0.74, y: size * 0.38)
    ]
    context.setStrokeColor(NSColor.white.cgColor)
    context.setLineWidth(max(1, size * 0.028))
    context.setLineCap(.round)
    context.move(to: points[0]); context.addLine(to: points[1]); context.strokePath()
    context.move(to: points[1]); context.addLine(to: points[2]); context.strokePath()
    context.move(to: points[0]); context.addLine(to: points[2]); context.strokePath()
    for (index, point) in points.enumerated() {
        let radius = size * (index == 1 ? 0.07 : 0.055)
        let color = index == 1
            ? NSColor(srgbRed: 1, green: 0.722, blue: 0.220, alpha: 1)
            : NSColor.white
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fputs("Could not encode \(name)\n", stderr)
        exit(1)
    }
    try png.write(to: directory.appendingPathComponent(name))
}
