import XCTest
@testable import ITimerCore

final class AnalyzerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func task(_ title: String, from start: TimeInterval, to end: TimeInterval?) -> TaskItem {
        TaskItem(
            title: title,
            createdAt: t0.addingTimeInterval(start),
            segments: [TimeSegment(startedAt: t0.addingTimeInterval(start), endedAt: end.map { t0.addingTimeInterval($0) })]
        )
    }

    func testSoloWorkIsFocused() {
        let tasks = [task("写方案", from: 0, to: 600)]
        let window = DateInterval(start: t0, end: t0.addingTimeInterval(600))
        let report = ParallelismAnalyzer.report(tasks: tasks, window: window, threshold: 3, now: window.end)
        XCTAssertEqual(report.maxConcurrency, 1)
        XCTAssertEqual(report.unionActive, 600, accuracy: 0.001)
        XCTAssertEqual(report.degree, .none)
        XCTAssertEqual(report.verdict, .focused)
        XCTAssertEqual(report.switchCount, 0)
        XCTAssertEqual(report.tasks.first?.duration ?? 0, 600, accuracy: 0.001)
    }

    func testTwoWayOverlapIsMildNotBrainSplit() {
        let tasks = [
            task("写方案", from: 0, to: 600),
            task("回消息", from: 60, to: 600),
        ]
        let window = DateInterval(start: t0, end: t0.addingTimeInterval(600))
        let report = ParallelismAnalyzer.report(tasks: tasks, window: window, threshold: 3, now: window.end)
        XCTAssertEqual(report.maxConcurrency, 2)
        XCTAssertEqual(report.timeAtOrAboveThreshold, 0, accuracy: 0.001)
        XCTAssertEqual(report.degree, .none)
        XCTAssertEqual(report.verdict, .mild)
        XCTAssertEqual(report.switchCount, 1)
        XCTAssertEqual(report.overlaps.count, 1)
        XCTAssertEqual(report.overlaps[0].duration, 540, accuracy: 0.001)
    }

    func testThreeWayOverlapReachesSevereBrainSplit() {
        let tasks = [
            task("写方案", from: 0, to: 600),
            task("回消息", from: 60, to: 600),
            task("改bug", from: 120, to: nil),
        ]
        let now = t0.addingTimeInterval(600)
        let window = DateInterval(start: t0, end: now)
        let report = ParallelismAnalyzer.report(tasks: tasks, window: window, threshold: 3, now: now)
        XCTAssertEqual(report.maxConcurrency, 3)
        XCTAssertEqual(report.timeAtOrAboveThreshold, 480, accuracy: 0.001)
        XCTAssertEqual(report.unionActive, 600, accuracy: 0.001)
        XCTAssertEqual(report.brainSplitRatio, 0.8, accuracy: 0.001)
        XCTAssertEqual(report.degree, .severe)
        XCTAssertEqual(report.verdict, .brainSplit)
        XCTAssertEqual(report.switchCount, 2)
    }

    func testBriefBrainSplitStaysBelowReachedRatio() {
        let tasks = [
            task("主线", from: 0, to: 1000),
            task("插入A", from: 100, to: 160),
            task("插入B", from: 100, to: 160),
        ]
        let window = DateInterval(start: t0, end: t0.addingTimeInterval(1000))
        let report = ParallelismAnalyzer.report(tasks: tasks, window: window, threshold: 3, now: window.end)
        XCTAssertEqual(report.timeAtOrAboveThreshold, 60, accuracy: 0.001)
        XCTAssertEqual(report.degree, .brief)
        XCTAssertEqual(report.verdict, .brainSplit)
    }

    func testClosedSegmentCountsOnlyWhileItWasRunning() {
        let paused = TaskItem(
            title: "暂停的",
            createdAt: t0,
            segments: [TimeSegment(startedAt: t0, endedAt: t0.addingTimeInterval(30))]
        )
        let running = task("进行中", from: 0, to: nil)
        let now = t0.addingTimeInterval(100)
        let window = DateInterval(start: t0, end: now)
        let report = ParallelismAnalyzer.report(tasks: [paused, running], window: window, threshold: 3, now: now)
        XCTAssertEqual(report.maxConcurrency, 2)
        XCTAssertEqual(report.verdict, .mild)
        let afterPause = report.slices.first { $0.start >= t0.addingTimeInterval(30) && $0.concurrency > 0 }
        XCTAssertEqual(afterPause?.concurrency, 1)
    }

    func testWindowClipsOutsideTime() {
        let tasks = [task("跨窗", from: -100, to: 50)]
        let window = DateInterval(start: t0, end: t0.addingTimeInterval(200))
        let report = ParallelismAnalyzer.report(tasks: tasks, window: window, threshold: 3, now: window.end)
        XCTAssertEqual(report.unionActive, 50, accuracy: 0.001)
        XCTAssertEqual(report.tasks.first?.duration ?? 0, 50, accuracy: 0.001)
    }

    func testExactHandoffDoesNotSpikeConcurrency() {
        let tasks = [
            task("前", from: 0, to: 100),
            task("后", from: 100, to: 200),
        ]
        let window = DateInterval(start: t0, end: t0.addingTimeInterval(200))
        let report = ParallelismAnalyzer.report(tasks: tasks, window: window, threshold: 3, now: window.end)
        XCTAssertEqual(report.maxConcurrency, 1)
        XCTAssertEqual(report.switchCount, 0)
    }

    func testLiveVerdictUsesThreshold() {
        XCTAssertEqual(ParallelismAnalyzer.liveVerdict(runningCount: 0, threshold: 3), .idle)
        XCTAssertEqual(ParallelismAnalyzer.liveVerdict(runningCount: 1, threshold: 3), .focused)
        XCTAssertEqual(ParallelismAnalyzer.liveVerdict(runningCount: 2, threshold: 3), .mild)
        XCTAssertEqual(ParallelismAnalyzer.liveVerdict(runningCount: 3, threshold: 3), .brainSplit)
        XCTAssertEqual(ParallelismAnalyzer.liveVerdict(runningCount: 2, threshold: 2), .brainSplit)
    }

    func testStatusLabel() {
        XCTAssertEqual(StatusText.label(runningCount: 0, longestElapsed: 10, threshold: 3), "")
        XCTAssertEqual(StatusText.label(runningCount: 1, longestElapsed: 65, threshold: 3), "01:05")
        XCTAssertEqual(StatusText.label(runningCount: 2, longestElapsed: 3661, threshold: 3), "1:01:01 ×2")
        XCTAssertEqual(StatusText.label(runningCount: 3, longestElapsed: 10, threshold: 3), "脑裂 3")
    }

    func testChartSharesAndMidnightSplit() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2024, month: 1, day: 2, hour: 0))!
        let slices = [
            ConcurrencySlice(id: 0, start: day.addingTimeInterval(-3600), end: day, concurrency: 1),
            ConcurrencySlice(id: 1, start: day.addingTimeInterval(-1800), end: day.addingTimeInterval(1800), concurrency: 3),
        ]
        let shares = ChartSeries.shares(of: slices)
        XCTAssertEqual(shares.map(\.level), [1, 3])
        XCTAssertEqual(shares[0].duration, 3600, accuracy: 0.001)
        XCTAssertEqual(shares[1].duration, 3600, accuracy: 0.001)

        let window = DateInterval(start: day.addingTimeInterval(-3600), end: day.addingTimeInterval(1800))
        let days = ChartSeries.days(of: slices, window: window, threshold: 3, calendar: calendar)
        let first = days[0]
        let second = days[1]
        XCTAssertEqual(first.focused, 3600, accuracy: 0.001)
        XCTAssertEqual(first.brainSplit, 1800, accuracy: 0.001)
        XCTAssertEqual(second.brainSplit, 1800, accuracy: 0.001)
        XCTAssertEqual(second.focused, 0, accuracy: 0.001)
    }

    func testFocusStreakCountsConsecutiveSoloDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let base = calendar.date(from: DateComponents(year: 2024, month: 1, day: 5, hour: 10))!
        let solo: TimeInterval = 30 * 60

        func soloTask(dayOffset: Int) -> TaskItem {
            let start = calendar.date(byAdding: .day, value: dayOffset, to: base)!
            return TaskItem(
                title: "day\(dayOffset)",
                createdAt: start,
                segments: [TimeSegment(startedAt: start, endedAt: start.addingTimeInterval(solo))]
            )
        }

        // three consecutive days including "today"
        let now = base.addingTimeInterval(solo + 60)
        let streak = Streaks.focusStreak(tasks: [soloTask(dayOffset: -2), soloTask(dayOffset: -1), soloTask(dayOffset: 0)], asOf: now, threshold: 3, calendar: calendar)
        XCTAssertEqual(streak, 3)

        // today not started yet: streak still counts from yesterday
        let early = calendar.date(byAdding: .hour, value: -8, to: base)!
        let streakSkipToday = Streaks.focusStreak(tasks: [soloTask(dayOffset: -2), soloTask(dayOffset: -1)], asOf: early, threshold: 3, calendar: calendar)
        XCTAssertEqual(streakSkipToday, 2)

        // a day with too little solo time breaks the streak
        let weakTask = TaskItem(
            title: "weak",
            createdAt: base.addingTimeInterval(-24 * 3600),
            segments: [TimeSegment(startedAt: base.addingTimeInterval(-24 * 3600), endedAt: base.addingTimeInterval(-24 * 3600 + 5 * 60))]
        )
        let streakBroken = Streaks.focusStreak(tasks: [soloTask(dayOffset: -2), weakTask, soloTask(dayOffset: 0)], asOf: now, threshold: 3, calendar: calendar)
        XCTAssertEqual(streakBroken, 1)
    }

    func testTitleParserExtractsTags() {
        let parsed = TitleParser.parse("写周报 #工作 #汇报")
        XCTAssertEqual(parsed.title, "写周报")
        XCTAssertEqual(parsed.tags, ["工作", "汇报"])

        let leading = TitleParser.parse("#工作 写周报")
        XCTAssertEqual(leading.title, "写周报")
        XCTAssertEqual(leading.tags, ["工作"])

        let deduped = TitleParser.parse("写周报 #工作 #工作")
        XCTAssertEqual(deduped.tags, ["工作"])

        let plain = TitleParser.parse("只写 #")
        XCTAssertEqual(plain.title, "只写 #")
        XCTAssertEqual(plain.tags, [])
    }

    @MainActor
    func testTagStatsAttributeDurationAndSort() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itimer-tags-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let store = TaskStore(url: directory.appendingPathComponent("state.json"), now: start)
        let work = store.addTask(title: "写方案 #工作", at: start)!
        let play = store.addTask(title: "摸鱼 #生活", at: start)!
        store.pause(id: work.id, at: start.addingTimeInterval(600))
        store.pause(id: play.id, at: start.addingTimeInterval(300))

        let window = DateInterval(start: start, end: start.addingTimeInterval(3600))
        let slices = TagStats.slices(tasks: store.tasks, window: window, now: start.addingTimeInterval(3600))
        XCTAssertEqual(slices.map(\.tag), ["工作", "生活"])
        XCTAssertEqual(slices[0].duration, 600, accuracy: 0.001)
        XCTAssertEqual(slices[1].duration, 300, accuracy: 0.001)

        // untagged tasks fall into 未分类
        let stray = store.addTask(title: "杂事", at: start)!
        store.pause(id: stray.id, at: start.addingTimeInterval(100))
        let withStray = TagStats.slices(tasks: store.tasks, window: window, now: start.addingTimeInterval(3600))
        XCTAssertTrue(withStray.contains { $0.tag == TagStats.untagged && abs($0.duration - 100) < 0.001 })
    }

    func testDurationProse() {
        XCTAssertEqual(DurationFormat.prose(12), "12秒")
        XCTAssertEqual(DurationFormat.prose(60), "1分")
        XCTAssertEqual(DurationFormat.prose(90), "1分30秒")
        XCTAssertEqual(DurationFormat.prose(3600), "1小时")
        XCTAssertEqual(DurationFormat.prose(3720), "1小时2分")
    }

    func testTodayWindowStartsAtLocalDayBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let window = AnalysisRange.today.window(asOf: now, tasks: [], calendar: calendar)
        XCTAssertEqual(window.start, calendar.startOfDay(for: now))
        XCTAssertEqual(window.end, now)
    }

    func testFocusScoreWeighsBandsAndSwitches() {
        let window = DateInterval(start: t0, end: t0.addingTimeInterval(3600))
        let solo = ParallelismAnalyzer.report(tasks: [task("单核", from: 0, to: 3600)], window: window, threshold: 3, now: window.end)
        XCTAssertEqual(FocusScore.score(report: solo), 100)
        XCTAssertEqual(FocusScore.tier(for: 100), .flow)

        // Half the hour at 3 threads: solo 30min, split 30min, 2 switches/h.
        let split = ParallelismAnalyzer.report(
            tasks: [task("主线", from: 0, to: 3600), task("插A", from: 1800, to: 3600), task("插B", from: 1800, to: 3600)],
            window: window, threshold: 3, now: window.end
        )
        // (0.5 * 1 + 0.5 * 0.15) - 2 * 0.03 ≈ 0.515
        XCTAssertEqual(FocusScore.score(report: split), 51)
        XCTAssertEqual(FocusScore.tier(for: 51), .scattered)
        XCTAssertEqual(FocusScore.tier(for: 20), .overloaded)

        let empty = ParallelismAnalyzer.report(tasks: [], window: window, threshold: 3, now: window.end)
        XCTAssertNil(FocusScore.score(report: empty))
    }

    func testHoursSplitAcrossHourBoundaries() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let nine = calendar.date(from: DateComponents(year: 2024, month: 3, day: 1, hour: 9, minute: 30))!
        let slices = [
            ConcurrencySlice(id: 0, start: nine, end: nine.addingTimeInterval(3600), concurrency: 1),
            ConcurrencySlice(id: 1, start: nine.addingTimeInterval(3600), end: nine.addingTimeInterval(4200), concurrency: 3),
        ]
        let hours = ChartSeries.hours(of: slices, threshold: 3, calendar: calendar)
        XCTAssertEqual(hours.count, 24)
        XCTAssertEqual(hours[9].focused, 1800, accuracy: 0.001)
        XCTAssertEqual(hours[10].focused, 1800, accuracy: 0.001)
        XCTAssertEqual(hours[10].brainSplit, 600, accuracy: 0.001)
        XCTAssertEqual(hours[11].total, 0, accuracy: 0.001)
    }

    func testLanesSplitIntervalsAndLongestSolo() {
        let tasks = [
            task("主线", from: 0, to: 1000),
            task("插入A", from: 100, to: 200),
            task("插入B", from: 150, to: 300),
            task("接力", from: 1000, to: 1600),
        ]
        let window = DateInterval(start: t0, end: t0.addingTimeInterval(1600))
        let lanes = ChartSeries.lanes(tasks: tasks, window: window, now: window.end, limit: 3)
        // Top 3 by duration, ordered by first start: 主线, 插入B, 接力.
        XCTAssertEqual(lanes.map(\.title), ["主线", "插入B", "接力"])

        let report = ParallelismAnalyzer.report(tasks: tasks, window: window, threshold: 3, now: window.end)
        let splits = ChartSeries.splitIntervals(of: report.slices, threshold: 3)
        XCTAssertEqual(splits, [DateInterval(start: t0.addingTimeInterval(150), end: t0.addingTimeInterval(200))])

        // 300→1000 solo on 主线, then an exact handoff to 接力 until 1600.
        let solo = ChartSeries.longestSolo(of: report.slices)
        XCTAssertEqual(solo?.start, t0.addingTimeInterval(300))
        XCTAssertEqual(solo?.duration ?? 0, 1300, accuracy: 0.001)
    }

    func testInsightsSurfaceWarningsFirst() {
        let tasks = [
            task("写方案", from: 0, to: 3600),
            task("回消息", from: 600, to: 1800),
            task("开会", from: 900, to: 1500),
            task("看群", from: 2000, to: 2100),
            task("回邮件", from: 2200, to: 2300),
        ]
        let window = DateInterval(start: t0, end: t0.addingTimeInterval(3600))
        let report = ParallelismAnalyzer.report(tasks: tasks, window: window, threshold: 3, now: window.end)
        let insights = Insights.generate(report: report)
        XCTAssertEqual(insights.first?.id, "switch-rate")
        XCTAssertTrue(insights.contains { $0.id == "split-hour" })
        XCTAssertTrue(insights.contains { $0.id == "overlap" && $0.title.contains("写方案") })
        XCTAssertEqual(insights.first(where: { $0.tone == .warning })?.tone, .warning)
        XCTAssertLessThanOrEqual(insights.count, 4)

        let calm = ParallelismAnalyzer.report(tasks: [task("单核", from: 0, to: 3600)], window: window, threshold: 3, now: window.end)
        XCTAssertEqual(Set(Insights.generate(report: calm).map(\.id)), ["longest-solo", "no-switch"])
    }

    func testPreviousWindowShiftsByOneCycle() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2024, month: 3, day: 10, hour: 15))!
        let today = AnalysisRange.today.window(asOf: now, tasks: [], calendar: calendar)
        let yesterday = AnalysisRange.today.previousWindow(of: today, calendar: calendar)
        XCTAssertEqual(yesterday?.start, calendar.date(from: DateComponents(year: 2024, month: 3, day: 9)))
        XCTAssertEqual(yesterday?.end, calendar.date(from: DateComponents(year: 2024, month: 3, day: 9, hour: 15)))
        let week = AnalysisRange.week.window(asOf: now, tasks: [], calendar: calendar)
        XCTAssertEqual(AnalysisRange.week.previousWindow(of: week, calendar: calendar)?.end, now.addingTimeInterval(-7 * 86_400))
        XCTAssertNil(AnalysisRange.all.previousWindow(of: week, calendar: calendar))
    }

    func testDigestComparesWithYesterdayAndScoresDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2024, month: 3, day: 10, hour: 12))!
        func at(_ day: Int, _ hour: Double) -> Date {
            calendar.date(from: DateComponents(year: 2024, month: 3, day: day))!.addingTimeInterval(hour * 3600)
        }
        func span(_ title: String, _ start: Date, _ end: Date) -> TaskItem {
            TaskItem(title: title, createdAt: start, segments: [TimeSegment(startedAt: start, endedAt: end)])
        }
        let tasks = [
            // Yesterday morning: messy, three threads for an hour.
            span("甲", at(9, 9), at(9, 11)),
            span("乙", at(9, 10), at(9, 11)),
            span("丙", at(9, 10), at(9, 11)),
            // Today morning: clean single thread.
            span("甲", at(10, 9), at(10, 11)),
            // Two days ago: nothing. Three days ago: some solo work.
            span("丁", at(7, 9), at(7, 10)),
        ]

        let today = AnalysisDigest.build(tasks: tasks, range: .today, threshold: 3, now: now, calendar: calendar)
        XCTAssertEqual(today.score, 100)
        XCTAssertNotNil(today.previousScore)
        XCTAssertLessThan(today.previousScore ?? 100, 100)
        XCTAssertEqual(today.insights.first?.id, "trend")
        XCTAssertEqual(today.insights.first?.tone, .positive)
        XCTAssertFalse(today.lanes.isEmpty)
        XCTAssertTrue(today.dayScores.isEmpty)

        let week = AnalysisDigest.build(tasks: tasks, range: .week, threshold: 3, now: now, calendar: calendar)
        XCTAssertEqual(week.dayScores.count, 7)
        XCTAssertEqual(week.dayScores.last?.score, 100)
        let twoDaysAgo = week.dayScores.first { $0.day == calendar.date(from: DateComponents(year: 2024, month: 3, day: 8)) }
        XCTAssertNotNil(twoDaysAgo)
        XCTAssertNil(twoDaysAgo?.score)
        XCTAssertTrue(week.lanes.isEmpty)
    }
}

final class StoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itimer-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    @MainActor
    private func makeStore(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> TaskStore {
        TaskStore(url: directory.appendingPathComponent("state.json"), now: now)
    }

    @MainActor
    func testAddPauseResumeCompleteRoundTrip() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore(now: start)
        let task = try XCTUnwrap(store.addTask(title: "  收集时间  ", at: start))
        XCTAssertEqual(task.title, "收集时间")
        XCTAssertEqual(store.runningCount, 1)
        XCTAssertTrue(store.pause(id: task.id, at: start.addingTimeInterval(90)))
        XCTAssertEqual(store.runningCount, 0)
        XCTAssertEqual(store.tasks[0].duration(asOf: start.addingTimeInterval(200)), 90, accuracy: 0.001)
        XCTAssertTrue(store.resume(id: task.id, at: start.addingTimeInterval(200)))
        XCTAssertEqual(store.runningCount, 1)
        XCTAssertTrue(store.complete(id: task.id, at: start.addingTimeInterval(260)))
        XCTAssertEqual(store.runningCount, 0)
        XCTAssertEqual(store.tasks[0].duration(asOf: start.addingTimeInterval(999)), 150, accuracy: 0.001)
        XCTAssertFalse(store.complete(id: task.id))

        let reloaded = TaskStore(url: store.url, now: start.addingTimeInterval(300))
        XCTAssertEqual(reloaded.tasks, store.tasks)
        XCTAssertEqual(reloaded.brainSplitThreshold, 3)
    }

    @MainActor
    func testEmptyTitleRejectedAndThresholdClamped() {
        let store = makeStore()
        XCTAssertNil(store.addTask(title: "   "))
        store.setThreshold(1)
        XCTAssertEqual(store.brainSplitThreshold, 2)
        store.setThreshold(99)
        XCTAssertEqual(store.brainSplitThreshold, 8)
    }

    @MainActor
    func testCorruptFileIsQuarantined() throws {
        let url = directory.appendingPathComponent("state.json")
        try Data("not-json".utf8).write(to: url)
        let store = TaskStore(url: url)
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("bad").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testDeleteAndRename() throws {
        let store = makeStore()
        let task = try XCTUnwrap(store.addTask(title: "旧名字"))
        XCTAssertTrue(store.rename(id: task.id, title: "新名字"))
        XCTAssertEqual(store.tasks[0].title, "新名字")
        XCTAssertFalse(store.rename(id: task.id, title: " "))
        XCTAssertTrue(store.delete(id: task.id))
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertFalse(store.delete(id: task.id))
    }

    @MainActor
    func testRunningTasksSurviveReloadAsOpenSegments() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore(now: start)
        _ = store.addTask(title: "仍在进行", at: start)
        let later = start.addingTimeInterval(30)
        let reloaded = TaskStore(url: store.url, now: later)
        XCTAssertEqual(reloaded.runningCount, 1)
        XCTAssertEqual(reloaded.longestRunningElapsed, 30, accuracy: 0.001)
        XCTAssertEqual(reloaded.liveVerdict, .focused)
    }

    @MainActor
    func testCalendarSyncLifecycle() {
        final class Recorder: TaskCalendarSyncing {
            struct Call: Equatable { var title: String; var start: Date; var end: Date; var eventID: String? }
            var availability: CalendarAvailability { .granted("iTimer") }
            var upserts: [Call] = []
            var removed: [String] = []
            var nextID = 0
            func requestAccess() async -> Bool { true }
            func upsert(task: TaskItem, range: DateInterval, eventID: String?) -> String? {
                upserts.append(Call(title: task.title, start: range.start, end: range.end, eventID: eventID))
                if let eventID { return eventID }
                nextID += 1
                return "evt-\(nextID)"
            }
            func remove(eventID: String) { removed.append(eventID) }
        }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore(now: start)
        let recorder = Recorder()
        store.syncer = recorder

        // disabled: no calls
        let quiet = store.addTask(title: "不同步", at: start)!
        XCTAssertTrue(recorder.upserts.isEmpty)
        store.delete(id: quiet.id)

        store.setCalendarSyncEnabled(true)
        let task = store.addTask(title: "写方案 #工作", at: start)!
        XCTAssertEqual(recorder.upserts.count, 1)
        XCTAssertEqual(recorder.upserts[0].title, "写方案")
        XCTAssertEqual(store.tasks[0].calendarEventIDs, ["evt-1"])

        // pause closes the event at pause time
        store.pause(id: task.id, at: start.addingTimeInterval(90))
        XCTAssertEqual(recorder.upserts.last?.end, start.addingTimeInterval(90))
        XCTAssertEqual(store.tasks[0].calendarEventIDs, ["evt-1"])

        // resume opens a second event; the paused gap stays off the calendar
        store.resume(id: task.id, at: start.addingTimeInterval(200))
        XCTAssertEqual(store.tasks[0].calendarEventIDs, ["evt-1", "evt-2"])
        XCTAssertEqual(recorder.upserts.last?.start, start.addingTimeInterval(200))
        XCTAssertEqual(recorder.upserts.last?.eventID, nil)

        // complete finalizes the end of the last stretch; the first keeps its end
        store.complete(id: task.id, at: start.addingTimeInterval(260))
        let final = recorder.upserts.suffix(2)
        XCTAssertEqual(final.map(\.eventID), ["evt-1", "evt-2"])
        XCTAssertEqual(final.map(\.end), [start.addingTimeInterval(90), start.addingTimeInterval(260)])

        // rename re-pushes title on both events
        store.rename(id: task.id, title: "改名了")
        XCTAssertEqual(recorder.upserts.suffix(2).map(\.title), ["改名了", "改名了"])
        XCTAssertEqual(store.tasks[0].calendarEventIDs, ["evt-1", "evt-2"])

        // delete removes every event
        store.delete(id: task.id)
        XCTAssertEqual(recorder.removed, ["evt-1", "evt-2"])
    }

    @MainActor
    func testReportCacheMemoizesAndInvalidates() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore(now: start)
        _ = store.addTask(title: "写方案", at: start)
        let cache = ReportCache()

        _ = cache.report(store: store, range: .today)
        _ = cache.report(store: store, range: .today)
        XCTAssertEqual(cache.computations, 1)

        // same bucket, unchanged tasks → still one computation
        store.save()
        _ = cache.report(store: store, range: .today)
        XCTAssertEqual(cache.computations, 1)

        // task mutation invalidates
        store.pause(id: store.tasks[0].id, at: start.addingTimeInterval(60))
        _ = cache.report(store: store, range: .today)
        XCTAssertEqual(cache.computations, 2)

        // range switch invalidates
        _ = cache.report(store: store, range: .all)
        XCTAssertEqual(cache.computations, 3)
    }

    @MainActor
    func testStreakCacheMemoizes() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore(now: start)
        _ = store.addTask(title: "写方案", at: start)
        let cache = StreakCache()
        _ = cache.streak(store: store)
        _ = cache.streak(store: store)
        XCTAssertEqual(cache.computations, 1)
        store.complete(id: store.tasks[0].id, at: start.addingTimeInterval(1800))
        _ = cache.streak(store: store)
        XCTAssertEqual(cache.computations, 2)
    }

    @MainActor
    func testStatusLabelFreezeSurvivesMutations() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore(now: start)
        _ = store.addTask(title: "甲", at: start)
        _ = store.addTask(title: "乙", at: start)

        let liveBefore = store.statusLabel
        store.setStatusFrozen(true)
        XCTAssertTrue(store.isStatusFrozen)
        XCTAssertEqual(store.statusLabel, liveBefore)
        XCTAssertEqual(store.liveVerdict, .mild)

        // Mutations under freeze: label and verdict present stale values.
        _ = store.pause(id: store.runningTasks[0].id, at: start.addingTimeInterval(60))
        XCTAssertEqual(store.statusLabel, liveBefore)
        XCTAssertEqual(store.liveVerdict, .mild)

        store.setStatusFrozen(false)
        XCTAssertFalse(store.isStatusFrozen)
        XCTAssertEqual(store.liveVerdict, .focused)
        XCTAssertTrue(store.statusLabel.hasPrefix("01:"))
    }

    @MainActor
    func testPauseDropsLiveConcurrency() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore(now: start)
        _ = try XCTUnwrap(store.addTask(title: "主线", at: start))
        let extra = try XCTUnwrap(store.addTask(title: "插入", at: start))
        XCTAssertEqual(store.liveVerdict, .mild)
        XCTAssertTrue(store.pause(id: extra.id, at: start.addingTimeInterval(10)))
        XCTAssertEqual(store.runningCount, 1)
        XCTAssertEqual(store.liveVerdict, .focused)
    }

    @MainActor
    func testFocusKeepsOnlyOneThread() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore(now: start)
        let a = try XCTUnwrap(store.addTask(title: "甲", at: start))
        let b = try XCTUnwrap(store.addTask(title: "乙", at: start))
        let c = try XCTUnwrap(store.addTask(title: "丙", at: start))
        store.pause(id: c.id, at: start.addingTimeInterval(10))

        // Focus a paused task: it resumes, the others pause.
        XCTAssertTrue(store.focus(id: c.id, at: start.addingTimeInterval(60)))
        XCTAssertEqual(store.runningTasks.map(\.id), [c.id])
        XCTAssertTrue(store.tasks.first { $0.id == a.id }!.isPaused)
        XCTAssertEqual(store.tasks.first { $0.id == b.id }!.duration(asOf: start.addingTimeInterval(999)), 60, accuracy: 0.001)

        store.complete(id: a.id, at: start.addingTimeInterval(70))
        XCTAssertFalse(store.focus(id: a.id))
    }

    @MainActor
    func testActionsStampWallClockNotFrozenNow() throws {
        // The observable clock is frozen while the menu panel is open; an
        // action taken then must still be stamped with the real time.
        let stale = Date().addingTimeInterval(-600)
        let store = makeStore(now: stale)
        let task = try XCTUnwrap(store.addTask(title: "晚点开始"))
        XCTAssertEqual(task.createdAt.timeIntervalSinceNow, 0, accuracy: 5)
    }

    @MainActor
    func testCompletedTodayAndSuggestions() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let morning = calendar.date(from: DateComponents(year: 2024, month: 5, day: 2, hour: 9))!
        let store = makeStore(now: morning)
        let old = try XCTUnwrap(store.addTask(title: "写周报 #工作", at: morning.addingTimeInterval(-86_400)))
        store.complete(id: old.id, at: morning.addingTimeInterval(-80_000))
        let done = try XCTUnwrap(store.addTask(title: "回邮件", at: morning))
        store.complete(id: done.id, at: morning.addingTimeInterval(600))
        _ = store.addTask(title: "改bug", at: morning.addingTimeInterval(700))
        let again = try XCTUnwrap(store.addTask(title: "回邮件", at: morning.addingTimeInterval(800)))
        store.complete(id: again.id, at: morning.addingTimeInterval(900))

        XCTAssertEqual(store.completedToday(calendar: calendar).map(\.id), [again.id, done.id])
        // Newest first, deduped, open tasks (改bug) excluded, tags restored.
        XCTAssertEqual(store.suggestions(), ["回邮件", "写周报 #工作"])
        XCTAssertEqual(store.suggestions(matching: "周报"), ["写周报 #工作"])
        XCTAssertEqual(store.suggestions(matching: "回邮件"), [])
    }

    @MainActor
    func testReportCacheKeepsRangesApart() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let store = makeStore(now: start)
        _ = store.addTask(title: "写方案", at: start)
        let cache = ReportCache()
        _ = cache.report(store: store, range: .today)
        _ = cache.report(store: store, range: .week)
        _ = cache.report(store: store, range: .today)
        _ = cache.report(store: store, range: .week)
        XCTAssertEqual(cache.computations, 2)
    }
}

final class ScheduleTests: XCTestCase {
    private var directory: URL!
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itimer-schedule-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    @MainActor
    private final class ReminderRecorder: ScheduleReminding {
        var last: [PlannedReminder] = []
        func reconcile(_ reminders: [PlannedReminder]) { last = reminders }
    }

    @MainActor
    private func makeStore(now: Date) -> TaskStore {
        TaskStore(url: directory.appendingPathComponent("state.json"), now: now)
    }

    @MainActor
    func testScheduleDoesNotStartOnItsOwn() throws {
        let store = makeStore(now: t0)
        let start = t0.addingTimeInterval(3600)
        let item = try XCTUnwrap(store.addSchedule(title: "写方案 #工作", start: start, plannedDuration: 7200, reminderLead: 300))
        XCTAssertEqual(item.tags, ["工作"])
        XCTAssertTrue(item.isPending)
        XCTAssertFalse(item.isPaused)
        XCTAssertEqual(store.upcomingSchedules.map(\.id), [item.id])
        XCTAssertTrue(store.dueSchedules.isEmpty)
        XCTAssertTrue(store.pausedTasks.isEmpty)
        XCTAssertEqual(store.runningCount, 0)

        XCTAssertEqual(store.statusLabel, "")

        // Start time passes (reload with a later clock): due, still not timing.
        let later = TaskStore(url: store.url, now: start.addingTimeInterval(600))
        XCTAssertEqual(later.dueSchedules.map(\.id), [item.id])
        XCTAssertTrue(later.upcomingSchedules.isEmpty)
        XCTAssertEqual(later.runningCount, 0)
        XCTAssertEqual(later.tasks[0].duration(asOf: later.now), 0)
        XCTAssertEqual(later.statusLabel, "待开始 1")
        XCTAssertFalse(later.pause(id: item.id))

        // Explicit start begins timing at the moment of the click.
        XCTAssertTrue(later.resume(id: item.id, at: start.addingTimeInterval(600)))
        XCTAssertEqual(later.runningCount, 1)
        XCTAssertTrue(later.dueSchedules.isEmpty)
        XCTAssertEqual(later.tasks[0].duration(asOf: start.addingTimeInterval(1200)), 600, accuracy: 0.001)

        let reloaded = TaskStore(url: store.url, now: start.addingTimeInterval(1200))
        XCTAssertEqual(reloaded.tasks, later.tasks)
    }

    @MainActor
    func testUndatedScheduleWaitsWithoutTime() throws {
        final class Recorder: TaskCalendarSyncing {
            var availability: CalendarAvailability { .granted("iTimer") }
            var upserts = 0
            var removed: [String] = []
            func requestAccess() async -> Bool { true }
            func upsert(task: TaskItem, range: DateInterval, eventID: String?) -> String? { upserts += 1; return "evt" }
            func remove(eventID: String) { removed.append(eventID) }
        }
        let store = makeStore(now: t0)
        let recorder = Recorder()
        store.syncer = recorder
        store.setCalendarSyncEnabled(true)

        let item = try XCTUnwrap(store.addSchedule(title: "接入AI", start: nil, plannedDuration: 3600, reminderLead: 300))
        XCTAssertTrue(item.isUndated)
        XCTAssertNil(item.reminderLead, "no time, no reminder")
        XCTAssertEqual(store.undatedSchedules.map(\.id), [item.id])
        XCTAssertTrue(store.upcomingSchedules.isEmpty)
        XCTAssertEqual(recorder.upserts, 0, "nothing to put on a calendar yet")

        // Days later it is still waiting, never due, never a reminder.
        let later = TaskStore(url: store.url, now: t0.addingTimeInterval(3 * 86400))
        XCTAssertTrue(later.dueSchedules.isEmpty)
        XCTAssertEqual(later.statusLabel, "")
        XCTAssertTrue(ReminderPlan.reminders(for: later.tasks, asOf: later.now).isEmpty)

        // Giving it a time turns it into a normal schedule; taking it back removes the event.
        let slot = t0.addingTimeInterval(7200)
        XCTAssertTrue(store.updateSchedule(id: item.id, start: slot, plannedDuration: 3600, reminderLead: 0))
        XCTAssertEqual(store.upcomingSchedules.map(\.id), [item.id])
        XCTAssertEqual(store.tasks[0].reminderLead, 0)
        XCTAssertEqual(recorder.upserts, 1)
        XCTAssertTrue(store.updateSchedule(id: item.id, start: nil, plannedDuration: 3600, reminderLead: 0))
        XCTAssertTrue(store.tasks[0].isUndated)
        XCTAssertNil(store.tasks[0].reminderLead)
        XCTAssertTrue(store.tasks[0].calendarEventIDs.isEmpty)
        XCTAssertEqual(recorder.removed, ["evt"])

        // Starting by hand works like any schedule.
        XCTAssertTrue(store.resume(id: item.id, at: t0.addingTimeInterval(60)))
        XCTAssertEqual(store.runningCount, 1)
        XCTAssertTrue(store.undatedSchedules.isEmpty)
    }

    @MainActor
    func testTimingRunsPastEstimate() throws {
        let store = makeStore(now: t0)
        let item = try XCTUnwrap(store.addSchedule(title: "以为两小时", start: t0, plannedDuration: 7200, reminderLead: nil))
        store.resume(id: item.id, at: t0)
        let later = t0.addingTimeInterval(4 * 3600)
        let running = store.tasks[0]
        XCTAssertTrue(running.isRunning)
        XCTAssertEqual(running.remaining(asOf: t0.addingTimeInterval(3600)) ?? 0, 3600, accuracy: 0.001)
        XCTAssertFalse(running.isOvertime(asOf: t0.addingTimeInterval(7200)))
        XCTAssertEqual(running.overtime(asOf: later), 7200, accuracy: 0.001)
        XCTAssertTrue(store.complete(id: item.id, at: later))
        XCTAssertEqual(store.tasks[0].duration(asOf: later), 4 * 3600, accuracy: 0.001)

        let stats = EstimateStats.of(store.tasks, asOf: later, within: DateInterval(start: t0, end: later))
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats.overrunCount, 1)
        XCTAssertEqual(stats.ratio, 2, accuracy: 0.001)
    }

    @MainActor
    func testUpdateSchedulePinsStartOnceRunning() throws {
        let store = makeStore(now: t0)
        let item = try XCTUnwrap(store.addSchedule(title: "会", start: t0, plannedDuration: 1800, reminderLead: 0))
        let moved = t0.addingTimeInterval(900)
        XCTAssertTrue(store.updateSchedule(id: item.id, start: moved, plannedDuration: 3600, reminderLead: nil))
        XCTAssertEqual(store.tasks[0].scheduledStart, moved)
        XCTAssertEqual(store.tasks[0].plannedDuration, 3600)
        XCTAssertNil(store.tasks[0].reminderLead)

        store.resume(id: item.id, at: moved)
        XCTAssertTrue(store.updateSchedule(id: item.id, start: t0, plannedDuration: 7200, reminderLead: nil))
        XCTAssertEqual(store.tasks[0].scheduledStart, moved)
        XCTAssertEqual(store.tasks[0].plannedDuration, 7200)
    }

    @MainActor
    func testReminderPlanFollowsLifecycle() throws {
        let store = makeStore(now: t0)
        let recorder = ReminderRecorder()
        store.reminders = recorder
        let start = t0.addingTimeInterval(3600)
        let item = try XCTUnwrap(store.addSchedule(title: "写方案", start: start, plannedDuration: 1800, reminderLead: 600))
        XCTAssertEqual(recorder.last.map(\.kind), [.advance, .due])
        XCTAssertEqual(recorder.last.map(\.fireAt), [start.addingTimeInterval(-600), start])

        // Snoozing moves both.
        store.postpone(id: item.id, by: 7200, at: t0)
        XCTAssertEqual(recorder.last.last?.fireAt, t0.addingTimeInterval(7200))

        // Started: advance/due go away, overtime lands when the estimate runs out.
        let clicked = t0.addingTimeInterval(7300)
        store.resume(id: item.id, at: clicked)
        XCTAssertEqual(recorder.last.map(\.kind), [.overtime])
        XCTAssertEqual(recorder.last[0].fireAt.timeIntervalSince(clicked), 1800, accuracy: 0.001)

        // Paused: nothing pending. Done: nothing pending.
        store.pause(id: item.id, at: clicked.addingTimeInterval(60))
        XCTAssertTrue(recorder.last.isEmpty)
        store.resume(id: item.id, at: clicked.addingTimeInterval(120))
        XCTAssertEqual(recorder.last[0].fireAt.timeIntervalSince(clicked), 1860, accuracy: 0.001)
        store.complete(id: item.id, at: clicked.addingTimeInterval(200))
        XCTAssertTrue(recorder.last.isEmpty)
    }

    func testReminderPlanSkipsDisabledAndPast() {
        let silent = TaskItem(title: "安静", createdAt: t0, scheduledStart: t0.addingTimeInterval(600), plannedDuration: 600, reminderLead: nil)
        let atTime = TaskItem(title: "准时", createdAt: t0, scheduledStart: t0.addingTimeInterval(600), reminderLead: 0)
        let lateLead = TaskItem(title: "来不及提前", createdAt: t0, scheduledStart: t0.addingTimeInterval(120), reminderLead: 300)
        let plan = ReminderPlan.reminders(for: [silent, atTime, lateLead], asOf: t0)
        XCTAssertEqual(plan.map(\.taskID), [atTime.id, lateLead.id])
        XCTAssertEqual(plan.map(\.kind), [.due, .due])
    }

    func testCalendarRangeUsesPlanThenActual() {
        var item = TaskItem(title: "排期", createdAt: t0, scheduledStart: t0.addingTimeInterval(3600), plannedDuration: 5400)
        XCTAssertEqual(item.calendarRanges(asOf: t0), [DateInterval(start: t0.addingTimeInterval(3600), duration: 5400)])
        item.segments = [TimeSegment(startedAt: t0.addingTimeInterval(4000))]
        XCTAssertEqual(item.calendarRanges(asOf: t0.addingTimeInterval(5000)), [DateInterval(start: t0.addingTimeInterval(4000), duration: 1000)])
    }

    func testCalendarRangesLeaveOutPausedTime() {
        let item = TaskItem(title: "断断续续", createdAt: t0, segments: [
            TimeSegment(startedAt: t0, endedAt: t0.addingTimeInterval(600)),
            // 30s break: bridged into the first stretch
            TimeSegment(startedAt: t0.addingTimeInterval(630), endedAt: t0.addingTimeInterval(1200)),
            // an hour's pause: its own event
            TimeSegment(startedAt: t0.addingTimeInterval(4800)),
        ])
        XCTAssertEqual(item.calendarRanges(asOf: t0.addingTimeInterval(5400)), [
            DateInterval(start: t0, duration: 1200),
            DateInterval(start: t0.addingTimeInterval(4800), duration: 600),
        ])
    }

    func testLegacySingleCalendarEventIDMigrates() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","title":"旧任务","createdAt":"2023-11-14T22:13:20Z","segments":[],"calendarEventID":"evt-old"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let task = try decoder.decode(TaskItem.self, from: Data(json.utf8))
        XCTAssertEqual(task.calendarEventIDs, ["evt-old"])
    }

    func testLegacyTasksDecodeWithoutScheduleFields() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","title":"旧任务","createdAt":"2023-11-14T22:13:20Z","segments":[{"startedAt":"2023-11-14T22:13:20Z"}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let task = try decoder.decode(TaskItem.self, from: Data(json.utf8))
        XCTAssertNil(task.scheduledStart)
        XCTAssertNil(task.plannedDuration)
        XCTAssertTrue(task.isRunning)
        XCTAssertFalse(task.isPending)
    }

    func testSuggestedStartRoundsToQuarterHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let base = calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 14, minute: 7, second: 30))!
        let suggested = ScheduleOptions.suggestedStart(after: base, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.hour, .minute, .second], from: suggested), DateComponents(hour: 14, minute: 15, second: 0))
        let late = calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 14, minute: 56))!
        XCTAssertEqual(calendar.dateComponents([.hour, .minute], from: ScheduleOptions.suggestedStart(after: late, calendar: calendar)), DateComponents(hour: 15, minute: 15))
    }
}

@MainActor
final class LabelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private var directories: [URL] = []

    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
        super.tearDown()
    }

    private func makeStore() -> TaskStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itimer-labels-\(UUID().uuidString)", isDirectory: true)
        directories.append(directory)
        return TaskStore(url: directory.appendingPathComponent("state.json"), now: t0)
    }

    func testParserExtractsTagsAndRoundTrips() {
        let parsed = TitleParser.parse("写周报 #汇报 #周报")
        XCTAssertEqual(parsed.title, "写周报")
        XCTAssertEqual(parsed.tags, ["汇报", "周报"])
        XCTAssertEqual(TitleParser.input(title: parsed.title, tags: parsed.tags), "写周报 #汇报 #周报")
        // a lone "#" stays in the title; "@" is no longer special
        XCTAssertEqual(TitleParser.parse("见 @ 老王").title, "见 @ 老王")
        XCTAssertEqual(TitleParser.parse("a @学习").title, "a @学习")
    }

    func testStoreStartsWithNoCollectionsAndLegacyFilesStayEmpty() throws {
        let store = makeStore()
        XCTAssertTrue(store.collections.isEmpty)

        let legacy = #"{"brainSplitThreshold":3,"categories":[{"name":"工作","color":0}],"tasks":[{"id":"\#(UUID().uuidString)","title":"x","createdAt":"2023-11-14T22:13:20Z","segments":[],"category":"工作"}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(StoreSnapshot.self, from: Data(legacy.utf8))
        XCTAssertTrue(snapshot.collections.isEmpty)
        XCTAssertNil(snapshot.tasks[0].collectionID)
        XCTAssertNil(snapshot.tasks[0].parentID)
    }

    func testCollectionsAreCreatedExplicitlyAndFiledByID() {
        let store = makeStore()
        XCTAssertNil(store.addCollection("  "), "empty names are refused")
        XCTAssertNil(store.addCollection(CollectionStats.uncollected))
        let work = store.addCollection("本周交付", at: t0)!
        XCTAssertEqual(work.color, 0)
        XCTAssertEqual(store.addCollection("本周交付")?.id, work.id, "names stay unique, case-insensitively")
        XCTAssertEqual(store.addCollection("本周交付 ")?.id, work.id)

        let task = store.addTask(title: "写周报 #汇报", collectionID: work.id, at: t0)!
        XCTAssertEqual(task.collectionID, work.id)
        XCTAssertEqual(task.tags, ["汇报"])
        XCTAssertNil(store.addTask(title: "孤儿", collectionID: UUID(), at: t0)?.collectionID, "unknown ids are dropped")

        store.complete(id: task.id, at: t0.addingTimeInterval(60))
        XCTAssertTrue(store.suggestions().contains("写周报 #汇报"))
    }

    func testRetitleAndTagsLeaveCollectionAlone() {
        let store = makeStore()
        let work = store.addCollection("工作", at: t0)!
        let task = store.addTask(title: "写周报", collectionID: work.id, at: t0)!
        XCTAssertTrue(store.retitle(id: task.id, input: "写月报 #汇报"))
        var current = store.tasks.first { $0.id == task.id }!
        XCTAssertEqual(current.title, "写月报")
        XCTAssertEqual(current.tags, ["汇报"])
        XCTAssertEqual(current.collectionID, work.id, "retitle no longer touches filing")

        store.toggleTag(id: task.id, "紧急")
        store.toggleTag(id: task.id, "汇报")
        store.setCollection(id: task.id, nil)
        current = store.tasks.first { $0.id == task.id }!
        XCTAssertEqual(current.tags, ["紧急"])
        XCTAssertNil(current.collectionID)
        XCTAssertEqual(store.knownTags.first, "紧急")

        XCTAssertFalse(store.retitle(id: task.id, input: "#只有标签"))
    }

    func testRenameAndRemoveCollectionKeepTasks() {
        let store = makeStore()
        let work = store.addCollection("工作", at: t0)!
        let study = store.addCollection("学习", at: t0)!
        let task = store.addTask(title: "写代码", collectionID: work.id, at: t0)!
        XCTAssertTrue(store.renameCollection(id: work.id, to: "上班"))
        XCTAssertEqual(store.tasks.first { $0.id == task.id }?.collectionID, work.id)
        XCTAssertFalse(store.renameCollection(id: work.id, to: "学习"), "names stay unique")
        XCTAssertFalse(store.renameCollection(id: work.id, to: CollectionStats.uncollected))

        store.removeCollection(id: work.id)
        XCTAssertNil(store.tasks.first { $0.id == task.id }?.collectionID, "tasks survive, just unfiled")
        XCTAssertNil(store.collection(id: work.id))
        XCTAssertNotNil(store.collection(id: study.id))

        let reloaded = TaskStore(url: store.url, now: t0)
        XCTAssertEqual(reloaded.collections.map(\.name), ["学习"])
        XCTAssertNil(reloaded.tasks.first?.collectionID)
    }

    func testScheduleMergesPickedTagsAndCollection() {
        let store = makeStore()
        let work = store.addCollection("工作", at: t0)!
        let item = store.addSchedule(
            title: "季度汇报 #PPT",
            tags: ["汇报"],
            collectionID: work.id,
            start: t0.addingTimeInterval(3600),
            plannedDuration: 3600,
            reminderLead: nil,
            at: t0
        )!
        XCTAssertEqual(item.tags, ["汇报", "PPT"])
        XCTAssertEqual(item.collectionID, work.id)
    }

    func testSubtasksStayOneLevelAndFollowTheParent() {
        let store = makeStore()
        let work = store.addCollection("本周交付", at: t0)!
        let parent = store.addTask(title: "写周报", collectionID: work.id, at: t0)!
        let child = store.addSubtask(parentID: parent.id, title: "整理数据 #数据", at: t0.addingTimeInterval(10))!
        XCTAssertEqual(child.parentID, parent.id)
        XCTAssertEqual(child.collectionID, work.id, "a subtask inherits the collection")
        XCTAssertEqual(store.subtasks(of: parent.id).map(\.id), [child.id])

        XCTAssertNil(store.addSubtask(parentID: child.id, title: "孙任务", at: t0), "no grandchildren")
        XCTAssertFalse(store.setParent(id: parent.id, child.id), "a parent with children cannot become a child")
        XCTAssertFalse(store.setCollection(id: child.id, nil), "a subtask cannot be filed on its own")

        let other = store.addCollection("生活", at: t0)!
        XCTAssertTrue(store.setCollection(id: parent.id, other.id))
        XCTAssertEqual(store.tasks.first { $0.id == child.id }?.collectionID, other.id)

        let stray = store.addTask(title: "杂事", at: t0)!
        XCTAssertTrue(store.setParent(id: stray.id, parent.id))
        XCTAssertEqual(store.tasks.first { $0.id == stray.id }?.collectionID, other.id)
        XCTAssertTrue(store.setParent(id: stray.id, nil))
        XCTAssertNil(store.tasks.first { $0.id == stray.id }?.parentID)
        XCTAssertEqual(store.tasks.first { $0.id == stray.id }?.collectionID, other.id, "leaving keeps the filing")

        store.delete(id: parent.id)
        XCTAssertNil(store.tasks.first { $0.id == parent.id })
        XCTAssertNil(store.tasks.first { $0.id == child.id }, "deleting a parent deletes its subtasks")
        XCTAssertNotNil(store.tasks.first { $0.id == stray.id })
    }

    func testCollectionStatsAndDigestFilter() {
        let store = makeStore()
        let work = store.addCollection("工作", at: t0)!
        let filed = store.addTask(title: "写方案", collectionID: work.id, at: t0)!
        let stray = store.addTask(title: "杂事", at: t0)!
        store.pause(id: filed.id, at: t0.addingTimeInterval(600))
        store.pause(id: stray.id, at: t0.addingTimeInterval(300))

        let window = DateInterval(start: t0, end: t0.addingTimeInterval(3600))
        let slices = CollectionStats.slices(tasks: store.tasks, collections: store.collections, window: window, now: window.end)
        XCTAssertEqual(slices.map(\.tag), ["工作", CollectionStats.uncollected])
        XCTAssertEqual(slices[0].duration, 600, accuracy: 0.001)

        let cache = DigestCache()
        let filtered = cache.digest(store: store, range: .all, collectionID: work.id)
        XCTAssertEqual(filtered.report.tasks.map(\.id), [filed.id])
        XCTAssertEqual(filtered.collections.map(\.tag), ["工作"])
        let loose = cache.digest(store: store, range: .all, collectionID: CollectionStats.uncollectedID)
        XCTAssertEqual(loose.report.tasks.map(\.id), [stray.id])
        XCTAssertEqual(cache.digest(store: store, range: .all).report.tasks.count, 2)
    }

    func testNoteAndCommentsPersistAndLegacyTasksHaveNone() throws {
        let legacy = #"{"id":"\#(UUID().uuidString)","title":"x","createdAt":"2023-11-14T22:13:20Z","segments":[]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(TaskItem.self, from: Data(legacy.utf8))
        XCTAssertEqual(old.note, "")
        XCTAssertTrue(old.comments.isEmpty)
        XCTAssertFalse(old.hasJournal)

        let store = makeStore()
        let task = store.addTask(title: "排查线上问题", at: t0)!
        XCTAssertNil(store.addComment(id: task.id, text: "   \n  ", at: t0), "blank comments are refused")
        let first = store.addComment(id: task.id, text: "复现了，只在 iOS 17 出现", at: t0.addingTimeInterval(60))!
        let second = store.addComment(id: task.id, text: "  定位到缓存键没带版本号  ", at: t0.addingTimeInterval(120))!
        XCTAssertEqual(second.text, "定位到缓存键没带版本号")
        XCTAssertTrue(store.setNote(id: task.id, "结论：缓存键加版本号\n\n\n下次：补回归测试  "))

        var current = store.tasks.first { $0.id == task.id }!
        XCTAssertEqual(current.note, "结论：缓存键加版本号\n\n下次：补回归测试", "blank runs collapse to one")
        XCTAssertEqual(current.comments.map(\.id), [first.id, second.id], "oldest first")
        XCTAssertEqual(current.comments[0].createdAt, t0.addingTimeInterval(60))
        XCTAssertTrue(current.hasJournal)

        XCTAssertTrue(store.deleteComment(id: task.id, commentID: first.id))
        XCTAssertFalse(store.deleteComment(id: task.id, commentID: first.id))
        current = store.tasks.first { $0.id == task.id }!
        XCTAssertEqual(current.comments.map(\.id), [second.id])

        let reloaded = TaskStore(url: store.url, now: t0)
        let saved = reloaded.tasks.first { $0.id == task.id }!
        XCTAssertEqual(saved.note, "结论：缓存键加版本号\n\n下次：补回归测试")
        XCTAssertEqual(saved.comments.map(\.text), ["定位到缓存键没带版本号"])

        XCTAssertTrue(store.setNote(id: task.id, "步骤：\n  - 清缓存  \n  - 重启"))
        XCTAssertEqual(store.tasks.first { $0.id == task.id }?.note, "步骤：\n  - 清缓存\n  - 重启", "indentation survives")
        XCTAssertTrue(store.setNote(id: task.id, "  "))
        XCTAssertEqual(store.tasks.first { $0.id == task.id }?.note, "")
    }
}
