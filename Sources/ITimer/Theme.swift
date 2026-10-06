import AppKit
import ITimerCore
import SwiftUI

enum Theme {
    /// Verdict colors — deliberately quiet, no neon. System colors so they
    /// adapt to dark mode.
    /// Calm indigo for "one thing at a time"; a touch lighter in dark mode
    /// so it keeps contrast on dark surfaces.
    static let focused = Color(nsColor: NSColor(name: "iTimerFocused") { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(srgbRed: 0.52, green: 0.53, blue: 0.98, alpha: 1)
            : NSColor(srgbRed: 0.34, green: 0.35, blue: 0.84, alpha: 1)
    })
    static let mild = Color.orange
    static let brainSplit = Color.pink

    static func verdict(_ verdict: FocusVerdict) -> Color {
        switch verdict {
        case .focused: focused
        case .mild: mild
        case .brainSplit: brainSplit
        case .idle: .secondary
        }
    }

    /// Color for "n threads running right now".
    static func load(_ running: Int, threshold: Int) -> Color {
        verdict(ParallelismAnalyzer.liveVerdict(runningCount: running, threshold: threshold))
    }

    static func tier(_ tier: FocusTier) -> Color {
        switch tier {
        case .flow: focused
        case .steady: .blue
        case .scattered: mild
        case .overloaded: brainSplit
        }
    }

    /// Shared chart band scale: focus / parallel / brain split.
    static var bandScale: KeyValuePairs<String, Color> {
        ["专注": focused, "并行": mild, "脑裂": brainSplit]
    }

    static func band(_ concurrency: Int, threshold: Int) -> String {
        if concurrency >= threshold { return "脑裂" }
        if concurrency >= 2 { return "并行" }
        return "专注"
    }

    static func bandColor(_ concurrency: Int, threshold: Int) -> Color {
        if concurrency >= threshold { return brainSplit }
        if concurrency >= 2 { return mild }
        return focused
    }

    static let card = RoundedRectangle(cornerRadius: 14, style: .continuous)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)

    /// Deterministic tag colors — stable across sessions. Orange and pink
    /// are reserved for "parallel" and "brain split", so tags never use them.
    private static let tagPalette: [Color] = [.blue, .green, .purple, .brown, .mint, .teal]

    static func tag(_ tag: String) -> Color {
        if tag == TagStats.untagged { return .gray }
        var hash: UInt64 = 5381
        for scalar in tag.unicodeScalars {
            hash = (hash &* 33) &+ UInt64(scalar.value)
        }
        return tagPalette[Int(hash % UInt64(tagPalette.count))]
    }

    static func lane(tags: [String]) -> Color {
        tags.first.map(tag) ?? focused
    }

    /// Collection colors a user can pick from; orange and pink stay reserved.
    static let collectionPalette: [Color] = [.blue, .green, .purple, .teal, .brown, .mint, .cyan, .indigo]

    static func collectionColor(index: Int) -> Color {
        collectionPalette[((index % collectionPalette.count) + collectionPalette.count) % collectionPalette.count]
    }

    /// Color of a collection by id, from the shared store; gray when the
    /// task is not filed in one, or the collection is gone.
    @MainActor
    static func collection(_ id: UUID?) -> Color {
        TaskStore.shared.collection(id: id).map { collectionColor(index: $0.color) } ?? .gray
    }

    /// Lanes follow the collection when the task is filed, else the first tag.
    @MainActor
    static func lane(_ span: LaneSpan) -> Color {
        span.collectionID != nil ? collection(span.collectionID) : lane(tags: span.tags)
    }
}

/// Lays chips out left to right, wrapping to new lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.items.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.items.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.items.append(index)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

struct CardSurface: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.surface, in: Theme.card)
            .overlay {
                Theme.card.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }
}

extension View {
    func cardSurface(padding: CGFloat = 16) -> some View {
        modifier(CardSurface(padding: padding))
    }
}

/// Breathing status dot.
struct PulseDot: View {
    var color: Color
    var active: Bool
    var size: CGFloat = 8
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(active ? (pulse ? 0.35 : 1) : 1)
            .scaleEffect(active && pulse ? 1.35 : 1)
            .animation(
                active ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .default,
                value: pulse
            )
            .onAppear { pulse = active }
            .onChange(of: active) { _, new in
                pulse = false
                pulse = new
            }
            .accessibilityHidden(true)
    }
}

/// "Brain capacity" meter: one slot per thread up to the brain-split line,
/// filled for each running task. Overflow past the line adds pink slots.
struct ThreadMeter: View {
    var running: Int
    var threshold: Int
    var slotWidth: CGFloat = 18

    var body: some View {
        let slots = max(threshold, running)
        let color = Theme.load(running, threshold: threshold)
        HStack(spacing: 3) {
            ForEach(0..<slots, id: \.self) { index in
                Capsule()
                    .fill(index < running ? color : Color.primary.opacity(0.1))
                    .frame(width: slotWidth, height: 5)
                    .overlay {
                        // Marks the slot that tips you into brain split.
                        if index == threshold - 1, index >= running {
                            Capsule().strokeBorder(Theme.brainSplit.opacity(0.45), lineWidth: 0.5)
                        }
                    }
            }
        }
        .animation(.spring(duration: 0.35), value: running)
        .accessibilityElement()
        .accessibilityLabel("线程 \(running) / 脑裂线 \(threshold)")
    }
}

/// Thin horizontal strip of a time window, colored by concurrency band.
/// Idle gaps stay faint so fragmentation reads at a glance.
struct LoadRibbon: View {
    var slices: [ConcurrencySlice]
    var window: DateInterval
    var threshold: Int
    var height: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            let total = window.duration
            guard total > 0 else { return }
            for slice in slices where slice.concurrency > 0 {
                let start = max(slice.start, window.start)
                let end = min(slice.end, window.end)
                guard end > start else { continue }
                let x = start.timeIntervalSince(window.start) / total * size.width
                let width = max(1, end.timeIntervalSince(start) / total * size.width)
                let rect = CGRect(x: x, y: 0, width: width, height: size.height)
                context.fill(Path(rect), with: .color(Theme.bandColor(slice.concurrency, threshold: threshold)))
            }
        }
        .frame(height: height)
        .background(Color.primary.opacity(0.07))
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// Focus score dial.
struct ScoreRing: View {
    var score: Int?
    var lineWidth: CGFloat = 10
    var size: CGFloat = 112

    var body: some View {
        let tier = score.map(FocusScore.tier(for:))
        let color = tier.map(Theme.tier) ?? .secondary
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.07), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(score ?? 0) / 100)
                .stroke(
                    AngularGradient(colors: [color.opacity(0.55), color], center: .center),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 0.6), value: score)
            VStack(spacing: 0) {
                Text(score.map(String.init) ?? "–")
                    .font(.system(size: size * 0.3, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(tier?.title ?? "专注度")
                    .font(.system(size: size * 0.11, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(score.map { "专注度 \($0)，\(tier?.title ?? "")" } ?? "暂无专注度")
    }
}

/// Small borderless icon button used in task rows. Hover tints the icon
/// and lights a circle behind it; press squashes it slightly.
struct IconButton: View {
    var title: String
    var systemImage: String
    var tint: Color = .primary
    var identifier: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(HoverButtonStyle(
            shape: .circle,
            tint: tint == .primary ? .primary : tint,
            hover: 0.13,
            hoverScale: 1.08,
            restForeground: tint,
            hoverForeground: tint == .primary ? .primary : tint
        ))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

/// The one hover/press language for every custom button in the app:
/// a tinted fill fades in on hover, an optional small lift, a squash on
/// press, and optionally a foreground color change.
struct HoverButtonStyle: ButtonStyle {
    enum Shape {
        case circle
        case capsule
        case rounded
    }

    var shape: Shape = .capsule
    var tint: Color = .primary
    /// Fill opacity at rest, on hover.
    var rest: Double = 0
    var hover: Double = 0.1
    var hoverScale: CGFloat = 1
    var restForeground: Color? = nil
    var hoverForeground: Color? = nil
    var padding = EdgeInsets()

    func makeBody(configuration: Configuration) -> some View {
        HoverSurface(style: self, pressed: configuration.isPressed) {
            configuration.label
        }
    }
}

/// Lives in a View because @State is not reliable inside a ButtonStyle.
private struct HoverSurface<Label: View>: View {
    var style: HoverButtonStyle
    var pressed: Bool
    @ViewBuilder var label: Label
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let shape = anyShape
        let opacity = pressed ? style.hover + 0.1 : (hovering ? style.hover : style.rest)
        foregrounded
            .padding(style.padding)
            .background(shape.fill(style.tint.opacity(opacity)))
            .contentShape(shape)
            .scaleEffect(pressed ? 0.92 : (hovering ? style.hoverScale : 1))
            .animation(.easeOut(duration: 0.14), value: hovering)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: pressed)
            .onHover { hovering = enabled && $0 }
    }

    @ViewBuilder
    private var foregrounded: some View {
        if style.restForeground != nil || style.hoverForeground != nil {
            let rest = style.restForeground.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary)
            let hover = style.hoverForeground.map { AnyShapeStyle($0) } ?? rest
            label.foregroundStyle(hovering ? hover : rest)
        } else {
            label
        }
    }

    private var anyShape: AnyShape {
        switch style.shape {
        case .circle: AnyShape(Circle())
        case .capsule: AnyShape(Capsule())
        case .rounded: AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// Small tinted capsule action ("完成", "继续", "显示全部").
struct PillButtonStyle: ButtonStyle {
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        HoverButtonStyle(
            shape: .capsule,
            tint: tint,
            rest: 0.1,
            hover: 0.22,
            restForeground: tint,
            hoverForeground: tint,
            padding: EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10)
        )
        .makeBody(configuration: configuration)
        .font(.caption.weight(.semibold))
    }
}

/// Form footer actions: a solid primary ("添加日程") and a quiet secondary
/// ("现在就开始") of the same height. Disabled reads as neutral grey rather
/// than a washed-out tint.
struct ActionButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color = Theme.focused

    func makeBody(configuration: Configuration) -> some View {
        ActionButtonBody(style: self, configuration: configuration)
    }
}

private struct ActionButtonBody: View {
    var style: ActionButtonStyle
    var configuration: ButtonStyle.Configuration
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let pressed = configuration.isPressed
        configuration.label
            .font(.callout.weight(.semibold))
            .labelStyle(ActionLabelStyle())
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(shape.fill(fill(pressed: pressed)))
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .shadow(color: enabled && style.prominent ? style.tint.opacity(hovering ? 0.45 : 0.3) : .clear, radius: hovering ? 6 : 3, y: 1)
            .contentShape(shape)
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.14), value: hovering)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: pressed)
            .onHover { hovering = enabled && $0 }
    }

    private var foreground: AnyShapeStyle {
        guard enabled else { return AnyShapeStyle(.tertiary) }
        return style.prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(style.tint)
    }

    private func fill(pressed: Bool) -> Color {
        guard enabled else { return Color.primary.opacity(scheme == .dark ? 0.08 : 0.05) }
        if style.prominent {
            return pressed ? style.tint.opacity(0.8) : (hovering ? style.tint.opacity(0.9) : style.tint)
        }
        return style.tint.opacity(pressed ? 0.22 : (hovering ? 0.16 : 0.08))
    }

    private var border: Color {
        guard enabled else { return Color.primary.opacity(0.08) }
        return style.prominent ? .white.opacity(0.12) : style.tint.opacity(hovering ? 0.5 : 0.3)
    }
}

/// Icon + title with a tighter gap and a smaller icon.
private struct ActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 10, weight: .bold))
            configuration.title
        }
    }
}
