import AppKit
import ITimerCore
import Observation

/// Plays the menu bar brain-split explosion by swapping the status icon
/// frame by frame. Frames are driven by hand rather than SwiftUI animation
/// because the MenuBarExtra label only reliably redraws on value changes.
///
/// The panel closes whenever the label changes, so while it is open
/// (`TaskStore.isStatusFrozen`) the current frame is held and time stops;
/// the burst finishes after the panel closes.
@MainActor
@Observable
final class StatusEffects {
    static let shared = StatusEffects()

    /// Current burst frame; nil means "show the resting glyph".
    private(set) var frame: NSImage?

    /// Seconds between wobbles while the brain stays split.
    static let wobbleInterval: TimeInterval = 4
    static let frameRate: Double = 30

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var burst: SplitBrainIcon.Burst = .blast
    @ObservationIgnored private var pieces = 1
    @ObservationIgnored private var intensity: CGFloat = 1
    @ObservationIgnored private var elapsed: TimeInterval = 0
    @ObservationIgnored private var lastRunning = 0
    @ObservationIgnored private var nextWobble: Date?
    /// Exposed for the self-test.
    @ObservationIgnored private(set) var burstsPlayed = 0

    var isPlaying: Bool { timer != nil }

    /// Called from the app clock (once a second, only while the panel is
    /// closed) with the live running count.
    func heartbeat(running: Int, threshold: Int) {
        defer { lastRunning = running }
        let split = running >= threshold
        let wasSplit = lastRunning >= threshold
        guard split else {
            nextWobble = nil
            if wasSplit { play(.heal, pieces: lastRunning, intensity: 1) }
            return
        }
        if running > lastRunning {
            // Crossing the line, or one more piece on an already split brain.
            play(.blast, pieces: running, intensity: CGFloat(running - threshold + 1))
            nextWobble = Date().addingTimeInterval(Self.wobbleInterval)
        } else if let next = nextWobble, Date() >= next, !isPlaying {
            play(.wobble, pieces: running, intensity: 1)
            nextWobble = Date().addingTimeInterval(Self.wobbleInterval)
        } else if nextWobble == nil {
            nextWobble = Date().addingTimeInterval(Self.wobbleInterval)
        }
    }

    func play(_ burst: SplitBrainIcon.Burst, pieces: Int, intensity: CGFloat) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        self.burst = burst
        self.pieces = pieces
        self.intensity = intensity
        elapsed = 0
        burstsPlayed += 1
        timer?.invalidate()
        let timer = Timer(timeInterval: 1 / Self.frameRate, repeats: true) { _ in
            Task { @MainActor in StatusEffects.shared.step() }
        }
        // .common keeps frames coming while menus track the mouse.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        render()
    }

    private func step() {
        // Hold the frame while the panel is open.
        guard !TaskStore.shared.isStatusFrozen else { return }
        elapsed += 1 / Self.frameRate
        if elapsed >= burst.duration {
            timer?.invalidate()
            timer = nil
            frame = nil
            return
        }
        render()
    }

    private func render() {
        frame = SplitBrainIcon.burstFrame(burst, t: CGFloat(elapsed / burst.duration), pieces: pieces, intensity: intensity)
    }
}
