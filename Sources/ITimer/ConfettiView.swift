import SwiftUI

struct ConfettiView: View {
    var seed: Int

    private struct Piece: Identifiable {
        var id: Int
        var x: CGFloat
        var speed: Double
        var drift: Double
        var phase: Double
        var rotation: Double
        var color: Color
        var size: CGFloat
    }

    private let pieces: [Piece]
    private let start = Date()

    init(seed: Int) {
        self.seed = seed
        var generator = SeededGenerator(seed: UInt64(truncatingIfNeeded: seed))
        let palette: [Color] = [.green, .orange, .pink, .mint, .cyan, .yellow]
        pieces = (0..<64).map { index in
            Piece(
                id: index,
                x: CGFloat(Double.random(in: 0...1, using: &generator)),
                speed: Double.random(in: 0.35...0.8, using: &generator),
                drift: Double.random(in: -30...30, using: &generator),
                phase: Double.random(in: 0...(.pi * 2), using: &generator),
                rotation: Double.random(in: 120...420, using: &generator),
                color: palette[index % palette.count],
                size: CGFloat(Double.random(in: 5...9, using: &generator))
            )
        }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(start)
                guard elapsed < 3 else { return }
                let fade = min(1, max(0, (3 - elapsed) / 0.8))
                for piece in pieces {
                    let y = -20 + piece.speed * elapsed * size.height
                    guard y < size.height + 30 else { continue }
                    let x = piece.x * size.width + sin(elapsed * 2.4 + piece.phase) * piece.drift
                    var copy = context
                    copy.opacity = fade
                    copy.translateBy(x: x, y: y)
                    copy.rotate(by: .degrees(piece.rotation * elapsed))
                    let rect = CGRect(x: -piece.size / 2, y: -piece.size / 2, width: piece.size, height: piece.size * 1.4)
                    copy.fill(Path(rect), with: .color(piece.color))
                }
            }
        }
        .drawingGroup()
        .accessibilityHidden(true)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
