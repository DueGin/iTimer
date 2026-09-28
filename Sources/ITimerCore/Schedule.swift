import Foundation

/// Choices offered when creating a schedule.
public enum ScheduleOptions {
    /// Estimated durations, in seconds.
    public static let durations: [TimeInterval] = [30, 60, 90, 120, 180, 240].map { $0 * 60 }
    public static let defaultDuration: TimeInterval = 60 * 60

    /// Reminder leads; nil = no reminder, 0 = at start time.
    public static let reminderLeads: [TimeInterval?] = [nil, 0, 5 * 60, 15 * 60, 30 * 60, 60 * 60]
    public static let defaultReminderLead: TimeInterval? = 5 * 60

    public static func reminderTitle(_ lead: TimeInterval?) -> String {
        guard let lead else { return "不提醒" }
        if lead <= 0 { return "准时" }
        return "提前\(DurationFormat.prose(lead))"
    }

    /// Next quarter hour at least five minutes out — a sensible default start.
    public static func suggestedStart(after now: Date, calendar: Calendar = .current) -> Date {
        let base = now.addingTimeInterval(5 * 60)
        guard let hour = calendar.dateInterval(of: .hour, for: base)?.start else { return base }
        let minute = calendar.component(.minute, from: base)
        let rounded = (minute + 14) / 15 * 15
        return calendar.date(byAdding: .minute, value: rounded, to: hour) ?? base
    }
}

/// A notification the app should have pending.
public struct PlannedReminder: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Heads-up ahead of the start time.
        case advance
        /// Start time arrived; the user still has to press start.
        case due
        /// A running item passed its estimate; timing continues.
        case overtime
    }

    public var taskID: UUID
    public var kind: Kind
    public var fireAt: Date
    public var title: String
    public var body: String

    public var identifier: String { "itimer-\(kind.rawValue)-\(taskID.uuidString)" }
}

public enum ReminderPlan {
    /// Every reminder that should be pending at `now`. Past fire dates are
    /// dropped — the panel's 待开始 section covers anything missed.
    public static func reminders(for tasks: [TaskItem], asOf now: Date) -> [PlannedReminder] {
        var result: [PlannedReminder] = []
        for task in tasks where task.completedAt == nil {
            guard let lead = task.reminderLead else { continue }
            if task.isPending, let start = task.scheduledStart {
                let plan = task.plannedDuration.map { " · 预计\(DurationFormat.prose($0))" } ?? ""
                if lead > 0 {
                    result.append(PlannedReminder(
                        taskID: task.id,
                        kind: .advance,
                        fireAt: start.addingTimeInterval(-lead),
                        title: "\(DurationFormat.prose(lead))后开始",
                        body: task.title + plan
                    ))
                }
                result.append(PlannedReminder(
                    taskID: task.id,
                    kind: .due,
                    fireAt: start,
                    title: "到时间了：\(task.title)",
                    body: "点「开始计时」才会开始记录" + plan
                ))
            } else if task.isRunning, let planned = task.plannedDuration, let remaining = task.remaining(asOf: now) {
                result.append(PlannedReminder(
                    taskID: task.id,
                    kind: .overtime,
                    fireAt: now.addingTimeInterval(remaining),
                    title: "已到预计时长：\(task.title)",
                    body: "预计\(DurationFormat.prose(planned))已用完，计时会继续，超出部分记为超时。"
                ))
            }
        }
        return result.filter { $0.fireAt > now }
    }
}

/// How estimates compare to reality, over finished items that had one.
public struct EstimateStats: Equatable, Sendable {
    public var count: Int
    public var planned: TimeInterval
    public var actual: TimeInterval
    public var overrunCount: Int

    /// actual / planned; 2.0 means things take twice as long as planned.
    public var ratio: Double {
        planned > 0 ? actual / planned : 0
    }

    public static func of(_ tasks: [TaskItem], asOf now: Date, within window: DateInterval) -> EstimateStats {
        var stats = EstimateStats(count: 0, planned: 0, actual: 0, overrunCount: 0)
        for task in tasks {
            guard let planned = task.plannedDuration, planned > 0,
                  let done = task.completedAt, window.contains(done), !task.segments.isEmpty else { continue }
            let actual = task.duration(asOf: now)
            stats.count += 1
            stats.planned += planned
            stats.actual += actual
            if actual > planned { stats.overrunCount += 1 }
        }
        return stats
    }
}

/// Keeps the system's pending notifications in line with the plan.
@MainActor
public protocol ScheduleReminding: AnyObject {
    func reconcile(_ reminders: [PlannedReminder])
}
