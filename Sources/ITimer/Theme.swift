import ITimerCore
import SwiftUI

enum Theme {
    /// Verdict colors — deliberately quiet, no neon.
    static let focused = Color.teal
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

    /// Shared chart band scale: focus / parallel / brain split.
    static var bandScale: KeyValuePairs<String, Color> {
        ["专注": focused, "并行": mild, "脑裂": brainSplit]
    }

    static let card = RoundedRectangle(cornerRadius: 14, style: .continuous)

    /// Deterministic tag colors — stable across sessions.
    private static let tagPalette: [Color] = [.teal, .indigo, .orange, .pink, .mint, .purple]

    static func tag(_ tag: String) -> Color {
        var hash: UInt64 = 5381
        for scalar in tag.unicodeScalars {
            hash = (hash &* 33) &+ UInt64(scalar.value)
        }
        return tagPalette[Int(hash % UInt64(tagPalette.count))]
    }
}

struct CardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(.thickMaterial, in: Theme.card)
            .overlay {
                Theme.card.stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
            }
    }
}

extension View {
    func cardSurface() -> some View {
        modifier(CardSurface())
    }
}

/// Breathing status dot used by the hero timer and task rows.
struct PulseDot: View {
    var color: Color
    var active: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
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
