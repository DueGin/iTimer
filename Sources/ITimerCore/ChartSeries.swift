import Foundation

public struct ConcurrencyShare: Identifiable, Equatable, Sendable {
    public var level: Int
    public var duration: TimeInterval
    public var id: Int { level }
}

public struct DayLoad: Identifiable, Equatable, Sendable {
    public var day: Date
    public var focused: TimeInterval
    public var mild: TimeInterval
    public var brainSplit: TimeInterval

    public var id: Date { day }
    public var total: TimeInterval { focused + mild + brainSplit }
}

public enum ChartSeries {
    public static func shares(of slices: [ConcurrencySlice]) -> [ConcurrencyShare] {
        var totals: [Int: TimeInterval] = [:]
        for slice in slices where slice.concurrency > 0 && slice.duration > 0 {
            totals[slice.concurrency, default: 0] += slice.duration
        }
        return totals.keys.sorted().map { ConcurrencyShare(level: $0, duration: totals[$0] ?? 0) }
    }

    public static func days(
        of slices: [ConcurrencySlice],
        window: DateInterval,
        threshold: Int,
        calendar: Calendar = .current
    ) -> [DayLoad] {
        let threshold = BrainSplitRules.clamp(threshold)
        var buckets: [Date: DayLoad] = [:]

        for slice in slices where slice.concurrency > 0 && slice.end > slice.start {
            var cursor = slice.start
            while cursor < slice.end {
                let day = calendar.startOfDay(for: cursor)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                let end = min(slice.end, next)
                let duration = end.timeIntervalSince(cursor)
                var load = buckets[day] ?? DayLoad(day: day, focused: 0, mild: 0, brainSplit: 0)
                if slice.concurrency >= threshold {
                    load.brainSplit += duration
                } else if slice.concurrency >= 2 {
                    load.mild += duration
                } else {
                    load.focused += duration
                }
                buckets[day] = load
                cursor = end
            }
        }

        if window.duration <= 31 * 24 * 3600, window.end > window.start {
            var day = calendar.startOfDay(for: window.start)
            let last = calendar.startOfDay(for: window.end.addingTimeInterval(-1))
            while day <= last {
                if buckets[day] == nil {
                    buckets[day] = DayLoad(day: day, focused: 0, mild: 0, brainSplit: 0)
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }

        return buckets.values.sorted { $0.day < $1.day }
    }

    /// Active time folded onto the 24 hours of the day, split by band.
    /// Always returns 24 entries, hour 0...23.
    public static func hours(
        of slices: [ConcurrencySlice],
        threshold: Int,
        calendar: Calendar = .current
    ) -> [HourLoad] {
        let threshold = BrainSplitRules.clamp(threshold)
        var loads = (0..<24).map { HourLoad(hour: $0, focused: 0, mild: 0, brainSplit: 0) }

        for slice in slices where slice.concurrency > 0 && slice.end > slice.start {
            var cursor = slice.start
            while cursor < slice.end {
                guard let hourEnd = calendar.dateInterval(of: .hour, for: cursor)?.end else { break }
                let end = min(slice.end, hourEnd)
                let duration = end.timeIntervalSince(cursor)
                let hour = calendar.component(.hour, from: cursor)
                if slice.concurrency >= threshold {
                    loads[hour].brainSplit += duration
                } else if slice.concurrency >= 2 {
                    loads[hour].mild += duration
                } else {
                    loads[hour].focused += duration
                }
                cursor = end
            }
        }
        return loads
    }

    /// Per-task segments clipped to the window, for a swimlane chart. Keeps
    /// the `limit` tasks with the most time, ordered by when they first ran.
    public static func lanes(
        tasks: [TaskItem],
        window: DateInterval,
        now: Date,
        limit: Int = 10
    ) -> [LaneSpan] {
        let ranked = tasks
            .map { ($0, $0.duration(asOf: now, within: window)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)

        var spans: [LaneSpan] = []
        for task in ranked {
            for segment in task.segments {
                guard let clipped = segment.clipped(to: window, asOf: now) else { continue }
                spans.append(LaneSpan(
                    id: spans.count,
                    taskID: task.id,
                    title: task.title,
                    tags: task.tags,
                    collectionID: task.collectionID,
                    start: clipped.start,
                    end: clipped.end,
                    isRunning: segment.endedAt == nil
                ))
            }
        }
        let firstStart = Dictionary(spans.map { ($0.taskID, $0.start) }, uniquingKeysWith: min)
        return spans.sorted { lhs, rhs in
            let left = firstStart[lhs.taskID] ?? lhs.start
            let right = firstStart[rhs.taskID] ?? rhs.start
            if left != right { return left < right }
            return lhs.start < rhs.start
        }
    }

    /// Contiguous stretches at or above the brain-split threshold.
    public static func splitIntervals(of slices: [ConcurrencySlice], threshold: Int) -> [DateInterval] {
        let threshold = BrainSplitRules.clamp(threshold)
        var result: [DateInterval] = []
        for slice in slices where slice.concurrency >= threshold && slice.end > slice.start {
            if let last = result.last, last.end >= slice.start {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, slice.end))
            } else {
                result.append(DateInterval(start: slice.start, end: slice.end))
            }
        }
        return result
    }

    /// Longest uninterrupted single-task stretch. Consecutive solo slices
    /// (e.g. an exact handoff between two tasks) count as one stretch.
    public static func longestSolo(of slices: [ConcurrencySlice]) -> DateInterval? {
        var best: DateInterval?
        var current: DateInterval?
        for slice in slices where slice.end > slice.start {
            if slice.concurrency == 1 {
                if let open = current, open.end >= slice.start {
                    current = DateInterval(start: open.start, end: slice.end)
                } else {
                    current = DateInterval(start: slice.start, end: slice.end)
                }
                if let candidate = current, candidate.duration > (best?.duration ?? 0) {
                    best = candidate
                }
            } else {
                current = nil
            }
        }
        return best
    }
}

public struct HourLoad: Identifiable, Equatable, Sendable {
    public var hour: Int
    public var focused: TimeInterval
    public var mild: TimeInterval
    public var brainSplit: TimeInterval

    public var id: Int { hour }
    public var total: TimeInterval { focused + mild + brainSplit }
}

public struct LaneSpan: Identifiable, Equatable, Sendable {
    public var id: Int
    public var taskID: UUID
    public var title: String
    public var tags: [String]
    public var collectionID: UUID?
    public var start: Date
    public var end: Date
    public var isRunning: Bool
}
