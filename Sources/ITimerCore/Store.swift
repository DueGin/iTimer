import Foundation
import Observation

public struct StoreSnapshot: Codable, Equatable, Sendable {
    public var version: Int
    public var brainSplitThreshold: Int
    public var tasks: [TaskItem]
    public var calendarSyncEnabled: Bool

    public init(version: Int = 1, brainSplitThreshold: Int, tasks: [TaskItem], calendarSyncEnabled: Bool = false) {
        self.version = version
        self.brainSplitThreshold = brainSplitThreshold
        self.tasks = tasks
        self.calendarSyncEnabled = calendarSyncEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case version, brainSplitThreshold, tasks, calendarSyncEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        brainSplitThreshold = try container.decode(Int.self, forKey: .brainSplitThreshold)
        tasks = try container.decode([TaskItem].self, forKey: .tasks)
        calendarSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .calendarSyncEnabled) ?? false
    }
}

public struct DebugLaunch: Codable, Equatable, Sendable {
    public var dataPath: String
    public var resultPath: String
    public var selfTest: Bool
}

public enum DebugLaunchFile {
    public static let url = URL(fileURLWithPath: "/tmp/itimer-self-test.request")
    public static let current: DebugLaunch? = DebugLaunchFile.consume()

    public static func consume() -> DebugLaunch? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return try? JSONDecoder().decode(DebugLaunch.self, from: data)
    }
}

@MainActor
@Observable
public final class TaskStore {
    public static let shared = TaskStore(url: TaskStore.defaultURL())
    public private(set) var tasks: [TaskItem]
    public private(set) var brainSplitThreshold: Int
    public private(set) var calendarSyncEnabled: Bool
    public private(set) var now: Date
    public private(set) var lastError: String?
    public let url: URL

    /// Calendar writer, injected by the app. Nil in tests unless a fake is set.
    public var syncer: (any TaskCalendarSyncing)?

    private var ticker: DispatchSourceTimer?

    public init(url: URL, now: Date = Date()) {
        self.url = url
        self.now = now
        let loaded = Self.read(url: url)
        self.tasks = loaded.tasks
        self.brainSplitThreshold = loaded.brainSplitThreshold
        self.calendarSyncEnabled = loaded.calendarSyncEnabled
        self.lastError = loaded.error
    }

    public static func defaultURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["ITIMER_DATA_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let path = DebugLaunchFile.current?.dataPath, !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("iTimer/state.json", isDirectory: false)
    }

    public var runningTasks: [TaskItem] {
        tasks.filter(\.isRunning).sorted { ($0.currentStart ?? $0.createdAt) < ($1.currentStart ?? $1.createdAt) }
    }

    public var pausedTasks: [TaskItem] {
        tasks.filter(\.isPaused).sorted { $0.createdAt > $1.createdAt }
    }

    public var runningCount: Int { runningTasks.count }

    public var longestRunningElapsed: TimeInterval {
        runningTasks.map { $0.duration(asOf: now) }.max() ?? 0
    }

    public var liveVerdict: FocusVerdict {
        ParallelismAnalyzer.liveVerdict(runningCount: runningCount, threshold: brainSplitThreshold)
    }

    public var statusLabel: String {
        StatusText.label(
            runningCount: runningCount,
            longestElapsed: longestRunningElapsed,
            threshold: brainSplitThreshold
        )
    }

    public var statusAccessibilityLabel: String {
        StatusText.accessibility(
            runningCount: runningCount,
            threshold: brainSplitThreshold,
            verdict: liveVerdict
        )
    }

    public func startTicking() {
        guard ticker == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 1, repeating: 1)
        source.setEventHandler {
            Task { @MainActor in
                TaskStore.tickShared()
            }
        }
        source.resume()
        ticker = source
    }

    private static func tickShared() {
        shared.now = Date()
    }

    /// Advance the observable clock. The app drives this so it can pause
    /// updates while the status panel is open.
    public func tick() {
        now = Date()
    }

    @discardableResult
    public func addTask(title: String, at now: Date? = nil) -> TaskItem? {
        let stamp = now ?? self.now
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let parsed = TitleParser.parse(cleaned)
        guard !parsed.title.isEmpty else { return nil }
        let limited = String(parsed.title.prefix(80))
        let task = TaskItem(
            title: limited,
            createdAt: stamp,
            segments: [TimeSegment(startedAt: stamp)],
            tags: parsed.tags
        )
        tasks.insert(task, at: 0)
        self.now = stamp
        save()
        syncTask(id: task.id)
        return tasks.first { $0.id == task.id }
    }

    @discardableResult
    public func pause(id: UUID, at now: Date? = nil) -> Bool {
        let stamp = now ?? self.now
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].isRunning else { return false }
        guard var segment = tasks[index].segments.last else { return false }
        segment.endedAt = max(segment.startedAt, stamp)
        tasks[index].segments[tasks[index].segments.count - 1] = segment
        self.now = stamp
        save()
        syncTask(id: id)
        return true
    }

    @discardableResult
    public func resume(id: UUID, at now: Date? = nil) -> Bool {
        let stamp = now ?? self.now
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        guard !tasks[index].isRunning else { return false }
        tasks[index].completedAt = nil
        tasks[index].segments.append(TimeSegment(startedAt: stamp))
        self.now = stamp
        save()
        syncTask(id: id)
        return true
    }

    @discardableResult
    public func complete(id: UUID, at now: Date? = nil) -> Bool {
        let stamp = now ?? self.now
        guard let index = tasks.firstIndex(where: { $0.id == id }), !tasks[index].isCompleted else { return false }
        if tasks[index].isRunning, var segment = tasks[index].segments.last {
            segment.endedAt = max(segment.startedAt, stamp)
            tasks[index].segments[tasks[index].segments.count - 1] = segment
        }
        tasks[index].completedAt = stamp
        self.now = stamp
        save()
        syncTask(id: id)
        return true
    }

    @discardableResult
    public func rename(id: UUID, title: String) -> Bool {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        tasks[index].title = String(cleaned.prefix(80))
        save()
        syncTask(id: id)
        return true
    }

    @discardableResult
    public func delete(id: UUID) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        let removed = tasks.remove(at: index)
        if calendarSyncEnabled, let syncer, let eventID = removed.calendarEventID {
            syncer.remove(eventID: eventID)
        }
        save()
        return true
    }

    public func setCalendarSyncEnabled(_ enabled: Bool) {
        guard enabled != calendarSyncEnabled else { return }
        calendarSyncEnabled = enabled
        save()
        if enabled {
            for task in tasks {
                syncTask(id: task.id)
            }
        }
    }

    /// Re-push an event, e.g. to extend the end time of a running task.
    public func resync(id: UUID) {
        syncTask(id: id)
    }

    private func syncTask(id: UUID) {
        guard calendarSyncEnabled, let syncer, let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard let eventID = syncer.upsert(task: tasks[index], asOf: now) else { return }
        if tasks[index].calendarEventID != eventID {
            tasks[index].calendarEventID = eventID
            save()
        }
    }

    public func setThreshold(_ value: Int) {
        let clamped = BrainSplitRules.clamp(value)
        guard clamped != brainSplitThreshold else { return }
        brainSplitThreshold = clamped
        save()
    }

    public func report(range: AnalysisRange, calendar: Calendar = .current) -> ParallelismReport {
        let window = range.window(asOf: now, tasks: tasks, calendar: calendar)
        return ParallelismAnalyzer.report(
            tasks: tasks,
            window: window,
            threshold: brainSplitThreshold,
            now: now
        )
    }

    public func save() {
        let snapshot = StoreSnapshot(
            brainSplitThreshold: brainSplitThreshold,
            tasks: tasks,
            calendarSyncEnabled: calendarSyncEnabled
        )
        do {
            try Self.write(snapshot, to: url)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private struct LoadResult {
        var tasks: [TaskItem]
        var brainSplitThreshold: Int
        var calendarSyncEnabled: Bool
        var error: String?
    }

    private static func read(url: URL) -> LoadResult {
        let fallback = LoadResult(
            tasks: [],
            brainSplitThreshold: BrainSplitRules.defaultThreshold,
            calendarSyncEnabled: false,
            error: nil
        )
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(StoreSnapshot.self, from: data)
            return LoadResult(
                tasks: snapshot.tasks,
                brainSplitThreshold: BrainSplitRules.clamp(snapshot.brainSplitThreshold),
                calendarSyncEnabled: snapshot.calendarSyncEnabled,
                error: nil
            )
        } catch {
            let bad = url.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: bad)
            try? FileManager.default.moveItem(at: url, to: bad)
            return LoadResult(
                tasks: [],
                brainSplitThreshold: BrainSplitRules.defaultThreshold,
                calendarSyncEnabled: false,
                error: "计时记录损坏，已备份后重新开始"
            )
        }
    }

    private static func write(_ snapshot: StoreSnapshot, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }
}
