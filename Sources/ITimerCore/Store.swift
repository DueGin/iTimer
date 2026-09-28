import Foundation
import Observation

public struct StoreSnapshot: Codable, Equatable, Sendable {
    public var version: Int
    public var brainSplitThreshold: Int
    public var tasks: [TaskItem]
    public var calendarSyncEnabled: Bool
    public var categories: [TaskCategory]

    public init(
        version: Int = 1,
        brainSplitThreshold: Int,
        tasks: [TaskItem],
        calendarSyncEnabled: Bool = false,
        categories: [TaskCategory] = TaskCategory.defaults
    ) {
        self.version = version
        self.brainSplitThreshold = brainSplitThreshold
        self.tasks = tasks
        self.calendarSyncEnabled = calendarSyncEnabled
        self.categories = categories
    }

    private enum CodingKeys: String, CodingKey {
        case version, brainSplitThreshold, tasks, calendarSyncEnabled, categories
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        brainSplitThreshold = try container.decode(Int.self, forKey: .brainSplitThreshold)
        tasks = try container.decode([TaskItem].self, forKey: .tasks)
        calendarSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .calendarSyncEnabled) ?? false
        categories = try container.decodeIfPresent([TaskCategory].self, forKey: .categories) ?? TaskCategory.defaults
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
    /// User-managed categories, in display order.
    public private(set) var categories: [TaskCategory]
    public private(set) var now: Date
    public private(set) var lastError: String?
    public let url: URL

    /// Calendar writer, injected by the app. Nil in tests unless a fake is set.
    public var syncer: (any TaskCalendarSyncing)?

    /// Notification scheduler, injected by the app. Reconciled after every save.
    public var reminders: (any ScheduleReminding)? {
        didSet { reconcileReminders() }
    }

    private var ticker: DispatchSourceTimer?

    public init(url: URL, now: Date = Date()) {
        self.url = url
        self.now = now
        let loaded = Self.read(url: url)
        self.tasks = loaded.tasks
        self.brainSplitThreshold = loaded.brainSplitThreshold
        self.calendarSyncEnabled = loaded.calendarSyncEnabled
        self.categories = loaded.categories
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

    /// Schedules whose time has come but which have not been started yet.
    public var dueSchedules: [TaskItem] {
        tasks.filter { $0.isDue(asOf: now) }.sorted(by: Self.byScheduledStart)
    }

    /// Schedules still in the future.
    public var upcomingSchedules: [TaskItem] {
        tasks.filter { $0.isPending && $0.scheduledStart != nil && !$0.isDue(asOf: now) }.sorted(by: Self.byScheduledStart)
    }

    /// Schedules without a time yet, oldest first.
    public var undatedSchedules: [TaskItem] {
        tasks.filter(\.isUndated).sorted { $0.createdAt < $1.createdAt }
    }

    private static func byScheduledStart(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        (lhs.scheduledStart ?? lhs.createdAt) < (rhs.scheduledStart ?? rhs.createdAt)
    }

    public var runningCount: Int { runningTasks.count }

    /// Tasks finished since local midnight, most recent first.
    public func completedToday(calendar: Calendar = .current) -> [TaskItem] {
        let start = calendar.startOfDay(for: now)
        return tasks
            .filter { ($0.completedAt ?? .distantPast) >= start }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    /// Recently used task inputs ("title #tag"), newest first, for one-tap
    /// restarts. Skips anything still open and exact matches of the query.
    public func suggestions(matching query: String = "", limit: Int = 6) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let open = Set(tasks.filter { !$0.isCompleted }.map { Self.input(for: $0).lowercased() })
        var seen: Set<String> = []
        var result: [String] = []
        for task in tasks.sorted(by: { $0.createdAt > $1.createdAt }) {
            let input = Self.input(for: task)
            let key = input.lowercased()
            guard !open.contains(key), seen.insert(key).inserted else { continue }
            if !needle.isEmpty {
                guard key.contains(needle), key != needle else { continue }
            }
            result.append(input)
            if result.count == limit { break }
        }
        return result
    }

    /// What the quick field would need to recreate `task`: "写周报 @工作 #汇报".
    public static func input(for task: TaskItem) -> String {
        TitleParser.input(title: task.title, tags: task.tags, category: task.category)
    }

    /// Every tag in use, most recently used first.
    public var knownTags: [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for task in tasks.sorted(by: { $0.createdAt > $1.createdAt }) {
            for tag in task.tags where seen.insert(tag.lowercased()).inserted {
                result.append(tag)
            }
        }
        return result
    }

    public func category(named name: String?) -> TaskCategory? {
        guard let name else { return nil }
        return categories.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public var longestRunningElapsed: TimeInterval {
        runningTasks.map { $0.duration(asOf: now) }.max() ?? 0
    }

    public var liveVerdict: FocusVerdict {
        statusFrozen ? frozenVerdict : computedLiveVerdict
    }

    public var statusLabel: String {
        statusFrozen ? frozenLabel : computedStatusLabel
    }

    public var statusAccessibilityLabel: String {
        statusFrozen ? frozenAccessibilityLabel : computedStatusAccessibilityLabel
    }

    /// Running count as the status item shows it (held while frozen, since
    /// the icon draws one brain piece per running task).
    public var statusRunningCount: Int {
        statusFrozen ? frozenRunningCount : runningCount
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

    // MARK: - Status label freeze

    /// While the MenuBarExtra panel is open, SwiftUI dismisses the panel on
    /// ANY label change — including task actions (pause/complete) that change
    /// the label text. Freeze the label presentation for the panel's lifetime.
    private var statusFrozen = false
    private var frozenLabel = ""
    private var frozenVerdict: FocusVerdict = .idle
    private var frozenAccessibilityLabel = ""
    private var frozenRunningCount = 0

    public func setStatusFrozen(_ frozen: Bool) {
        guard frozen != statusFrozen else { return }
        if frozen {
            frozenLabel = computedStatusLabel
            frozenVerdict = computedLiveVerdict
            frozenAccessibilityLabel = computedStatusAccessibilityLabel
            frozenRunningCount = runningCount
        }
        statusFrozen = frozen
    }

    public var isStatusFrozen: Bool { statusFrozen }

    private var computedLiveVerdict: FocusVerdict {
        ParallelismAnalyzer.liveVerdict(runningCount: runningCount, threshold: brainSplitThreshold)
    }

    private var computedStatusLabel: String {
        StatusText.label(
            runningCount: runningCount,
            longestElapsed: longestRunningElapsed,
            threshold: brainSplitThreshold,
            dueCount: dueSchedules.count
        )
    }

    private var computedStatusAccessibilityLabel: String {
        StatusText.accessibility(
            runningCount: runningCount,
            threshold: brainSplitThreshold,
            verdict: liveVerdict,
            dueCount: dueSchedules.count
        )
    }

    @discardableResult
    public func addTask(title: String, at now: Date? = nil) -> TaskItem? {
        let stamp = now ?? Date()
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let parsed = TitleParser.parse(cleaned)
        guard !parsed.title.isEmpty else { return nil }
        let limited = String(parsed.title.prefix(80))
        let task = TaskItem(
            title: limited,
            createdAt: stamp,
            segments: [TimeSegment(startedAt: stamp)],
            tags: parsed.tags,
            category: resolveCategory(parsed.category)
        )
        tasks.insert(task, at: 0)
        self.now = stamp
        save()
        syncTask(id: task.id)
        return tasks.first { $0.id == task.id }
    }

    /// Add a schedule. It does not start timing — not even once its start
    /// time passes; the user starts it explicitly via `resume(id:)`.
    /// `start` nil = time to be decided; such a schedule has no reminder.
    /// `tags` and `category` add to whatever `#`/`@` the title carries.
    @discardableResult
    public func addSchedule(
        title: String,
        tags: [String] = [],
        category: String? = nil,
        start: Date?,
        plannedDuration: TimeInterval?,
        reminderLead: TimeInterval?,
        at now: Date? = nil
    ) -> TaskItem? {
        let stamp = now ?? self.now
        let parsed = TitleParser.parse(title.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !parsed.title.isEmpty else { return nil }
        let task = TaskItem(
            title: String(parsed.title.prefix(80)),
            createdAt: stamp,
            tags: TitleParser.merge(tags, parsed.tags),
            category: resolveCategory(parsed.category ?? category),
            scheduledStart: start,
            plannedDuration: plannedDuration.map { max(60, $0) },
            reminderLead: start == nil ? nil : reminderLead.map { max(0, $0) }
        )
        tasks.insert(task, at: 0)
        save()
        syncTask(id: task.id)
        return tasks.first { $0.id == task.id }
    }

    /// Change time, estimate or reminder. The estimate stays editable while
    /// running (e.g. to admit it will take longer); the start only before.
    @discardableResult
    public func updateSchedule(
        id: UUID,
        start: Date?,
        plannedDuration: TimeInterval?,
        reminderLead: TimeInterval?
    ) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }), !tasks[index].isCompleted else { return false }
        if tasks[index].isPending {
            tasks[index].scheduledStart = start
        }
        tasks[index].plannedDuration = plannedDuration.map { max(60, $0) }
        tasks[index].reminderLead = tasks[index].isUndated ? nil : reminderLead.map { max(0, $0) }
        save()
        syncTask(id: id)
        return true
    }

    /// Snooze a pending schedule: move its start to `interval` from now.
    @discardableResult
    public func postpone(id: UUID, by interval: TimeInterval, at now: Date? = nil) -> Bool {
        let stamp = now ?? self.now
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].isPending else { return false }
        tasks[index].scheduledStart = stamp.addingTimeInterval(interval)
        self.now = stamp
        save()
        syncTask(id: id)
        return true
    }

    @discardableResult
    public func pause(id: UUID, at now: Date? = nil) -> Bool {
        let stamp = now ?? Date()
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
        let stamp = now ?? Date()
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
        let stamp = now ?? Date()
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

    /// Single-core mode: keep only this task running. Pauses every other
    /// running task and resumes this one if it was paused.
    @discardableResult
    public func focus(id: UUID, at now: Date? = nil) -> Bool {
        let stamp = now ?? Date()
        guard let target = tasks.first(where: { $0.id == id }), !target.isCompleted else { return false }
        for other in runningTasks where other.id != id {
            pause(id: other.id, at: stamp)
        }
        if !target.isRunning {
            resume(id: id, at: stamp)
        }
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

    /// Replace title, tags and category from one quick-field style input
    /// ("写周报 @工作 #汇报"). A bare title clears tags and category.
    @discardableResult
    public func retitle(id: UUID, input: String) -> Bool {
        let parsed = TitleParser.parse(input.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !parsed.title.isEmpty, let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        tasks[index].title = String(parsed.title.prefix(80))
        tasks[index].tags = parsed.tags
        tasks[index].category = resolveCategory(parsed.category)
        save()
        syncTask(id: id)
        return true
    }

    @discardableResult
    public func setTags(id: UUID, _ tags: [String]) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        let cleaned = TitleParser.merge(tags.map(TaskCategory.clean).filter { !$0.isEmpty }, [])
        guard cleaned != tasks[index].tags else { return true }
        tasks[index].tags = cleaned
        save()
        syncTask(id: id)
        return true
    }

    @discardableResult
    public func toggleTag(id: UUID, _ tag: String) -> Bool {
        guard let task = tasks.first(where: { $0.id == id }) else { return false }
        let has = task.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        return setTags(id: id, has ? task.tags.filter { $0.caseInsensitiveCompare(tag) != .orderedSame } : task.tags + [tag])
    }

    /// nil = 未分类. An unknown name creates the category.
    @discardableResult
    public func setCategory(id: UUID, _ name: String?) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        let resolved = resolveCategory(name)
        guard resolved != tasks[index].category else { return true }
        tasks[index].category = resolved
        save()
        syncTask(id: id)
        return true
    }

    // MARK: - Categories

    /// Adds a category (next palette color) and returns it; an existing
    /// name returns the existing one.
    @discardableResult
    public func addCategory(_ name: String) -> TaskCategory? {
        let cleaned = TaskCategory.clean(name)
        guard !cleaned.isEmpty, cleaned != CategoryStats.uncategorized else { return nil }
        if let existing = category(named: cleaned) { return existing }
        let used = Set(categories.map(\.color))
        let color = (0..<Self.categoryColorCount).first { !used.contains($0) } ?? categories.count % Self.categoryColorCount
        let category = TaskCategory(name: cleaned, color: color)
        categories.append(category)
        save()
        return category
    }

    /// Renames the category and every task filed under it.
    @discardableResult
    public func renameCategory(_ old: String, to new: String) -> Bool {
        let cleaned = TaskCategory.clean(new)
        guard !cleaned.isEmpty, cleaned != CategoryStats.uncategorized,
              let index = categories.firstIndex(where: { $0.name == old }) else { return false }
        if cleaned == old { return true }
        guard category(named: cleaned) == nil || cleaned.caseInsensitiveCompare(old) == .orderedSame else { return false }
        categories[index].name = cleaned
        let affected = tasks.indices.filter { tasks[$0].category == old }
        for task in affected { tasks[task].category = cleaned }
        save()
        affected.forEach { syncTask(id: tasks[$0].id) }
        return true
    }

    /// Removes the category; its tasks become 未分类.
    public func removeCategory(_ name: String) {
        guard let index = categories.firstIndex(where: { $0.name == name }) else { return }
        categories.remove(at: index)
        let affected = tasks.indices.filter { tasks[$0].category == name }
        for task in affected { tasks[task].category = nil }
        save()
        affected.forEach { syncTask(id: tasks[$0].id) }
    }

    public func setCategoryColor(_ name: String, color: Int) {
        guard let index = categories.firstIndex(where: { $0.name == name }), categories[index].color != color else { return }
        categories[index].color = color
        save()
    }

    public func moveCategory(_ name: String, by offset: Int) {
        guard let index = categories.firstIndex(where: { $0.name == name }) else { return }
        let target = index + offset
        guard categories.indices.contains(target) else { return }
        categories.swapAt(index, target)
        save()
    }

    /// Size of the app's category palette; colors cycle past it.
    public static let categoryColorCount = 8

    /// Canonical spelling of `name`, creating the category if it is new.
    private func resolveCategory(_ name: String?) -> String? {
        guard let name, !TaskCategory.clean(name).isEmpty else { return nil }
        return addCategory(name)?.name
    }

    @discardableResult
    public func delete(id: UUID) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        let removed = tasks.remove(at: index)
        if calendarSyncEnabled, let syncer {
            removed.calendarEventIDs.forEach(syncer.remove(eventID:))
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
        // Nothing to place on a calendar until it has a time.
        let ranges = tasks[index].isUndated ? [] : tasks[index].calendarRanges(asOf: now)
        let existing = tasks[index].calendarEventIDs
        var ids: [String] = []
        for (offset, range) in ranges.enumerated() {
            let current = offset < existing.count ? existing[offset] : nil
            guard let id = syncer.upsert(task: tasks[index], range: range, eventID: current) else { break }
            ids.append(id)
        }
        if ids.count == ranges.count {
            existing.dropFirst(ranges.count).forEach(syncer.remove(eventID:))
        } else {
            // A write failed: keep the old ids so the next sync can retry them.
            ids += existing.dropFirst(ids.count)
        }
        if tasks[index].calendarEventIDs != ids {
            tasks[index].calendarEventIDs = ids
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
            calendarSyncEnabled: calendarSyncEnabled,
            categories: categories
        )
        do {
            try Self.write(snapshot, to: url)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        reconcileReminders()
    }

    public func reconcileReminders() {
        reminders?.reconcile(ReminderPlan.reminders(for: tasks, asOf: now))
    }

    private struct LoadResult {
        var tasks: [TaskItem]
        var brainSplitThreshold: Int
        var calendarSyncEnabled: Bool
        var categories: [TaskCategory] = TaskCategory.defaults
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
                categories: snapshot.categories,
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
