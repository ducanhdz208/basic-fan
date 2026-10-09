import AppKit
let out = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
func render(_ size: Int, path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)!
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    let bg = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 212, yRadius: 212)
    NSColor(calibratedRed: 0.065, green: 0.12, blue: 0.17, alpha: 1).setFill(); bg.fill()
    let ring = NSBezierPath(ovalIn: NSRect(x: 212, y: 212, width: 600, height: 600))
    ring.lineWidth = 24
    NSColor(calibratedRed: 0.36, green: 0.86, blue: 0.9, alpha: 0.3).setStroke(); ring.stroke()
    NSGraphicsContext.saveGraphicsState()
    let center = NSAffineTransform(); center.translateX(by: 512, yBy: 512); center.concat()
    for _ in 0..<3 {
        let blade = NSBezierPath()
        blade.move(to: NSPoint(x: -23, y: 63))
        blade.curve(to: NSPoint(x: -126, y: 264), controlPoint1: NSPoint(x: -164, y: 110), controlPoint2: NSPoint(x: -196, y: 215))
        blade.curve(to: NSPoint(x: 123, y: 222), controlPoint1: NSPoint(x: -63, y: 311), controlPoint2: NSPoint(x: 141, y: 299))
        blade.curve(to: NSPoint(x: 45, y: 60), controlPoint1: NSPoint(x: 107, y: 151), controlPoint2: NSPoint(x: 18, y: 151))
        blade.close()
        NSColor(calibratedRed: 0.5, green: 0.93, blue: 0.94, alpha: 1).setFill(); blade.fill()
        let rotate = NSAffineTransform(); rotate.rotate(byDegrees: 120); rotate.concat()
    }
    NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: -49, y: -49, width: 98, height: 98)).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
for n in [16, 32, 128, 256, 512] {
    render(n, path: "\(out)/icon_\(n)x\(n).png")
    render(n * 2, path: "\(out)/icon_\(n)x\(n)@2x.png")
}
