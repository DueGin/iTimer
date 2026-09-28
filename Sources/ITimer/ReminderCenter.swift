import AppKit
import ITimerCore
import UserNotifications

/// Mirrors `ReminderPlan` into pending system notifications, and turns the
/// notification buttons back into store actions.
@MainActor
final class ReminderCenter: NSObject, ScheduleReminding {
    static let shared = ReminderCenter()

    private static let scheduleCategory = "itimer.schedule"
    private static let startAction = "itimer.start"
    private static let snoozeAction = "itimer.snooze"
    private static let snoozeInterval: TimeInterval = 10 * 60

    /// What we have handed to the system, keyed by request identifier.
    private var pending: [String: PlannedReminder] = [:]
    private weak var store: TaskStore?

    func start(store: TaskStore) {
        // UNUserNotificationCenter traps outside an app bundle (`swift run`).
        guard self.store == nil, Bundle.main.bundleIdentifier != nil else { return }
        self.store = store
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let start = UNNotificationAction(identifier: Self.startAction, title: "开始计时", options: [])
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "推迟 10 分钟", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.scheduleCategory, actions: [start, snooze], intentIdentifiers: [])
        ])
        // Leftovers from a previous run; the store re-plans everything now.
        center.removeAllPendingNotificationRequests()
        store.reminders = self
    }

    func reconcile(_ reminders: [PlannedReminder]) {
        let now = Date()
        var desired: [String: PlannedReminder] = [:]
        for reminder in reminders where reminder.fireAt > now {
            desired[reminder.identifier] = reminder
        }
        let center = UNUserNotificationCenter.current()
        let stale = pending.keys.filter { desired[$0] != pending[$0] }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
            stale.forEach { pending[$0] = nil }
        }
        for (identifier, reminder) in desired where pending[identifier] == nil {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            content.userInfo = ["taskID": reminder.taskID.uuidString]
            if reminder.kind != .overtime {
                content.categoryIdentifier = Self.scheduleCategory
            }
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, reminder.fireAt.timeIntervalSince(now)),
                repeats: false
            )
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
            pending[identifier] = reminder
        }
    }

    fileprivate func handle(action: String, taskID: UUID?) {
        guard let store, let taskID else { return }
        store.tick()
        switch action {
        case Self.startAction:
            store.resume(id: taskID)
        case Self.snoozeAction:
            store.postpone(id: taskID, by: Self.snoozeInterval)
        default:
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

extension ReminderCenter: UNUserNotificationCenterDelegate {
    /// The app is usually frontmost-ish (menu bar); show banners anyway.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let taskID = (response.notification.request.content.userInfo["taskID"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            ReminderCenter.shared.handle(action: action, taskID: taskID)
        }
        completionHandler()
    }
}
