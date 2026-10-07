import AppKit
import ITimerCore
import SwiftUI

/// Workflow card size and canvas limits, in canvas points. Cards have a
/// fixed size so lines can anchor to their sides without measuring.
enum CanvasMetrics {
    static let card = CGSize(width: 220, height: 84)
    static let grid: CGFloat = 24
    static let scaleRange: ClosedRange<CGFloat> = 0.3...2
    /// Spacing used for new steps and the tidy-up layout.
    static let column: CGFloat = 280
    static let row: CGFloat = 120
}

/// Pan and zoom: screen = canvas × scale + offset.
struct CanvasTransform: Equatable {
    var offset: CGSize = .zero
    var scale: CGFloat = 1

    init(offset: CGSize = .zero, scale: CGFloat = 1) {
        self.offset = offset
        self.scale = scale
    }

    init(_ viewport: WorkflowViewport) {
        offset = CGSize(width: viewport.x, height: viewport.y)
        scale = min(max(viewport.scale, CanvasMetrics.scaleRange.lowerBound), CanvasMetrics.scaleRange.upperBound)
    }

    var viewport: WorkflowViewport {
        WorkflowViewport(x: offset.width, y: offset.height, scale: scale)
    }

    func screen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scale + offset.width, y: point.y * scale + offset.height)
    }

    func canvas(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.width) / scale, y: (point.y - offset.height) / scale)
    }

    /// Zooms keeping the canvas point under `anchor` where it is on screen.
    mutating func zoom(by factor: CGFloat, around anchor: CGPoint) {
        let target = min(max(scale * factor, CanvasMetrics.scaleRange.lowerBound), CanvasMetrics.scaleRange.upperBound)
        let fixed = canvas(anchor)
        scale = target
        offset = CGSize(width: anchor.x - fixed.x * target, height: anchor.y - fixed.y * target)
    }

    /// Centers `rect` in a view of `size`, zoomed out as needed but never in
    /// past 100%, so a lone card does not fill the window.
    static func fitting(_ rect: CGRect, in size: CGSize) -> CanvasTransform {
        guard size.width > 0, size.height > 0 else { return CanvasTransform() }
        let padded = rect.insetBy(dx: -60, dy: -60)
        let fit = min(size.width / padded.width, size.height / padded.height)
        let scale = min(1, max(CanvasMetrics.scaleRange.lowerBound, fit))
        return CanvasTransform(
            offset: CGSize(width: size.width / 2 - padded.midX * scale, height: size.height / 2 - padded.midY * scale),
            scale: scale
        )
    }
}

/// One dependency line in screen space: a cubic leaving the upstream card's
/// right side and arriving at the downstream card's left side.
struct EdgeGeometry: Identifiable {
    enum Style {
        /// Upstream is done: solid.
        case met
        /// Upstream still open: dashed.
        case waiting
        /// Being drawn, or previewing where a new step will hang.
        case draft
    }

    var id: String
    var edge: WorkflowEdge?
    var start: CGPoint
    var end: CGPoint
    var scale: CGFloat
    var style: Style

    private var arrowLength: CGFloat { 9 * scale }
    private var base: CGPoint { CGPoint(x: end.x - arrowLength, y: end.y) }

    private var controls: (CGPoint, CGPoint) {
        let reach = max(40 * scale, abs(base.x - start.x) / 2)
        return (CGPoint(x: start.x + reach, y: start.y), CGPoint(x: base.x - reach, y: base.y))
    }

    var curve: Path {
        let (first, second) = controls
        var path = Path()
        path.move(to: start)
        path.addCurve(to: base, control1: first, control2: second)
        return path
    }

    var arrow: Path {
        let half = arrowLength * 0.55
        var path = Path()
        path.move(to: end)
        path.addLine(to: CGPoint(x: base.x, y: end.y - half))
        path.addLine(to: CGPoint(x: base.x, y: end.y + half))
        path.closeSubpath()
        return path
    }

    func point(at t: CGFloat) -> CGPoint {
        let (first, second) = controls
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(
            x: a * start.x + b * first.x + c * second.x + d * base.x,
            y: a * start.y + b * first.y + c * second.y + d * base.y
        )
    }

    var midpoint: CGPoint { point(at: 0.5) }

    /// Distance from `point` to the curve, measured on a sampled polyline.
    func distance(to point: CGPoint) -> CGFloat {
        var best = CGFloat.infinity
        var previous = start
        for step in 1...24 {
            let next = self.point(at: CGFloat(step) / 24)
            best = min(best, Self.distance(point, from: previous, to: next))
            previous = next
        }
        return min(best, Self.distance(point, from: base, to: end))
    }

    private static func distance(_ point: CGPoint, from a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        let t = length == 0 ? 0 : max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }
}

/// Card size and spacing for one kind of canvas, in canvas points.
struct CanvasLayout {
    var card: CGSize
    /// Spacing used for new cards and the tidy-up layout.
    var column: CGFloat
    var row: CGFloat

    static let workflow = CanvasLayout(card: CanvasMetrics.card, column: CanvasMetrics.column, row: CanvasMetrics.row)
    /// Milestones carry more on a card, so cards are larger and further apart.
    static let goal = CanvasLayout(card: CGSize(width: 260, height: 116), column: CGFloat(Goal.columnGap), row: CGFloat(Goal.rowGap))
}

/// Dot grid that pans and zooms with the canvas. Dots thin out when zoomed
/// far out so the background never turns to noise.
struct CanvasGrid: View {
    var transform: CanvasTransform

    var body: some View {
        Canvas { context, size in
            var step = CanvasMetrics.grid * transform.scale
            while step < 14 { step *= 2 }
            let radius = max(0.7, min(1.2, transform.scale))
            let startX = (transform.offset.width.truncatingRemainder(dividingBy: step) + step).truncatingRemainder(dividingBy: step)
            let startY = (transform.offset.height.truncatingRemainder(dividingBy: step) + step).truncatingRemainder(dividingBy: step)
            var dots = Path()
            var x = startX
            while x < size.width {
                var y = startY
                while y < size.height {
                    dots.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    y += step
                }
                x += step
            }
            context.fill(dots, with: .color(.primary.opacity(0.14)))
        }
        .accessibilityHidden(true)
    }
}

/// Every dependency line, drawn in one pass. Hit testing happens in the
/// canvas view, against the same geometry.
struct EdgeLayer: View {
    var edges: [EdgeGeometry]
    var hovered: String?
    var selected: String?

    var body: some View {
        Canvas { context, _ in
            for edge in edges {
                let lit = edge.id == hovered || edge.id == selected
                let color: Color = switch edge.style {
                case _ where edge.id == selected: .accentColor
                case .met: Theme.focused.opacity(lit ? 1 : 0.75)
                case .waiting: Color.primary.opacity(lit ? 0.6 : 0.3)
                case .draft: Theme.focused
                }
                let width = (lit ? 2.6 : 1.7) * max(0.7, edge.scale)
                let dash: [CGFloat] = edge.style == .met ? [] : [5 * edge.scale, 4 * edge.scale]
                context.stroke(edge.curve, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
                context.fill(edge.arrow, with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The handle on a card's right side: drag it onto another card to wire
/// "this before that", or click it to add the next card.
struct OutputPort: View {
    var selected: Bool
    var help: String
    var label: String
    var onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Circle()
                .fill(hovering ? Theme.focused : Theme.surface)
            Circle()
                .strokeBorder(Theme.focused.opacity(hovering || selected ? 1 : 0.5), lineWidth: 1.5)
            Image(systemName: "plus")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(hovering ? Color.white : Theme.focused)
                .opacity(hovering || selected ? 1 : 0)
        }
        .frame(width: 16, height: 16)
        .scaleEffect(hovering ? 1.2 : 1)
        .contentShape(Circle().inset(by: -4))
        .onHover { inside in
            guard !MenuTracking.isOpen else { return }
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .onTapGesture(perform: onTap)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
    }
}

struct CanvasScroll {
    var delta: CGSize
    var location: CGPoint
    /// Trackpad (continuous) rather than a notched wheel.
    var precise: Bool
    /// ⌘ held: zoom instead of pan.
    var zooms: Bool
}

/// SwiftUI on macOS 14 has no scroll-wheel or pinch events for a plain view,
/// so watch them app-wide and claim the ones over the canvas.
struct CanvasEventCatcher: NSViewRepresentable {
    var onScroll: (CanvasScroll) -> Void
    var onMagnify: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.handlers = self
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.handlers = self
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.stop()
    }

    final class CatcherView: NSView {
        var handlers: CanvasEventCatcher?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        /// Clicks go to the SwiftUI views above.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                // Local monitors run on the main thread.
                nonisolated(unsafe) let event = event
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window, !isHiddenOrHasHiddenAncestor else { return false }
            let windowPoint: NSPoint
            if let target = event.window {
                guard target === window else { return false }
                windowPoint = event.locationInWindow
            } else {
                // Events posted by other tools may come without a window;
                // their location is then on screen.
                guard NSWindow.windowNumber(at: event.locationInWindow, belowWindowWithWindowNumber: 0) == window.windowNumber else { return false }
                windowPoint = window.convertPoint(fromScreen: event.locationInWindow)
            }
            return deliver(event, at: convert(windowPoint, from: nil))
        }

        /// Handles a scroll or pinch at a point in this view.
        @discardableResult
        func deliver(_ event: NSEvent, at point: CGPoint) -> Bool {
            guard let handlers, bounds.contains(point) else { return false }
            switch event.type {
            case .scrollWheel:
                handlers.onScroll(CanvasScroll(
                    delta: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
                    location: point,
                    precise: event.hasPreciseScrollingDeltas,
                    zooms: event.modifierFlags.contains(.command)
                ))
            case .magnify:
                handlers.onMagnify(event.magnification, point)
            default:
                return false
            }
            return true
        }
    }
}
