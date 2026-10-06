import AppKit
import ITimerCore
import SwiftUI

@main
struct ITimerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("iTimer", id: "main") {
            MainView(store: .shared)
        }
        .defaultSize(width: 1180, height: 780)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建任务") {
                    NotificationCenter.default.post(name: .iTimerFocusNewTask, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarView(store: .shared)
        } label: {
            StatusLabel(store: .shared)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: .shared)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var nudgeTimer: DispatchSourceTimer?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    private var clockTimer: DispatchSourceTimer?
    @MainActor private static var panelWasOpen = false

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
                if !panelOpen && AppDelegate.panelWasOpen {
                    NotificationCenter.default.post(name: .iTimerPanelClosed, object: nil)
                }
                AppDelegate.panelWasOpen = panelOpen
                // Brain buddies animate only while actually on screen.
                BuddyClock.panel.run(panelOpen)
                BuddyClock.window.run(NSApp.windows.contains {
                    $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
                        && $0.identifier?.rawValue.hasPrefix("main") == true
                })
                // A tick re-renders the task lists, and an open context menu
                // in the main window would be rebuilt with them (it flashes).
                if !panelOpen && !MenuTracking.isOpen {
                    store.tick()
                    StatusEffects.shared.heartbeat(
                        running: store.runningCount,
                        threshold: store.brainSplitThreshold
                    )
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
            ReminderCenter.shared.start(store: TaskStore.shared)
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler {
            Task { @MainActor in
                NudgeCenter.shared.observe(store: TaskStore.shared)
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
    var effects = StatusEffects.shared

    var body: some View {
        HStack(spacing: 1) {
            // A burst frame (colored) replaces the template glyph while the
            // brain-split explosion plays.
            if let frame = effects.frame {
                Image(nsImage: frame)
                    .renderingMode(.original)
            } else if store.liveVerdict == .brainSplit {
                // Same red as the burst frames, so the hand-off is seamless.
                Image(nsImage: SplitBrainIcon.statusImage(pieces: pieces, spread: spread, tint: .systemRed))
                    .renderingMode(.original)
            } else {
                Image(nsImage: SplitBrainIcon.statusImage(pieces: pieces, spread: spread))
                    .renderingMode(.template)
                    .foregroundStyle(iconColor)
            }
            if !store.statusLabel.isEmpty {
                Text(store.statusLabel)
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(store.statusAccessibilityLabel)
        .accessibilityIdentifier("status-item")
    }

    /// One piece per running task: 0–1 = whole brain, under the line =
    /// cracked into pieces, at or past it = pieces pulled apart.
    private var pieces: Int {
        max(1, store.statusRunningCount)
    }

    private var spread: CGFloat {
        switch store.liveVerdict {
        case .brainSplit: 1.0
        case .mild: SplitBrainIcon.crackSpread
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
    static let iTimerNewSchedule = Notification.Name("iTimerNewSchedule")
    /// Posted by the clock loop; SwiftUI's onDisappear does not fire for
    /// MenuBarExtra panels.
    static let iTimerPanelClosed = Notification.Name("iTimerPanelClosed")
}
