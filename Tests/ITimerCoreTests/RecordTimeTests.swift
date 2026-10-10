import XCTest
@testable import ITimerCore

final class RecordTimeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("itimer-record-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func segment(_ start: TimeInterval, _ end: TimeInterval?) -> TimeSegment {
        TimeSegment(startedAt: t0.addingTimeInterval(start), endedAt: end.map { t0.addingTimeInterval($0) })
    }

    @MainActor
    private func makeStore() -> TaskStore {
        TaskStore(url: directory.appendingPathComponent("state.json"), now: t0)
    }

    @MainActor
    func testCorrectForgottenTimerRecalculatesAnalysisAndPersists() throws {
        let store = makeStore()
        let forgotten = try XCTUnwrap(store.addTask(title: "忘记结束 #工作", at: t0))
        let other = try XCTUnwrap(store.addTask(title: "另一件事", at: t0.addingTimeInterval(3600)))
        store.complete(id: other.id, at: t0.addingTimeInterval(5400))
        let now = t0.addingTimeInterval(7200)
        store.complete(id: forgotten.id, at: now)
        store.setNote(id: forgotten.id, "保留备注")
        let cache = ReportCache()
        XCTAssertEqual(cache.report(store: store, range: .all).overlaps.first?.duration, 1800)
        let original = try XCTUnwrap(store.tasks.first { $0.id == forgotten.id })
        let corrected = [segment(-600, 1800)]
        XCTAssertTrue(store.updateCompletedSegments(id: forgotten.id, segments: corrected, at: now))
        let edited = try XCTUnwrap(store.tasks.first { $0.id == forgotten.id })
        XCTAssertEqual(edited.segments, corrected)
        XCTAssertEqual(edited.duration(asOf: now), 2400)
        XCTAssertEqual(edited.completedAt, t0.addingTimeInterval(1800))
        XCTAssertTrue(edited.isCompleted)
        XCTAssertFalse(edited.isRunning)
        XCTAssertEqual(edited.createdAt, original.createdAt)
        XCTAssertEqual(edited.tags, original.tags)
        XCTAssertEqual(edited.note, original.note)
        let report = cache.report(store: store, range: .all)
        XCTAssertEqual(cache.computations, 2)
        XCTAssertTrue(report.overlaps.isEmpty)
        XCTAssertEqual(report.unionActive, 4200)
        XCTAssertEqual(report.tasks.first { $0.id == forgotten.id }?.duration, 2400)
        XCTAssertEqual(TaskStore(url: store.url, now: now).tasks, store.tasks)
    }

    @MainActor
    func testMultipleSegmentsPreservePauseAndSyncCalendarRanges() throws {
        let store = makeStore()
        let syncer = CalendarRecorder()
        store.syncer = syncer
        store.setCalendarSyncEnabled(true)
        let task = try XCTUnwrap(store.addTask(title: "分段计时", at: t0))
        store.pause(id: task.id, at: t0.addingTimeInterval(600))
        store.resume(id: task.id, at: t0.addingTimeInterval(1200))
        let now = t0.addingTimeInterval(3600)
        store.complete(id: task.id, at: now)
        let original = store.tasks[0]
        var advances = 0
        store.onWorkflowAdvance = { _ in advances += 1 }
        syncer.calls.removeAll()
        let corrected = [segment(60, 480), segment(1500, 2100)]
        XCTAssertTrue(store.updateCompletedSegments(id: task.id, segments: corrected, expectedSegments: original.segments, at: now))
        XCTAssertEqual(store.tasks[0].duration(asOf: now), 1020)
        XCTAssertEqual(syncer.calls.map(\.range), [
            DateInterval(start: t0.addingTimeInterval(60), end: t0.addingTimeInterval(480)),
            DateInterval(start: t0.addingTimeInterval(1500), end: t0.addingTimeInterval(2100))
        ])
        XCTAssertEqual(syncer.calls.map(\.eventID), original.calendarEventIDs.map(Optional.some))
        XCTAssertEqual(advances, 0)

        // Bringing the stretches together merges calendar events, without
        // merging actual segments or counting paused time in the duration.
        let closeTogether = [segment(60, 480), segment(510, 2100)]
        XCTAssertTrue(store.updateCompletedSegments(id: task.id, segments: closeTogether, at: now))
        XCTAssertEqual(store.tasks[0].segments.count, 2)
        XCTAssertEqual(store.tasks[0].duration(asOf: now), 2010)
        XCTAssertEqual(syncer.removed, [original.calendarEventIDs[1]])
        XCTAssertEqual(store.tasks[0].calendarEventIDs, [original.calendarEventIDs[0]])
        XCTAssertEqual(TaskStore(url: store.url, now: now).tasks, store.tasks)
    }

    @MainActor
    func testInvalidEditsDoNotChangeMemoryFileOrCalendar() throws {
        let store = makeStore()
        let syncer = CalendarRecorder()
        store.syncer = syncer
        store.setCalendarSyncEnabled(true)
        let task = try XCTUnwrap(store.addTask(title: "两段", at: t0))
        store.pause(id: task.id, at: t0.addingTimeInterval(300))
        store.resume(id: task.id, at: t0.addingTimeInterval(600))
        let now = t0.addingTimeInterval(900)
        store.complete(id: task.id, at: now)
        let original = store.tasks
        let file = try Data(contentsOf: store.url)
        syncer.calls.removeAll()
        let invalid: [[TimeSegment]] = [
            [],
            [segment(0, 300)],
            [segment(300, 0), segment(600, 900)],
            [segment(0, nil), segment(600, 900)],
            [segment(0, 700), segment(600, 900)],
            [segment(600, 900), segment(0, 300)],
            [segment(0, 300), segment(600, 901)],
            [segment(0, 300), segment(1000, 1100)],
            [TimeSegment(startedAt: Date(timeIntervalSince1970: .nan), endedAt: now), segment(600, 900)]
        ]
        for segments in invalid {
            XCTAssertFalse(store.updateCompletedSegments(id: task.id, segments: segments, at: now))
            XCTAssertEqual(store.tasks, original)
            XCTAssertEqual(try Data(contentsOf: store.url), file)
            XCTAssertTrue(syncer.calls.isEmpty)
        }
    }

    @MainActor
    func testActiveDeletedAndStaleRecordsCannotBeEdited() throws {
        let store = makeStore()
        let task = try XCTUnwrap(store.addTask(title: "记录", at: t0))
        let now = t0.addingTimeInterval(600)
        let corrected = [segment(0, 100)]
        XCTAssertFalse(store.updateCompletedSegments(id: task.id, segments: corrected, at: now))
        store.pause(id: task.id, at: t0.addingTimeInterval(300))
        XCTAssertFalse(store.updateCompletedSegments(id: task.id, segments: corrected, at: now))
        store.complete(id: task.id, at: now)
        let original = store.tasks[0].segments
        XCTAssertTrue(store.updateCompletedSegments(id: task.id, segments: corrected, expectedSegments: original, at: now))
        XCTAssertFalse(store.updateCompletedSegments(id: task.id, segments: [segment(0, 200)], expectedSegments: original, at: now))
        XCTAssertEqual(store.tasks[0].segments, corrected)
        store.resume(id: task.id, at: now)
        XCTAssertFalse(store.updateCompletedSegments(id: task.id, segments: corrected, at: now))
        store.delete(id: task.id)
        XCTAssertFalse(store.updateCompletedSegments(id: task.id, segments: corrected, at: now))
    }

    @MainActor
    func testCorrectionAcrossMidnightMovesCompletionOutOfToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = calendar.startOfDay(for: t0)
        let store = makeStore()
        let task = try XCTUnwrap(store.addTask(title: "昨天的事", at: midnight.addingTimeInterval(-3600)))
        let now = midnight.addingTimeInterval(3600)
        store.complete(id: task.id, at: now)
        XCTAssertEqual(store.completedToday(calendar: calendar).count, 1)
        let corrected = [TimeSegment(startedAt: midnight.addingTimeInterval(-3600), endedAt: midnight.addingTimeInterval(-1800))]
        XCTAssertTrue(store.updateCompletedSegments(id: task.id, segments: corrected, at: now))
        XCTAssertTrue(store.completedToday(calendar: calendar).isEmpty)
        XCTAssertEqual(store.report(range: .today, calendar: calendar).unionActive, 0)
        XCTAssertEqual(store.report(range: .all, calendar: calendar).unionActive, 1800)
    }

    @MainActor
    func testSaveFailureRollsBackCorrectionAndSkipsCalendar() throws {
        let store = makeStore()
        let syncer = CalendarRecorder()
        store.syncer = syncer
        store.setCalendarSyncEnabled(true)
        let task = try XCTUnwrap(store.addTask(title: "保留原记录", at: t0))
        store.complete(id: task.id, at: t0.addingTimeInterval(300))
        let original = store.tasks
        let previousNow = store.now
        syncer.calls.removeAll()
        // A file in place of the parent directory makes writing impossible,
        // independent of the test process's filesystem permissions.
        try FileManager.default.removeItem(at: directory)
        try Data("blocker".utf8).write(to: directory)
        XCTAssertFalse(store.updateCompletedSegments(id: task.id, segments: [segment(0, 100)], at: t0.addingTimeInterval(600)))
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(store.tasks, original)
        XCTAssertEqual(store.now, previousNow)
        XCTAssertTrue(syncer.calls.isEmpty)
    }

    @MainActor
    func testUnchangedTimesKeepLaterCompletionAndZeroLengthSegmentsAreEditable() throws {
        let store = makeStore()
        let task = try XCTUnwrap(store.addTask(title: "先暂停再完成", at: t0))
        store.pause(id: task.id, at: t0)
        let now = t0.addingTimeInterval(600)
        store.complete(id: task.id, at: now)
        let original = store.tasks[0]
        XCTAssertTrue(store.updateCompletedSegments(id: task.id, segments: original.segments, at: now))
        XCTAssertEqual(store.tasks[0], original)
        XCTAssertTrue(store.updateCompletedSegments(id: task.id, segments: [segment(0, 60)], at: now))
        XCTAssertEqual(store.tasks[0].duration(asOf: now), 60)
    }
}

@MainActor
private final class CalendarRecorder: TaskCalendarSyncing {
    struct Call { var range: DateInterval; var eventID: String? }
    var availability: CalendarAvailability { .granted("iTimer") }
    var calls: [Call] = []
    var removed: [String] = []
    private var nextID = 0

    func requestAccess() async -> Bool { true }

    func upsert(task: TaskItem, range: DateInterval, eventID: String?) -> String? {
        calls.append(Call(range: range, eventID: eventID))
        if let eventID { return eventID }
        nextID += 1
        return "record-event-\(nextID)"
    }

    func remove(eventID: String) { removed.append(eventID) }
}
