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
}
