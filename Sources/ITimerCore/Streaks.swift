import Foundation

public enum Streaks {
    /// Daily solo-focus time that keeps the streak alive.
    public static let dailySoloMinimum: TimeInterval = 25 * 60

    /// Consecutive days with at least `dailySoloMinimum` of single-task time.
    /// A not-yet-finished today does not break the streak.
    public static func focusStreak(
        tasks: [TaskItem],
        asOf now: Date,
        threshold: Int,
        calendar: Calendar = .current
    ) -> Int {
        guard let earliest = tasks.flatMap(\.segments).map(\.startedAt).min() else { return 0 }
        let firstDay = calendar.startOfDay(for: earliest)
        let window = DateInterval(start: firstDay, end: max(now, firstDay.addingTimeInterval(1)))
        let report = ParallelismAnalyzer.report(tasks: tasks, window: window, threshold: threshold, now: now)
        let days = ChartSeries.days(of: report.slices, window: window, threshold: threshold, calendar: calendar)
        let focusedByDay = Dictionary(days.map { (calendar.startOfDay(for: $0.day), $0.focused) }, uniquingKeysWith: +)

        var cursor = calendar.startOfDay(for: now)
        if (focusedByDay[cursor] ?? 0) < dailySoloMinimum,
           let previous = calendar.date(byAdding: .day, value: -1, to: cursor) {
            cursor = previous
        }
        var streak = 0
        while cursor >= firstDay {
            guard (focusedByDay[cursor] ?? 0) >= dailySoloMinimum else { break }
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }
}
