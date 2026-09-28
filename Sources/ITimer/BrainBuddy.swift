import AppKit
import SwiftUI

/// The panel's mascot: the status item's brain, one piece per running task,
/// with an eye on every piece so each "thread" looks its own way.
/// Hover pulls the pieces apart; a click pokes it (the hero shows a quip).
struct BrainBuddy: View {
    var running: Int
    var threshold: Int
    var tint: Color
    /// Animation clock for where it lives; a stopped clock draws a still.
    var clock: BuddyClock = .still
    var onPoke: () -> Void = {}

    @State private var hovering = false
    @State private var pokedAt = Date.distantPast
    @State private var changedAt = Date.distantPast
    @State private var grew = true

    var body: some View {
        // Driven by a shared clock that the app loop starts and stops, not
        // TimelineView or onAppear: inside the MenuBarExtra panel neither
        // timeline schedule fires, and lifecycle callbacks do not repeat on
        // reopen — it only redrew on the panel's once-a-second refresh.
        let now = clock.now
        Canvas { canvas, size in
            draw(in: &canvas, size: size, now: now)
        }
        .frame(width: 64, height: 56)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            pokedAt = Date()
            onPoke()
        }
        .onChange(of: running) { old, new in
            grew = new > old
            changedAt = Date()
        }
        .help(running >= 2 ? "戳一下 · 悬停把 \(running) 块脑子掰开看看" : "戳一下")
        .accessibilityElement()
        .accessibilityLabel(running >= 2 ? "脑子裂成 \(running) 块" : "脑子完整")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("brain-buddy")
    }

    private func draw(in canvas: inout GraphicsContext, size: CGSize, now: Date) {
        let t = now.timeIntervalSinceReferenceDate
        let unit = min(size.width / 64, size.height / 56)
        let pieces = min(SplitBrainIcon.maxPieces, max(1, running))
        let split = running >= threshold

        // Resting layout, hover spread, and a pop when a task starts.
        // Event stamps come from Date(); the timeline's date can lag
        // behind it, so a negative gap counts as "not started yet".
        let sinceChange = now.timeIntervalSince(changedAt)
        let change = (0..<0.7).contains(sinceChange) ? CGFloat(1 - sinceChange / 0.7) : 0
        var spread: CGFloat = split ? 1 : (running >= 2 ? SplitBrainIcon.crackSpread : 0)
        if hovering && running >= 2 { spread += 0.9 }
        if grew && running >= 2 { spread += 1.8 * change * change }

        // Poke: damped wiggle. Shrinking: a little squash as pieces rejoin.
        let sincePoke = now.timeIntervalSince(pokedAt)
        let poke = (0..<0.7).contains(sincePoke) ? CGFloat(sin(sincePoke / 0.7 * .pi * 4) * (1 - sincePoke / 0.7)) : 0
        let squash = !grew ? 0.12 * change * CGFloat(sin(Double(change) * .pi)) : 0

        // More pieces past the line = more restless.
        let jitter: CGFloat = split ? min(2.4, 0.9 + 0.5 * CGFloat(running - threshold)) : (running >= 2 ? 0.5 : 0)
        let bob = CGFloat(sin(t * (running == 0 ? 1.4 : 2.6))) * (running == 0 ? 0.6 : 1)

        let side = 42 * unit
        // Canvas is y-down; the icon geometry is y-up, so draw in a flipped frame.
        let brain = CGRect(x: (size.width - side) / 2, y: (size.height - side * 0.9) / 2 + bob * unit, width: side, height: side * 0.9)
        let center = CGPoint(x: brain.midX, y: brain.midY)
        let directions = SplitBrainIcon.directions(pieces: pieces)
        let poses: [SplitBrainIcon.PiecePose] = directions.enumerated().map { index, direction in
            let phase = t * (4.5 + Double(index) * 0.9) + Double(index) * 1.7
            let wiggle = jitter * CGFloat(sin(phase)) * unit
            return SplitBrainIcon.PiecePose(
                offset: CGVector(dx: direction.dx * wiggle, dy: direction.dy * wiggle),
                rotation: (index.isMultiple(of: 2) ? 1 : -1) * (0.3 * poke + (split ? 0.05 * CGFloat(sin(phase * 0.7)) : 0)),
                scale: 1 + (running == 1 ? 0.03 * CGFloat(sin(t * 2.2)) : 0)
            )
        }
        let base = NSColor(tint)
        let colors = (0..<pieces).map { index in
            index.isMultiple(of: 2) ? base : (base.blended(withFraction: 0.22, of: .white) ?? base)
        }
        let gap = SplitBrainIcon.spreadDistance(spread, in: brain)

        canvas.withCGContext { cg in
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
            // Squash about the bottom so it looks like it lands.
            cg.translateBy(x: center.x, y: brain.minY)
            cg.scaleBy(x: 1 + squash + 0.06 * abs(poke), y: 1 - squash - 0.06 * abs(poke))
            cg.translateBy(x: -center.x, y: -brain.minY)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
            SplitBrainIcon.drawBrain(
                pieces: pieces,
                spread: spread,
                in: brain,
                pose: { index, _ in poses[index] },
                color: { colors[$0] }
            )
            drawEyes(
                pieces: pieces,
                directions: directions,
                poses: poses,
                gap: gap,
                brain: brain,
                t: t,
                poked: (0..<0.6).contains(sincePoke)
            )
            NSGraphicsContext.restoreGraphicsState()
        }

        if running == 0 {
            // Asleep: little z's drifting up.
            for index in 0..<2 {
                let cycle = (t * 0.5 + Double(index) * 0.5).truncatingRemainder(dividingBy: 1)
                let point = CGPoint(
                    x: brain.maxX - 2 * unit + CGFloat(cycle) * 8 * unit,
                    y: size.height - brain.maxY + 2 * unit - CGFloat(cycle) * 14 * unit
                )
                canvas.draw(
                    Text("z").font(.system(size: (8 + CGFloat(index) * 3) * unit, weight: .bold, design: .rounded))
                        .foregroundColor(Color(nsColor: .systemGray).opacity(1 - cycle)),
                    at: point
                )
            }
        }
    }

    /// One eye per piece; a whole brain gets two. Asleep = closed,
    /// poked = squeezed shut, split = every eye rolls its own way.
    private func drawEyes(
        pieces: Int,
        directions: [CGVector],
        poses: [SplitBrainIcon.PiecePose],
        gap: CGFloat,
        brain: CGRect,
        t: TimeInterval,
        poked: Bool
    ) {
        let center = CGPoint(x: brain.midX, y: brain.midY)
        var eyes: [(point: CGPoint, look: CGFloat?)] = []
        if pieces == 1 {
            let y = center.y + brain.height * 0.06 + poses[0].offset.dy
            // Blink for a moment every few seconds.
            let blinking = t.truncatingRemainder(dividingBy: 3.7) < 0.13
            for sign in [-1.0, 1.0] as [CGFloat] {
                eyes.append((CGPoint(x: center.x + sign * brain.width * 0.18, y: y), blinking || running == 0 ? nil : .pi * 1.5))
            }
        } else {
            let split = running >= threshold
            for (index, direction) in directions.enumerated() {
                let point = CGPoint(
                    x: center.x + direction.dx * (brain.width * 0.22 + gap) + poses[index].offset.dx,
                    y: center.y + direction.dy * (brain.height * 0.22 + gap) + poses[index].offset.dy
                )
                // Two pieces glare at each other; more pieces roll their eyes.
                let look = split
                    ? CGFloat(t * (1.6 + Double(index) * 0.45) * (index.isMultiple(of: 2) ? 1 : -1))
                    : atan2(-direction.dy, -direction.dx)
                eyes.append((point, look))
            }
        }

        let radius = brain.width * (pieces <= 2 ? 0.1 : 0.085)
        let ink = NSColor(white: 0.12, alpha: 1)
        for eye in eyes {
            if poked {
                // "> <"
                let path = NSBezierPath()
                let flip: CGFloat = eye.point.x < center.x ? 1 : -1
                path.move(to: CGPoint(x: eye.point.x - flip * radius * 0.7, y: eye.point.y + radius * 0.7))
                path.line(to: CGPoint(x: eye.point.x + flip * radius * 0.5, y: eye.point.y))
                path.line(to: CGPoint(x: eye.point.x - flip * radius * 0.7, y: eye.point.y - radius * 0.7))
                path.lineWidth = radius * 0.45
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                ink.setStroke()
                path.stroke()
                continue
            }
            guard let look = eye.look else {
                // Closed: a small smile-shaped lid.
                let path = NSBezierPath()
                path.appendArc(withCenter: CGPoint(x: eye.point.x, y: eye.point.y + radius * 0.3), radius: radius * 0.8, startAngle: 200, endAngle: 340)
                path.lineWidth = radius * 0.4
                path.lineCapStyle = .round
                ink.setStroke()
                path.stroke()
                continue
            }
            NSColor.white.setFill()
            NSBezierPath(ovalIn: CGRect(x: eye.point.x - radius, y: eye.point.y - radius, width: radius * 2, height: radius * 2)).fill()
            let pupil = radius * 0.55
            let reach = radius - pupil - radius * 0.08
            let px = eye.point.x + cos(look) * reach
            let py = eye.point.y + sin(look) * reach
            ink.setFill()
            NSBezierPath(ovalIn: CGRect(x: px - pupil, y: py - pupil, width: pupil * 2, height: pupil * 2)).fill()
        }
    }
}

/// 30fps clock for the brain buddies. The app's clock loop runs `.panel`
/// while the status panel is open and `.window` while the main window is on
/// screen. A run-loop timer in `.common` mode keeps ticking while the panel
/// tracks the mouse.
@MainActor
@Observable
final class BuddyClock {
    static let panel = BuddyClock(place: "panel")
    static let window = BuddyClock(place: "window")
    /// Never runs; for offscreen renders.
    static let still = BuddyClock(place: "still")
    static let frameRate: Double = 30

    /// Frames ticked so far; the self-test checks the frame rate.
    @ObservationIgnored private(set) var ticks = 0
    private(set) var now = Date()
    @ObservationIgnored let place: String
    @ObservationIgnored private var timer: Timer?

    private init(place: String) {
        self.place = place
    }

    var isRunning: Bool { timer != nil }

    func run(_ on: Bool) {
        guard on != isRunning, self !== Self.still else { return }
        timer?.invalidate()
        timer = nil
        guard on else { return }
        let timer = Timer(timeInterval: 1 / Self.frameRate, repeats: true) { _ in
            MainActor.assumeIsolated { BuddyClock.tick(place: self.place) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        now = Date()
    }

    private static func tick(place: String) {
        let clock = place == panel.place ? panel : window
        clock.now = Date()
        clock.ticks += 1
    }
}
