import AppKit
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let p = CGFloat(pixels)
        let rect = NSRect(x: p * 0.06, y: p * 0.06, width: p * 0.88, height: p * 0.88)
        let shape = NSBezierPath(roundedRect: rect, xRadius: p * 0.20, yRadius: p * 0.20)
        NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.27, blue: 0.26, alpha: 1), ending: NSColor(srgbRed: 0.09, green: 0.13, blue: 0.13, alpha: 1))!.draw(in: shape, angle: -90)
        NSColor(srgbRed: 0.65, green: 0.91, blue: 0.79, alpha: 1).setFill()
        let moon = NSBezierPath()
        moon.appendArc(withCenter: NSPoint(x: p * 0.5, y: p * 0.5), radius: p * 0.265, startAngle: 65, endAngle: 295, clockwise: false)
        moon.curve(to: NSPoint(x: p * 0.5 + cos(65 * .pi / 180) * p * 0.265, y: p * 0.5 + sin(65 * .pi / 180) * p * 0.265), controlPoint1: NSPoint(x: p * 0.30, y: p * 0.34), controlPoint2: NSPoint(x: p * 0.30, y: p * 0.67))
        moon.close(); moon.fill()
        NSColor.white.withAlphaComponent(0.15).setStroke(); shape.lineWidth = max(1, p * 0.002); shape.stroke()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(filename))
    }
}
