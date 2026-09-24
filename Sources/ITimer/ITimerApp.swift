import AppKit
import ITimerCore
import SwiftUI

@main
struct ITimerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            MainView(store: .shared)
        }
        .defaultSize(width: 1080, height: 720)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact)

        MenuBarExtra {
            MenuBarView(store: .shared)
        } label: {
            StatusLabel(store: .shared)
        }
        .menuBarExtraStyle(.window)

        Window("任务分析", id: "analysis") {
            AnalysisView(store: .shared)
        }
        .defaultSize(width: 780, height: 680)
        .windowResizability(.contentMinSize)
    }

    var commands: some Commands {
        CommandGroup(after: .newItem) {
            Button("新建任务") {
                NotificationCenter.default.post(name: .iTimerFocusNewTask, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var nudgeTimer: DispatchSourceTimer?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    private var clockTimer: DispatchSourceTimer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            CalendarManager.shared.attach(to: TaskStore.shared)
            startClock()
            SelfTest.runIfRequested()
        }
        startNudges()
    }

    /// MenuBarExtra dismisses its panel whenever the label view changes
    /// (observed: panel self-closes about 1s after open while a task ticks).
    /// Freeze the clock while the panel is open; it resumes on close.
    private func startClock() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler {
            Task { @MainActor in
                let store = TaskStore.shared
                let panelOpen = NSApp.windows.contains {
                    $0.isVisible && String(describing: type(of: $0)).contains("MenuBarExtra")
                }
                // Freeze is set by the panel's onAppear; the clock releases
                // it after close since onDisappear is unreliable here.
                if !panelOpen && store.isStatusFrozen {
                    store.setStatusFrozen(false)
                }
                if !panelOpen {
                    store.tick()
                }
            }
        }
        timer.resume()
        clockTimer = timer
    }

    private func startNudges() {
        guard DebugLaunchFile.current == nil else { return }
        Task { @MainActor in
            NudgeCenter.shared.start()
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler {
            Task { @MainActor in
                let store = TaskStore.shared
                NudgeCenter.shared.observe(runningCount: store.runningCount, verdict: store.liveVerdict)
            }
        }
        timer.resume()
        nudgeTimer = timer
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct StatusLabel: View {
    var store: TaskStore
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: SplitBrainIcon.image(split: splitAmount))
                .renderingMode(.template)
                .foregroundStyle(iconColor)
                .opacity(store.liveVerdict == .brainSplit && pulse ? 0.35 : 1)
                .animation(
                    store.liveVerdict == .brainSplit
                        ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                        : .default,
                    value: pulse
                )
                .onChange(of: store.liveVerdict, initial: true) { _, verdict in
                    pulse = verdict == .brainSplit
                }
            if !store.statusLabel.isEmpty {
                Text(store.statusLabel)
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(store.statusAccessibilityLabel)
        .accessibilityIdentifier("status-item")
    }

    /// 0 running = idle dim whole brain, 1 = whole, 2 = cracking, ≥line = split.
    private var splitAmount: CGFloat {
        switch store.liveVerdict {
        case .brainSplit: 1.0
        case .mild: 0.45
        case .focused, .idle: 0
        }
    }

    private var iconColor: Color {
        switch store.liveVerdict {
        case .brainSplit: .red
        case .idle: .secondary
        case .mild, .focused: .primary
        }
    }
}

extension Notification.Name {
    static let iTimerStartTask = Notification.Name("iTimerStartTask")
    static let iTimerPauseFirst = Notification.Name("iTimerPauseFirst")
    static let iTimerOpenAnalysis = Notification.Name("iTimerOpenAnalysis")
    static let iTimerFocusNewTask = Notification.Name("iTimerFocusNewTask")
}
