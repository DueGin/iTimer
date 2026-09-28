import AppKit
import ITimerCore
import UserNotifications

@MainActor
final class NudgeCenter {
    static let shared = NudgeCenter()
    /// A single segment running this long is probably a forgotten timer.
    static let longRunThreshold: TimeInterval = 3 * 3600

    private let cooldown: TimeInterval = 15 * 60
    private var lastBrainSplitNudge: Date?
    private var lastVerdict: FocusVerdict = .idle
    /// One long-run nudge per segment, keyed by task id + segment start.
    private var longRunNudged: Set<String> = []

    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func observe(store: TaskStore) {
        observeVerdict(runningCount: store.runningCount, verdict: store.liveVerdict)
        observeLongRuns(store.runningTasks)
    }

    private func observeVerdict(runningCount: Int, verdict: FocusVerdict) {
        let previous = lastVerdict
        lastVerdict = verdict
        guard verdict != previous, Preferences.enabled(Preferences.brainSplitNudge) else { return }
        if verdict == .brainSplit {
            guard lastBrainSplitNudge.map({ Date().timeIntervalSince($0) >= cooldown }) ?? true else { return }
            lastBrainSplitNudge = Date()
            post(title: "脑子裂开了", body: "同时 \(runningCount) 个任务在计时。在菜单栏对最要紧的那个点 ◎「只做这个」，其他会先暂停。")
        } else if previous == .brainSplit {
            post(title: "合回来了", body: "并行度回到 \(runningCount)，继续。")
        }
    }

    private func observeLongRuns(_ running: [TaskItem]) {
        guard Preferences.enabled(Preferences.longRunNudge) else { return }
        let now = Date()
        for task in running {
            guard let start = task.currentStart, now.timeIntervalSince(start) >= Self.longRunThreshold else { continue }
            let key = "\(task.id.uuidString)-\(start.timeIntervalSinceReferenceDate)"
            guard longRunNudged.insert(key).inserted else { continue }
            let hours = Int(now.timeIntervalSince(start) / 3600)
            post(title: "「\(task.title)」已经连续计时 \(hours) 小时", body: "是不是忘了暂停？如果还在做，起来走两步再回来。")
        }
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: "itimer-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
