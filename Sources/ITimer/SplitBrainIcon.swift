import AppKit

/// Resolution-independent split-brain glyph. The brain cracks into one
/// piece per running task (2 running = 2 halves, 4 running = 4 quarters),
/// and `spread` 0...1 says how far apart the pieces sit (0.35 = a crack,
/// 1 = fully split). Used for the status item and the panel's brain buddy.
enum SplitBrainIcon {
    /// Status item canvas: the 16pt brain plus a little room on each side
    /// for the explosion's shards, so the item never changes width.
    static let statusCanvas = NSSize(width: 22, height: 18)
    /// Past this the pieces get too small to read in the menu bar.
    static let maxPieces = 6
    /// Resting spread for the "cracking" state (two tasks, under the line).
    static let crackSpread: CGFloat = 0.35

    /// Per-piece animation offset on top of the resting layout.
    struct PiecePose {
        var offset = CGVector.zero
        var rotation: CGFloat = 0
        var scale: CGFloat = 1
    }

    static func image(pieces: Int, spread: CGFloat, size: CGFloat = 16) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            drawBrain(pieces: pieces, spread: spread, in: rect.insetBy(dx: size * 0.08, dy: size * 0.10)) { _ in .black }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Resting status-bar glyph on the wider canvas. Template (follows the
    /// menu bar) unless `tint` is given — the menu bar ignores SwiftUI tints
    /// on template images, so the split state is drawn in color.
    static func statusImage(pieces: Int, spread: CGFloat, tint: NSColor? = nil) -> NSImage {
        let image = NSImage(size: statusCanvas, flipped: false) { rect in
            drawBrain(pieces: pieces, spread: spread, in: brainRect(in: rect, scale: 1)) { _ in tint ?? .black }
            return true
        }
        image.isTemplate = tint == nil
        return image
    }

    private static func brainRect(in rect: CGRect, scale: CGFloat) -> CGRect {
        let side = min(rect.height, rect.width) * 16 / 18 * scale
        let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        return square.insetBy(dx: side * 0.08, dy: side * 0.10)
    }

    // MARK: pieces

    /// Draws the brain cut into `pieces` radial wedges with zig-zag cracks
    /// into the current graphics context (y up). `pose` gets the piece index
    /// and its outward unit direction and may add motion on top.
    static func drawBrain(
        pieces: Int,
        spread: CGFloat,
        in brain: CGRect,
        pose: (Int, CGVector) -> PiecePose = { _, _ in PiecePose() },
        color: (Int) -> NSColor
    ) {
        let outline = outlinePath(in: brain)
        let center = CGPoint(x: brain.midX, y: brain.midY)
        let count = max(1, min(maxPieces, pieces))
        guard count > 1 else {
            draw(outline, color: color(0), pivot: center, pose: pose(0, .zero), clip: nil)
            return
        }
        let radius = max(brain.width, brain.height) * 0.62
        let amplitude = brain.width * 0.05
        let gap = spreadDistance(spread, in: brain)
        let step = 2 * CGFloat.pi / CGFloat(count)
        for index in 0..<count {
            let from = CGFloat.pi / 2 + CGFloat(index) * step
            let mid = from + step / 2
            let direction = CGVector(dx: cos(mid), dy: sin(mid))
            var piece = pose(index, direction)
            piece.offset.dx += direction.dx * gap
            piece.offset.dy += direction.dy * gap
            let pivot = CGPoint(x: center.x + direction.dx * brain.width * 0.22, y: center.y + direction.dy * brain.height * 0.22)
            let wedge = wedgePath(from: from, to: from + step, center: center, radius: radius, amplitude: amplitude)
            draw(outline, color: color(index), pivot: pivot, pose: piece, clip: wedge)
        }
    }

    /// How far each piece sits out from the center at a given spread.
    static func spreadDistance(_ spread: CGFloat, in brain: CGRect) -> CGFloat {
        brain.width * 0.085 * spread
    }

    /// Unit direction of each piece, same order as `drawBrain`.
    static func directions(pieces: Int) -> [CGVector] {
        let count = max(1, min(maxPieces, pieces))
        guard count > 1 else { return [.zero] }
        let step = 2 * CGFloat.pi / CGFloat(count)
        return (0..<count).map { index in
            let mid = CGFloat.pi / 2 + (CGFloat(index) + 0.5) * step
            return CGVector(dx: cos(mid), dy: sin(mid))
        }
    }

    private static func draw(_ shape: NSBezierPath, color: NSColor, pivot: CGPoint, pose: PiecePose, clip: NSBezierPath?) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: pivot.x + pose.offset.dx, yBy: pivot.y + pose.offset.dy)
        transform.rotate(byRadians: pose.rotation)
        transform.scale(by: pose.scale)
        transform.translateX(by: -pivot.x, yBy: -pivot.y)
        transform.concat()
        clip?.addClip()
        color.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Whole-brain silhouette: both hemispheres with no gap, one fill so
    /// there is no seam.
    static func outlinePath(in rect: CGRect) -> NSBezierPath {
        let path = halfPath(left: true, split: 0, in: rect)
        path.append(halfPath(left: false, split: 0, in: rect))
        return path
    }

    /// A crack from the center outward. Only depends on the angle, so the
    /// two pieces sharing a crack get the exact same edge.
    private static func crack(angle: CGFloat, center: CGPoint, radius: CGFloat, amplitude: CGFloat) -> [CGPoint] {
        let fractions: [CGFloat] = [0, 0.2, 0.38, 0.56, 0.74, 1]
        let along = CGVector(dx: cos(angle), dy: sin(angle))
        let across = CGVector(dx: -along.dy, dy: along.dx)
        return fractions.enumerated().map { index, fraction in
            let edge = index == 0 || index == fractions.count - 1
            let side: CGFloat = edge ? 0 : (index.isMultiple(of: 2) ? -1 : 1)
            return CGPoint(
                x: center.x + along.dx * radius * fraction + across.dx * amplitude * side,
                y: center.y + along.dy * radius * fraction + across.dy * amplitude * side
            )
        }
    }

    private static func wedgePath(from start: CGFloat, to end: CGFloat, center: CGPoint, radius: CGFloat, amplitude: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let first = crack(angle: start, center: center, radius: radius, amplitude: amplitude)
        path.move(to: first[0])
        first.dropFirst().forEach { path.line(to: $0) }
        // Sweep well outside the silhouette to the next crack.
        let steps = 12
        for index in 0...steps {
            let angle = start + (end - start) * CGFloat(index) / CGFloat(steps)
            path.line(to: CGPoint(x: center.x + cos(angle) * radius * 1.8, y: center.y + sin(angle) * radius * 1.8))
        }
        crack(angle: end, center: center, radius: radius, amplitude: amplitude).reversed().forEach { path.line(to: $0) }
        path.close()
        return path
    }

    // MARK: explosion

    enum Burst {
        /// Crossing into brain split (or one more task): charge, flash,
        /// the pieces fly apart, shards.
        case blast
        /// Still split: the pieces pop out one after another and sparks
        /// jump out of the cracks. Repeats every few seconds.
        case wobble
        /// Dropping back under the line: pieces snap together, sparkles.
        case heal

        var duration: TimeInterval {
            switch self {
            case .blast: 1.2
            case .wobble: 1.1
            case .heal: 0.9
            }
        }
    }

    /// One colored frame of a burst. `t` runs 0...1; `intensity` ≥ 1 grows
    /// with how far past the brain-split line you are. At t = 1 blast and
    /// wobble match the resting split glyph so the hand-off is seamless.
    static func burstFrame(
        _ burst: Burst,
        t rawT: CGFloat,
        pieces: Int,
        intensity: CGFloat = 1,
        size: NSSize = statusCanvas,
        tint: NSColor = .systemRed
    ) -> NSImage {
        let t = max(0, min(1, rawT))
        let image = NSImage(size: size, flipped: false) { rect in
            let unit = rect.height / 18
            switch burst {
            case .blast:
                drawBlast(t: t, pieces: pieces, intensity: intensity, unit: unit, in: rect, tint: tint)
            case .wobble:
                drawWobble(t: t, pieces: pieces, unit: unit, in: rect, tint: tint)
            case .heal:
                drawHeal(t: t, pieces: pieces, unit: unit, in: rect)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawBlast(t: CGFloat, pieces: Int, intensity: CGFloat, unit: CGFloat, in rect: CGRect, tint: NSColor) {
        let charge = min(1, t / 0.18)
        let blast = min(1, max(0, (t - 0.18) / 0.82))
        let power = 1 + (min(intensity, 3) - 1) * 0.25

        // Charge: swell and shake. Settles back to scale 1 during the blast.
        let swell = t < 0.18 ? 1 + 0.12 * charge : 1 + 0.12 * max(0, 1 - blast * 4)
        let shake = t < 0.18 ? sin(t * 140) * 0.7 * unit * charge : 0
        let brain = brainRect(in: rect, scale: swell).offsetBy(dx: shake, dy: 0)
        let center = CGPoint(x: brain.midX, y: brain.midY)

        // Flash: a spiky star behind the brain.
        if t > 0.18 {
            // Fades fast (squared) so it never lingers as a muddy blob on
            // dark menu bars; the pale core keeps it reading as light.
            let flash = min(1, (t - 0.18) / 0.3)
            let alpha = (1 - flash) * (1 - flash)
            if alpha > 0.02 {
                let radius = (3 + 9 * flash * power) * unit
                starPath(center: center, points: 9, outer: radius, inner: radius * 0.45, rotation: flash * 0.6)
                    .fill(color: NSColor.systemOrange.withAlphaComponent(alpha))
                starPath(center: center, points: 7, outer: radius * 0.62, inner: radius * 0.32, rotation: -flash)
                    .fill(color: NSColor.systemYellow.withAlphaComponent(alpha))
                NSBezierPath(ovalIn: CGRect(x: center.x - radius * 0.22, y: center.y - radius * 0.22, width: radius * 0.44, height: radius * 0.44))
                    .fill(color: NSColor(calibratedRed: 1, green: 0.97, blue: 0.85, alpha: alpha))
            }
        }

        // Shards fly out from the cracks, with a little gravity.
        if t > 0.18 {
            let count = 10 + Int((min(intensity, 3) - 1) * 4)
            let colors: [NSColor] = [.systemYellow, .systemOrange, tint, .systemPink]
            let eased = 1 - pow(1 - blast, 2.2)
            for index in 0..<count {
                let seed = CGFloat(index)
                let angle = seed / CGFloat(count) * .pi * 2 + noise(index, 1) * 0.5
                let speed = (6 + 6 * noise(index, 2)) * unit * power
                let x = center.x + cos(angle) * speed * eased
                let y = center.y + sin(angle) * speed * eased * 0.8 - 4 * unit * blast * blast
                let alpha = max(0, 1 - pow(blast, 1.4))
                let side = max(0.6, (1.9 - 1.2 * blast) * unit)
                let color = colors[index % colors.count].withAlphaComponent(alpha)
                let shard = NSBezierPath()
                let spin = angle + blast * 6 * (index.isMultiple(of: 2) ? 1 : -1)
                for corner in 0..<3 {
                    let a = spin + CGFloat(corner) * .pi * 2 / 3
                    let point = CGPoint(x: x + cos(a) * side, y: y + sin(a) * side)
                    corner == 0 ? shard.move(to: point) : shard.line(to: point)
                }
                shard.close()
                shard.fill(color: color)
            }
        }

        // Pieces: the crack widens during charge, then they fly apart, tilt
        // outward and spring back into the resting split layout.
        let spread = t < 0.18 ? crackSpread + 0.15 * charge : 0.5 + 0.5 * min(1, blast * 3)
        let fly = flyCurve(blast) * 3.4 * unit * power
        let tilt = flyCurve(blast) * 0.32 * power
        drawBrain(pieces: pieces, spread: spread, in: brain, pose: { index, direction in
            PiecePose(
                offset: CGVector(dx: direction.dx * fly, dy: direction.dy * fly * 0.55 + flyCurve(blast) * unit * 0.5),
                rotation: (index.isMultiple(of: 2) ? 1 : -1) * tilt
            )
        }, color: { _ in tint })
    }

    private static func drawWobble(t: CGFloat, pieces: Int, unit: CGFloat, in rect: CGRect, tint: NSColor) {
        let count = max(1, min(maxPieces, pieces))
        let shiver = sin(t * 55) * 0.6 * unit * (1 - t)
        let brain = brainRect(in: rect, scale: 1).offsetBy(dx: shiver, dy: 0)
        let center = CGPoint(x: brain.midX, y: brain.midY)
        // Each piece pops out in turn, so the count reads as a ripple.
        let stagger = 0.5 / CGFloat(count)
        func bump(_ index: Int) -> CGFloat {
            let local = max(0, min(1, (t - CGFloat(index) * stagger) / 0.45))
            return sin(local * .pi)
        }
        drawBrain(pieces: count, spread: 1, in: brain, pose: { index, direction in
            let amount = bump(index)
            return PiecePose(
                offset: CGVector(dx: direction.dx * 2 * unit * amount, dy: direction.dy * 1.2 * unit * amount),
                rotation: (index.isMultiple(of: 2) ? 1 : -1) * 0.28 * amount,
                scale: 1 + 0.05 * amount
            )
        }, color: { _ in tint })
        // Sparks jump out of every crack.
        let step = 2 * CGFloat.pi / CGFloat(count)
        for index in 0..<count {
            let local = max(0, min(1, (t - CGFloat(index) * stagger - 0.1) / 0.6))
            guard local > 0, local < 1 else { continue }
            let angle = CGFloat.pi / 2 + CGFloat(index) * step
            let distance = (2 + 7 * local) * unit
            let x = center.x + cos(angle) * distance
            let y = center.y + sin(angle) * distance * 0.9
            let radius = (1.2 - 0.6 * local) * unit
            NSBezierPath(ovalIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                .fill(color: (index.isMultiple(of: 2) ? NSColor.systemYellow : NSColor.systemOrange).withAlphaComponent(1 - local))
        }
    }

    private static func drawHeal(t: CGFloat, pieces: Int, unit: CGFloat, in rect: CGRect) {
        let brain = brainRect(in: rect, scale: 1)
        let center = CGPoint(x: brain.midX, y: brain.midY)
        // Ease-out with a small overshoot: pieces slam together, then settle.
        let close = 1 - pow(1 - min(1, t / 0.55), 3)
        let squash = t > 0.5 ? sin(min(1, (t - 0.5) / 0.5) * .pi) * 0.08 : 0
        let spread = 1.4 * (1 - close)
        let tint = NSColor.systemRed.blended(withFraction: close, of: .systemGreen) ?? .systemGreen
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: brain.minY)
        transform.scaleX(by: 1 + squash, yBy: 1 - squash)
        transform.translateX(by: -center.x, yBy: -brain.minY)
        transform.concat()
        if close < 0.98 {
            drawBrain(pieces: pieces, spread: spread, in: brain, color: { _ in tint })
        } else {
            drawBrain(pieces: 1, spread: 0, in: brain, color: { _ in tint })
        }
        NSGraphicsContext.restoreGraphicsState()
        // Sparkles once the pieces meet.
        if t > 0.45 {
            let local = (t - 0.45) / 0.55
            for index in 0..<4 {
                let angle = CGFloat(index) * .pi / 2 + .pi / 4
                let distance = (5 + 4 * local) * unit
                let point = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance * 0.8)
                let size = (2.2 * sin(local * .pi)) * unit
                guard size > 0.2 else { continue }
                starPath(center: point, points: 4, outer: size, inner: size * 0.35, rotation: local)
                    .fill(color: (index.isMultiple(of: 2) ? NSColor.systemYellow : NSColor.white).withAlphaComponent(1 - local * 0.6))
            }
        }
    }

    /// Rises fast, peaks around 0.3, back to 0 at 1 with a small overshoot feel.
    private static func flyCurve(_ b: CGFloat) -> CGFloat {
        guard b > 0 else { return 0 }
        return sin(min(b, 1) * .pi) * exp(-2.5 * b) / 0.385
    }

    /// Deterministic per-shard pseudo-random in 0...1.
    private static func noise(_ index: Int, _ salt: Int) -> CGFloat {
        var x = UInt64(index &* 2_654_435_761 &+ salt &* 40_503)
        x ^= x >> 13
        x = x &* 0x5bd1e995
        x ^= x >> 15
        return CGFloat(x % 1000) / 1000
    }

    private static func starPath(center: CGPoint, points: Int, outer: CGFloat, inner: CGFloat, rotation: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        for index in 0..<(points * 2) {
            let radius = index.isMultiple(of: 2) ? outer : inner
            let angle = rotation + CGFloat(index) * .pi / CGFloat(points)
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            index == 0 ? path.move(to: point) : path.line(to: point)
        }
        path.close()
        return path
    }

    // MARK: geometry

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

private extension NSBezierPath {
    func fill(color: NSColor) {
        color.setFill()
        fill()
    }
}
