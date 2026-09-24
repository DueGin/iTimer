import AppKit
import ITimerCore
import UserNotifications

@MainActor
final class NudgeCenter {
    static let shared = NudgeCenter()

    private let cooldown: TimeInterval = 15 * 60
    private var lastBrainSplitNudge: Date?
    private var lastVerdict: FocusVerdict = .idle

    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    func observe(runningCount: Int, verdict: FocusVerdict) {
        let previous = lastVerdict
        lastVerdict = verdict
        guard verdict != previous else { return }
        if verdict == .brainSplit {
            guard lastBrainSplitNudge.map({ Date().timeIntervalSince($0) >= cooldown }) ?? true else { return }
            lastBrainSplitNudge = Date()
            post(title: "脑子裂开了", body: "同时 \(runningCount) 个任务在计时。按住一个，其他先暂停？")
        } else if previous == .brainSplit {
            post(title: "合回来了", body: "并行度回到 \(runningCount)，继续。")
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
