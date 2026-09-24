import AppKit

/// Resolution-independent split-brain glyph. `split` 0 = whole brain,
/// 0.45 = cracking, 1.0 = fully split. Used for the status bar item.
enum SplitBrainIcon {
    static func image(split: CGFloat, size: CGFloat = 16) -> NSImage {
        let clamped = max(0, min(1, split))
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.black.setFill()
            let insetRect = rect.insetBy(dx: size * 0.08, dy: size * 0.10)
            halfPath(left: true, split: clamped, in: insetRect).fill()
            halfPath(left: false, split: clamped, in: insetRect).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// One brain hemisphere with a zig-zag crack edge. Mirrored for the other side.
    static func halfPath(left: Bool, split: CGFloat, in rect: CGRect) -> NSBezierPath {
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

        // Zig-zag crack back to the top. Amplitude scales with split, so at
        // split 0 both edges are the same vertical midline and the halves
        // merge into a whole brain with no visible seam.
        let sign: CGFloat = left ? 1 : -1
        // Amplitude stays below the gap so zig-zag tips never interlock —
        // full split must read as wider than the cracking state.
        let amplitude = gap * 0.8
        for (i, f) in [0.72, 0.61, 0.42, 0.31].enumerated() {
            let x = mid + sign * amplitude * (i.isMultiple(of: 2) ? 1 : -1)
            p.line(to: CGPoint(x: x, y: rect.minY + h * f))
        }
        p.close()
        return p
    }
}
