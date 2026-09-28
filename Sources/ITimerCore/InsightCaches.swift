import Foundation

/// Reports sweep the full task history; recomputing them on every one-second
/// UI tick is wasteful. Memoize per range on (tasks, threshold, 30s bucket) —
/// the panel always wants "today" while the analysis view may show another
/// range, so a single slot would thrash.
@MainActor
public final class ReportCache {
    public static let shared = ReportCache()

    private struct Key: Equatable {
        var tasks: [TaskItem]
        var threshold: Int
        var bucket: Int
    }

    private var entries: [AnalysisRange: (key: Key, value: ParallelismReport)] = [:]
    /// Exposed for tests: how many times the report was actually computed.
    public private(set) var computations = 0

    public init() {}

    public func report(store: TaskStore, range: AnalysisRange) -> ParallelismReport {
        let key = Key(
            tasks: store.tasks,
            threshold: store.brainSplitThreshold,
            bucket: Int(store.now.timeIntervalSince1970 / 30)
        )
        if let entry = entries[range], entry.key == key { return entry.value }
        let fresh = store.report(range: range)
        computations += 1
        entries[range] = (key, fresh)
        return fresh
    }

    public func invalidate() {
        entries.removeAll()
    }
}

/// Streak reads the full history too. Cache on (tasks, day, 60s bucket) —
/// the running-minute crossing the daily minimum is the only tick-driven change.
@MainActor
public final class StreakCache {
    public static let shared = StreakCache()

    private struct Key: Equatable {
        var tasks: [TaskItem]
        var day: Date
        var bucket: Int
        var threshold: Int
    }

    private var key: Key?
    private var value = 0
    public private(set) var computations = 0

    public init() {}

    public func streak(store: TaskStore, calendar: Calendar = .current) -> Int {
        let key = Key(
            tasks: store.tasks,
            day: calendar.startOfDay(for: store.now),
            bucket: Int(store.now.timeIntervalSince1970 / 60),
            threshold: store.brainSplitThreshold
        )
        if key == self.key { return value }
        let fresh = Streaks.focusStreak(tasks: store.tasks, asOf: store.now, threshold: store.brainSplitThreshold, calendar: calendar)
        computations += 1
        self.key = key
        self.value = fresh
        return fresh
    }

    public func invalidate() {
        key = nil
    }
}
