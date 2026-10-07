import Foundation

extension AnalysisRange {
    /// The same stretch one cycle earlier, for comparisons: today so far vs
    /// yesterday up to the same time, last 7 days vs the 7 before, etc.
    /// `nil` for `.all`, which has nothing before it.
    public func previousWindow(of window: DateInterval, calendar: Calendar = .current) -> DateInterval? {
        let days: Int
        switch self {
        case .today: days = 1
        case .week: days = 7
        case .month: days = 30
        case .all: return nil
        }
        guard let start = calendar.date(byAdding: .day, value: -days, to: window.start),
              let end = calendar.date(byAdding: .day, value: -days, to: window.end) else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// How the comparison period reads in a sentence ("比昨天同一时段").
    public var previousTitle: String {
        switch self {
        case .today: "昨天同一时段"
        case .week: "前 7 天"
        case .month: "前 30 天"
        case .all: ""
        }
    }
}

public struct DayScore: Identifiable, Equatable, Sendable {
    public var day: Date
    public var score: Int?
    public var active: TimeInterval
    public var id: Date { day }
}

/// Everything the analysis screen draws, computed once per cache key rather
/// than on every one-second tick.
public struct AnalysisDigest: Equatable, Sendable {
    public var range: AnalysisRange
    public var report: ParallelismReport
    public var bands: BandTotals
    public var score: Int?
    public var previous: ParallelismReport?
    public var previousBands: BandTotals?
    public var previousScore: Int?
    public var insights: [Insight]
    public var hours: [HourLoad]
    public var lanes: [LaneSpan]
    public var splitIntervals: [DateInterval]
    public var days: [DayLoad]
    public var dayScores: [DayScore]
    public var tags: [TagSlice]

    /// Days in the trend chart, newest last. Older history is left out.
    public static let trendDays = 90

    public static func build(
        tasks: [TaskItem],
        range: AnalysisRange,
        threshold: Int,
        now: Date,
        calendar: Calendar = .current
    ) -> AnalysisDigest {
        let window = range.window(asOf: now, tasks: tasks, calendar: calendar)
        let report = ParallelismAnalyzer.report(tasks: tasks, window: window, threshold: threshold, now: now)
        let score = FocusScore.score(report: report)

        var previous: ParallelismReport?
        if let earlier = range.previousWindow(of: window, calendar: calendar) {
            let candidate = ParallelismAnalyzer.report(tasks: tasks, window: earlier, threshold: threshold, now: now)
            previous = candidate.unionActive > 0 ? candidate : nil
        }
        let previousScore = previous.flatMap(FocusScore.score(report:))

        var insights = Insights.generate(report: report, calendar: calendar, limit: 3)
        if let score, let previousScore, abs(score - previousScore) >= 5 {
            let delta = score - previousScore
            insights.insert(Insight(
                id: "trend",
                symbol: delta > 0 ? "arrow.up.right" : "arrow.down.right",
                title: "专注度比\(range.previousTitle)\(delta > 0 ? "高" : "低") \(abs(delta))",
                detail: delta > 0
                    ? "从 \(previousScore) 到 \(score)。保持一次只开一个线程的节奏。"
                    : "从 \(previousScore) 到 \(score)。看看下面哪个时段线程开得最多。",
                tone: delta > 0 ? .positive : .warning
            ), at: 0)
        }

        return AnalysisDigest(
            range: range,
            report: report,
            bands: BandTotals.of(report.slices, threshold: report.threshold),
            score: score,
            previous: previous,
            previousBands: previous.map { BandTotals.of($0.slices, threshold: $0.threshold) },
            previousScore: previousScore,
            insights: insights,
            hours: ChartSeries.hours(of: report.slices, threshold: report.threshold, calendar: calendar),
            lanes: range == .today ? ChartSeries.lanes(tasks: tasks, window: window, now: now) : [],
            splitIntervals: ChartSeries.splitIntervals(of: report.slices, threshold: report.threshold),
            days: ChartSeries.days(of: report.slices, window: window, threshold: report.threshold, calendar: calendar),
            dayScores: range == .today ? [] : dayScores(tasks: tasks, window: window, threshold: threshold, now: now, calendar: calendar),
            tags: TagStats.slices(tasks: tasks, window: window, now: now)
        )
    }

    /// One focus score per calendar day in the window (days without any
    /// timing get `nil`, so the trend line shows a gap instead of a zero).
    static func dayScores(
        tasks: [TaskItem],
        window: DateInterval,
        threshold: Int,
        now: Date,
        calendar: Calendar
    ) -> [DayScore] {
        let lastDay = calendar.startOfDay(for: window.end.addingTimeInterval(-1))
        let earliest = calendar.date(byAdding: .day, value: -(trendDays - 1), to: lastDay) ?? lastDay
        var day = max(calendar.startOfDay(for: window.start), earliest)
        var result: [DayScore] = []
        while day <= lastDay {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            let span = DateInterval(start: max(day, window.start), end: max(min(next, window.end), max(day, window.start)))
            let report = span.duration > 0
                ? ParallelismAnalyzer.report(tasks: tasks, window: span, threshold: threshold, now: now)
                : ParallelismReport.empty
            result.append(DayScore(day: day, score: FocusScore.score(report: report), active: report.unionActive))
            day = next
        }
        return result
    }
}

/// Memoizes digests per range on (tasks, threshold, 30s bucket).
@MainActor
public final class DigestCache {
    public static let shared = DigestCache()

    private struct Key: Equatable {
        var tasks: [TaskItem]
        var threshold: Int
        var bucket: Int
    }

    private var entries: [AnalysisRange: (key: Key, value: AnalysisDigest)] = [:]
    public private(set) var computations = 0

    public init() {}

    public func digest(
        store: TaskStore,
        range: AnalysisRange,
        calendar: Calendar = .current
    ) -> AnalysisDigest {
        let key = Key(
            tasks: store.tasks,
            threshold: store.brainSplitThreshold,
            bucket: Int(store.now.timeIntervalSince1970 / 30)
        )
        if let entry = entries[range], entry.key == key { return entry.value }
        let fresh = AnalysisDigest.build(
            tasks: store.tasks,
            range: range,
            threshold: store.brainSplitThreshold,
            now: store.now,
            calendar: calendar
        )
        computations += 1
        entries[range] = (key, fresh)
        return fresh
    }
}
