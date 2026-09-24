import AppKit

let out = "Support/AppIcon.iconset"
try! FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func halfPath(left: Bool, split: CGFloat, in rect: CGRect) -> NSBezierPath {
    let gap = rect.width * 0.09 * split
    let mid = rect.midX + (left ? -gap : gap)
    let w = rect.width
    let h = rect.height
    let p = NSBezierPath()

    let top = CGPoint(x: mid, y: rect.minY + h * 0.97)
    let bottom = CGPoint(x: mid, y: rect.minY + h * 0.03)
    p.move(to: top)

    if left {
        let edge = rect.minX
        p.curve(
            to: CGPoint(x: edge, y: rect.midY),
            controlPoint1: CGPoint(x: mid - w * 0.30, y: rect.minY + h * 1.02),
            controlPoint2: CGPoint(x: edge - w * 0.04, y: rect.minY + h * 0.80)
        )
        p.curve(
            to: bottom,
            controlPoint1: CGPoint(x: edge - w * 0.04, y: rect.minY + h * 0.20),
            controlPoint2: CGPoint(x: mid - w * 0.30, y: rect.minY - h * 0.02)
        )
    } else {
        let edge = rect.maxX
        p.curve(
            to: CGPoint(x: edge, y: rect.midY),
            controlPoint1: CGPoint(x: mid + w * 0.30, y: rect.minY + h * 1.02),
            controlPoint2: CGPoint(x: edge + w * 0.04, y: rect.minY + h * 0.80)
        )
        p.curve(
            to: bottom,
            controlPoint1: CGPoint(x: edge + w * 0.04, y: rect.minY + h * 0.20),
            controlPoint2: CGPoint(x: mid + w * 0.30, y: rect.minY - h * 0.02)
        )
    }

    let sign: CGFloat = left ? 1 : -1
    let amplitude = gap * 0.8
    for (i, f) in [0.72, 0.61, 0.42, 0.31].enumerated() {
        let x = mid + sign * amplitude * (i.isMultiple(of: 2) ? 1 : -1)
        p.line(to: CGPoint(x: x, y: rect.minY + h * f))
    }
    p.close()
    return p
}

func draw(_ size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    let inset = s * 0.04
    let iconRect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: iconRect, xRadius: s * 0.24, yRadius: s * 0.24)
    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [
        NSColor(red: 0.09, green: 0.09, blue: 0.13, alpha: 1),
        NSColor(red: 0.17, green: 0.16, blue: 0.23, alpha: 1),
    ])!.draw(in: iconRect, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // Split brain, teal left / pink right, wide crack
    let brainRect = iconRect.insetBy(dx: s * 0.13, dy: s * 0.17)
    let teal = NSColor(red: 0.20, green: 0.82, blue: 0.74, alpha: 1)
    let pink = NSColor(red: 1.0, green: 0.40, blue: 0.57, alpha: 1)
    teal.setFill()
    halfPath(left: true, split: 1.0, in: brainRect).fill()
    pink.setFill()
    halfPath(left: false, split: 1.0, in: brainRect).fill()

    image.unlockFocus()
    return image
}

func pngData(_ image: NSImage, size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let master = draw(1024)
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
    ("icon_512x512@2x.png", 1024),
]
for (name, size) in sizes {
    try! pngData(master, size: size).write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
print("iconset written")
