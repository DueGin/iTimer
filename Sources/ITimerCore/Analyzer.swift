import Foundation

public enum ParallelismAnalyzer {
    public static func liveVerdict(runningCount: Int, threshold: Int) -> FocusVerdict {
        let threshold = BrainSplitRules.clamp(threshold)
        if runningCount <= 0 { return .idle }
        if runningCount >= threshold { return .brainSplit }
        if runningCount >= 2 { return .mild }
        return .focused
    }

    public static func degree(
        maxConcurrency: Int,
        brainSplitDuration: TimeInterval,
        unionActive: TimeInterval,
        threshold: Int
    ) -> BrainSplitDegree {
        let threshold = BrainSplitRules.clamp(threshold)
        guard maxConcurrency >= threshold, brainSplitDuration > 0, unionActive > 0 else { return .none }
        let ratio = brainSplitDuration / unionActive
        if ratio >= BrainSplitRules.severeRatio || maxConcurrency >= threshold + 2 {
            return .severe
        }
        if ratio >= BrainSplitRules.reachedRatio {
            return .reached
        }
        return .brief
    }

    public static func historicalVerdict(
        maxConcurrency: Int,
        degree: BrainSplitDegree,
        unionActive: TimeInterval
    ) -> FocusVerdict {
        if unionActive <= 0 { return .idle }
        if degree != .none { return .brainSplit }
        if maxConcurrency >= 2 { return .mild }
        return .focused
    }

    public static func report(
        tasks: [TaskItem],
        window: DateInterval,
        threshold: Int,
        now: Date
    ) -> ParallelismReport {
        let threshold = BrainSplitRules.clamp(threshold)
        guard window.end > window.start else {
            return ParallelismReport.empty
        }

        let spans = clippedSpans(tasks: tasks, window: window, now: now)
        let sweep = sweep(spans: spans, window: window)
        let splitDuration = sweep.timeByConcurrency
            .filter { $0.key >= threshold }
            .reduce(0) { $0 + $1.value }
        let degree = degree(
            maxConcurrency: sweep.maxConcurrency,
            brainSplitDuration: splitDuration,
            unionActive: sweep.unionActive,
            threshold: threshold
        )
        let verdict = historicalVerdict(
            maxConcurrency: sweep.maxConcurrency,
            degree: degree,
            unionActive: sweep.unionActive
        )
        let stats = tasks.compactMap { task -> TaskStat? in
            let duration = task.duration(asOf: now, within: window)
            guard duration > 0 else { return nil }
            return TaskStat(
                id: task.id,
                title: task.title,
                duration: duration,
                isRunning: task.isRunning,
                isPaused: task.isPaused,
                isCompleted: task.isCompleted
            )
        }
        .sorted { lhs, rhs in
            if lhs.duration != rhs.duration { return lhs.duration > rhs.duration }
            return lhs.title < rhs.title
        }

        return ParallelismReport(
            window: window,
            threshold: threshold,
            maxConcurrency: sweep.maxConcurrency,
            unionActive: sweep.unionActive,
            timeAtOrAboveThreshold: splitDuration,
            degree: degree,
            verdict: verdict,
            switchCount: sweep.switchCount,
            slices: sweep.slices,
            overlaps: overlaps(spans: spans, titles: Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.title) })),
            tasks: stats
        )
    }

    private struct Span {
        var taskID: UUID
        var start: Date
        var end: Date
    }

    private static func clippedSpans(tasks: [TaskItem], window: DateInterval, now: Date) -> [Span] {
        tasks.flatMap { task in
            task.segments.compactMap { segment -> Span? in
                guard let clipped = segment.clipped(to: window, asOf: now) else { return nil }
                return Span(taskID: task.id, start: clipped.start, end: clipped.end)
            }
        }
    }

    private struct Sweep {
        var slices: [ConcurrencySlice]
        var maxConcurrency: Int
        var unionActive: TimeInterval
        var timeByConcurrency: [Int: TimeInterval]
        var switchCount: Int
    }

    private struct Event {
        var time: Date
        var delta: Int
    }

    private static func sweep(spans: [Span], window: DateInterval) -> Sweep {
        var events: [Event] = []
        events.reserveCapacity(spans.count * 2)
        for span in spans {
            events.append(Event(time: span.start, delta: 1))
            events.append(Event(time: span.end, delta: -1))
        }
        events.sort { lhs, rhs in
            if lhs.time != rhs.time { return lhs.time < rhs.time }
            return lhs.delta < rhs.delta
        }

        var slices: [ConcurrencySlice] = []
        var timeByConcurrency: [Int: TimeInterval] = [:]
        var cursor = window.start
        var concurrency = 0
        var maxConcurrency = 0
        var unionActive: TimeInterval = 0
        var switchCount = 0
        var index = 0

        func emit(until time: Date) {
            guard time > cursor else { return }
            let duration = time.timeIntervalSince(cursor)
            slices.append(ConcurrencySlice(id: index, start: cursor, end: time, concurrency: concurrency))
            index += 1
            timeByConcurrency[concurrency, default: 0] += duration
            if concurrency > 0 { unionActive += duration }
            cursor = time
        }

        for event in events {
            emit(until: min(event.time, window.end))
            if event.delta > 0, concurrency >= 1 {
                switchCount += 1
            }
            concurrency = max(0, concurrency + event.delta)
            maxConcurrency = max(maxConcurrency, concurrency)
        }
        emit(until: window.end)

        return Sweep(
            slices: slices,
            maxConcurrency: maxConcurrency,
            unionActive: unionActive,
            timeByConcurrency: timeByConcurrency,
            switchCount: switchCount
        )
    }

    private static func overlaps(spans: [Span], titles: [UUID: String]) -> [TaskOverlap] {
        struct Key: Hashable {
            var a: UUID
            var b: UUID
        }
        var totals: [Key: TimeInterval] = [:]
        for index in spans.indices {
            for other in spans.index(after: index)..<spans.endIndex {
                let left = spans[index]
                let right = spans[other]
                guard left.taskID != right.taskID else { continue }
                let start = max(left.start, right.start)
                let end = min(left.end, right.end)
                guard end > start else { continue }
                let ordered = left.taskID.uuidString < right.taskID.uuidString
                    ? Key(a: left.taskID, b: right.taskID)
                    : Key(a: right.taskID, b: left.taskID)
                totals[ordered, default: 0] += end.timeIntervalSince(start)
            }
        }
        return totals.map { key, duration in
            TaskOverlap(
                taskAID: key.a,
                taskBID: key.b,
                titleA: titles[key.a] ?? "未命名",
                titleB: titles[key.b] ?? "未命名",
                duration: duration
            )
        }
        .sorted { lhs, rhs in
            if lhs.duration != rhs.duration { return lhs.duration > rhs.duration }
            return lhs.titleA < rhs.titleA
        }
    }
}
