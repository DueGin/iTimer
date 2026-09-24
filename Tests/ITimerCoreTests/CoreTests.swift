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
        XCTAssertEqual(StatusText.label(runningCount: 2, longestElapsed: 3661, threshold: 3), "2·1:01:01")
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
            struct Call: Equatable { var title: String; var start: Date; var end: Date }
            var availability: CalendarAvailability { .granted("iTimer") }
            var upserts: [Call] = []
            var removed: [String] = []
            var nextID = 0
            func requestAccess() async -> Bool { true }
            func upsert(task: TaskItem, asOf now: Date) -> String? {
                let start = task.segments.first?.startedAt ?? task.createdAt
                let end = task.segments.last?.endedAt ?? now
                upserts.append(Call(title: task.title, start: start, end: end))
                if let existing = task.calendarEventID { return existing }
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
        XCTAssertEqual(store.tasks[0].calendarEventID, "evt-1")

        // pause closes the event at pause time
        store.pause(id: task.id, at: start.addingTimeInterval(90))
        XCTAssertEqual(recorder.upserts.last?.end, start.addingTimeInterval(90))
        XCTAssertEqual(store.tasks[0].calendarEventID, "evt-1")

        // resume extends the same event
        store.resume(id: task.id, at: start.addingTimeInterval(200))
        XCTAssertEqual(recorder.upserts.count, 3)

        // complete finalizes the end
        store.complete(id: task.id, at: start.addingTimeInterval(260))
        XCTAssertEqual(recorder.upserts.last?.end, start.addingTimeInterval(260))

        // rename re-pushes title on the same event
        store.rename(id: task.id, title: "改名了")
        XCTAssertEqual(recorder.upserts.last?.title, "改名了")
        XCTAssertEqual(store.tasks[0].calendarEventID, "evt-1")

        // delete removes the event
        store.delete(id: task.id)
        XCTAssertEqual(recorder.removed, ["evt-1"])
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
}
