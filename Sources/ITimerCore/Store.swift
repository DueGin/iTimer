import Foundation
import Observation

public struct StoreSnapshot: Codable, Equatable, Sendable {
    public var version: Int
    public var brainSplitThreshold: Int
    public var tasks: [TaskItem]
    public var calendarSyncEnabled: Bool
    public var workflows: [Workflow]

    public init(
        version: Int = 2,
        brainSplitThreshold: Int,
        tasks: [TaskItem],
        calendarSyncEnabled: Bool = false,
        workflows: [Workflow] = []
    ) {
        self.version = version
        self.brainSplitThreshold = brainSplitThreshold
        self.tasks = tasks
        self.calendarSyncEnabled = calendarSyncEnabled
        self.workflows = workflows
    }

    private enum CodingKeys: String, CodingKey {
        case version, brainSplitThreshold, tasks, calendarSyncEnabled, workflows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        brainSplitThreshold = try container.decode(Int.self, forKey: .brainSplitThreshold)
        tasks = try container.decode([TaskItem].self, forKey: .tasks)
        calendarSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .calendarSyncEnabled) ?? false
        workflows = try container.decodeIfPresent([Workflow].self, forKey: .workflows) ?? []
    }
}

public struct DebugLaunch: Codable, Equatable, Sendable {
    public var dataPath: String
    public var resultPath: String
    public var selfTest: Bool
    /// Which self-test to run; nil = the full panel and window run.
    public var scenario: String?
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
    /// User-created workflow canvases, in sidebar order.
    public private(set) var workflows: [Workflow]
    public private(set) var now: Date
    public private(set) var lastError: String?
    public let url: URL

    /// Calendar writer, injected by the app. Nil in tests unless a fake is set.
    public var syncer: (any TaskCalendarSyncing)?

    /// Told whenever finishing a task moves a workflow along (downstream
    /// tasks started or now clear to start). Injected by the app.
    public var onWorkflowAdvance: (@MainActor (WorkflowAdvance) -> Void)?

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
        self.workflows = loaded.workflows
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

    /// What the quick field would need to recreate `task`: "写周报 #汇报".
    public static func input(for task: TaskItem) -> String {
        TitleParser.input(title: task.title, tags: task.tags)
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

    /// Direct children of a task, oldest first. Subtasks are one level deep.
    public func subtasks(of id: UUID) -> [TaskItem] {
        tasks.filter { $0.parentID == id }.sorted { $0.createdAt < $1.createdAt }
    }

    public func parent(of task: TaskItem) -> TaskItem? {
        guard let parentID = task.parentID else { return nil }
        return tasks.first { $0.id == parentID }
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
    public func addTask(
        title: String,
        parentID: UUID? = nil,
        at now: Date? = nil
    ) -> TaskItem? {
        let stamp = now ?? Date()
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let parsed = TitleParser.parse(cleaned)
        guard !parsed.title.isEmpty else { return nil }
        // A named parent that cannot take children (missing, or itself a
        // subtask) is a refusal, not a silent promotion to a root task.
        if parentID != nil, resolvedParent(parentID) == nil { return nil }
        let parent = resolvedParent(parentID)
        let task = TaskItem(
            title: String(parsed.title.prefix(80)),
            createdAt: stamp,
            segments: [TimeSegment(startedAt: stamp)],
            tags: parsed.tags,
            parentID: parent?.id
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
    /// `tags` add to whatever `#` the title carries. A subtask cannot itself
    /// be a parent.
    @discardableResult
    public func addSchedule(
        title: String,
        tags: [String] = [],
        parentID: UUID? = nil,
        start: Date?,
        plannedDuration: TimeInterval?,
        reminderLead: TimeInterval?,
        at now: Date? = nil
    ) -> TaskItem? {
        let stamp = now ?? self.now
        let parsed = TitleParser.parse(title.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !parsed.title.isEmpty else { return nil }
        if parentID != nil, resolvedParent(parentID) == nil { return nil }
        let parent = resolvedParent(parentID)
        let task = TaskItem(
            title: String(parsed.title.prefix(80)),
            createdAt: stamp,
            tags: TitleParser.merge(tags, parsed.tags),
            parentID: parent?.id,
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
        advanceWorkflow(after: id, at: stamp)
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

    /// Replace title and tags from one quick-field style input
    /// ("写周报 #汇报"). A bare title clears tags.
    @discardableResult
    public func retitle(id: UUID, input: String) -> Bool {
        let parsed = TitleParser.parse(input.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !parsed.title.isEmpty, let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        tasks[index].title = String(parsed.title.prefix(80))
        tasks[index].tags = parsed.tags
        save()
        syncTask(id: id)
        return true
    }

    @discardableResult
    public func setTags(id: UUID, _ tags: [String]) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        let cleaned = TitleParser.merge(tags.map(TitleParser.cleanTag).filter { !$0.isEmpty }, [])
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

    /// Replace the standing note. Whitespace-only becomes empty.
    @discardableResult
    public func setNote(id: UUID, _ note: String) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        let cleaned = Self.cleanJournal(note)
        guard cleaned != tasks[index].note else { return true }
        tasks[index].note = cleaned
        save()
        syncTask(id: id)
        return true
    }

    /// Append a progress comment. Empty text is refused.
    @discardableResult
    public func addComment(id: UUID, text: String, at now: Date? = nil) -> TaskComment? {
        let cleaned = Self.cleanJournal(text)
        guard !cleaned.isEmpty, let index = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        let comment = TaskComment(text: cleaned, createdAt: now ?? self.now)
        tasks[index].comments.append(comment)
        save()
        syncTask(id: id)
        return comment
    }

    /// Removes one comment. Returns false if the task or comment is gone.
    @discardableResult
    public func deleteComment(id: UUID, commentID: UUID) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              let comment = tasks[index].comments.firstIndex(where: { $0.id == commentID }) else { return false }
        tasks[index].comments.remove(at: comment)
        save()
        syncTask(id: id)
        return true
    }

    /// Collapse blank lines and cap length so a journal entry stays a note,
    /// not a document. Indentation inside is kept so nested lists survive.
    static func cleanJournal(_ text: String) -> String {
        let lines = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .map { line in String(line.reversed().drop(while: \.isWhitespace).reversed()) }
        var collapsed: [String] = []
        var blank = false
        for line in lines {
            if line.isEmpty {
                if !collapsed.isEmpty { blank = true }
                continue
            }
            if blank { collapsed.append("") }
            collapsed.append(line)
            blank = false
        }
        return String(collapsed.joined(separator: "\n").prefix(2000))
    }

    /// Makes `id` a subtask of `parentID`, or a top-level task when nil.
    /// Refuses a parent that is itself a subtask, or a task that already
    /// has children — nesting stays one level deep.
    @discardableResult
    public func setParent(id: UUID, _ parentID: UUID?) -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return false }
        guard !tasks.contains(where: { $0.parentID == id }) else { return false }
        if parentID == nil {
            guard tasks[index].parentID != nil else { return true }
            tasks[index].parentID = nil
            save()
            return true
        }
        guard let parent = resolvedParent(parentID), parent.id != id else { return false }
        guard tasks[index].parentID != parent.id else { return true }
        tasks[index].parentID = parent.id
        save()
        syncTask(id: id)
        return true
    }

    /// Adds a subtask under `parentID` and starts it immediately.
    @discardableResult
    public func addSubtask(parentID: UUID, title: String, at now: Date? = nil) -> TaskItem? {
        addTask(title: title, parentID: parentID, at: now)
    }

    /// A parent that can still take children: it exists and is itself a root.
    private func resolvedParent(_ id: UUID?) -> TaskItem? {
        guard let id, let parent = tasks.first(where: { $0.id == id }), parent.parentID == nil else { return nil }
        return parent
    }

    // MARK: - Workflows

    public func workflow(id: UUID?) -> Workflow? {
        guard let id else { return nil }
        return workflows.first { $0.id == id }
    }

    /// The workflow a task sits on. A task sits on at most one.
    public func workflow(containing taskID: UUID) -> Workflow? {
        workflows.first { $0.contains(taskID) }
    }

    /// Tasks by id, for reading workflow state.
    public var tasksByID: [UUID: TaskItem] {
        Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Where a task stands in its workflow; nil when it is on none.
    public func workflowState(of taskID: UUID) -> WorkflowNodeState? {
        workflow(containing: taskID)?.state(of: taskID, tasks: tasksByID)
    }

    /// Upstream tasks a workflow task is still waiting on.
    public func workflowBlockers(of taskID: UUID) -> [TaskItem] {
        guard let workflow = workflow(containing: taskID) else { return [] }
        let byID = tasksByID
        return workflow.blockers(of: taskID, tasks: byID).compactMap { byID[$0] }
    }

    /// Adds an empty canvas. A name already in use gets a number, so a
    /// quick "new workflow" never fails.
    @discardableResult
    public func addWorkflow(_ name: String, at now: Date? = nil) -> Workflow? {
        let cleaned = Workflow.clean(name)
        guard !cleaned.isEmpty else { return nil }
        let taken = Set(workflows.map(\.name))
        var unique = cleaned
        var number = 2
        while taken.contains(unique) {
            unique = "\(cleaned) \(number)"
            number += 1
        }
        let workflow = Workflow(name: unique, createdAt: now ?? self.now)
        workflows.append(workflow)
        save()
        return workflow
    }

    @discardableResult
    public func renameWorkflow(id: UUID, to name: String) -> Bool {
        let cleaned = Workflow.clean(name)
        guard !cleaned.isEmpty, let index = workflows.firstIndex(where: { $0.id == id }) else { return false }
        guard cleaned != workflows[index].name else { return true }
        workflows[index].name = cleaned
        save()
        return true
    }

    /// Removes the canvas. Its tasks stay, just off any workflow.
    public func removeWorkflow(id: UUID) {
        guard let index = workflows.firstIndex(where: { $0.id == id }) else { return }
        workflows.remove(at: index)
        save()
    }

    public func moveWorkflow(id: UUID, by offset: Int) {
        guard let index = workflows.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard workflows.indices.contains(target) else { return }
        workflows.swapAt(index, target)
        save()
    }

    /// Puts a task on a workflow at a canvas point, or right of the
    /// rightmost card without one. A task on another workflow leaves it,
    /// edges and all; on this one it just moves.
    @discardableResult
    public func place(taskID: UUID, in workflowID: UUID, x: Double? = nil, y: Double? = nil) -> Bool {
        guard tasks.contains(where: { $0.id == taskID }),
              let target = workflows.firstIndex(where: { $0.id == workflowID }) else { return false }
        if workflows[target].contains(taskID) {
            guard let x, let y else { return true }
            return moveNode(taskID: taskID, in: workflowID, x: x, y: y)
        }
        for index in workflows.indices where index != target && workflows[index].contains(taskID) {
            let others = Set(workflows[index].nodes.map(\.taskID)).subtracting([taskID])
            workflows[index] = workflows[index].pruned(keeping: others)
        }
        let slot = workflows[target].nextSlot()
        workflows[target].nodes.append(WorkflowNode(taskID: taskID, x: x ?? slot.x, y: y ?? slot.y))
        save()
        return true
    }

    @discardableResult
    public func moveNode(taskID: UUID, in workflowID: UUID, x: Double, y: Double) -> Bool {
        guard let index = workflows.firstIndex(where: { $0.id == workflowID }),
              let node = workflows[index].nodes.firstIndex(where: { $0.taskID == taskID }) else { return false }
        guard workflows[index].nodes[node].x != x || workflows[index].nodes[node].y != y else { return true }
        workflows[index].nodes[node].x = x
        workflows[index].nodes[node].y = y
        save()
        return true
    }

    /// Takes a task off its canvas, with its edges. The task itself stays.
    @discardableResult
    public func removeNode(taskID: UUID, from workflowID: UUID) -> Bool {
        guard let index = workflows.firstIndex(where: { $0.id == workflowID }),
              workflows[index].contains(taskID) else { return false }
        let others = Set(workflows[index].nodes.map(\.taskID)).subtracting([taskID])
        workflows[index] = workflows[index].pruned(keeping: others)
        save()
        return true
    }

    /// A new step drawn on the canvas: an undated schedule (it waits to be
    /// started like any other), placed at the point. With `upstream` it is
    /// wired after that task.
    @discardableResult
    public func addWorkflowStep(
        title: String,
        in workflowID: UUID,
        x: Double,
        y: Double,
        after upstream: UUID? = nil,
        at now: Date? = nil
    ) -> TaskItem? {
        guard workflow(id: workflowID) != nil else { return nil }
        guard let task = addSchedule(
            title: title,
            start: nil,
            plannedDuration: nil,
            reminderLead: nil,
            at: now
        ) else { return nil }
        place(taskID: task.id, in: workflowID, x: x, y: y)
        if let upstream {
            connect(from: upstream, to: task.id, in: workflowID)
        }
        return task
    }

    /// Wires `from` before `to`. Refuses a loop, a repeat, a self-edge, or
    /// a task that is not on this canvas.
    @discardableResult
    public func connect(from: UUID, to: UUID, in workflowID: UUID) -> Bool {
        guard let index = workflows.firstIndex(where: { $0.id == workflowID }),
              workflows[index].canConnect(from: from, to: to) else { return false }
        workflows[index].edges.append(WorkflowEdge(from: from, to: to))
        save()
        return true
    }

    @discardableResult
    public func disconnect(from: UUID, to: UUID, in workflowID: UUID) -> Bool {
        guard let index = workflows.firstIndex(where: { $0.id == workflowID }) else { return false }
        let edge = WorkflowEdge(from: from, to: to)
        guard workflows[index].edges.contains(edge) else { return false }
        workflows[index].edges.removeAll { $0 == edge }
        save()
        return true
    }

    /// Whether the task starts on its own once its upstream is done.
    /// Turning it on does not start a task that is already clear.
    @discardableResult
    public func setAutoStart(taskID: UUID, in workflowID: UUID, _ on: Bool) -> Bool {
        guard let index = workflows.firstIndex(where: { $0.id == workflowID }),
              let node = workflows[index].nodes.firstIndex(where: { $0.taskID == taskID }) else { return false }
        guard workflows[index].nodes[node].autoStart != on else { return true }
        workflows[index].nodes[node].autoStart = on
        save()
        return true
    }

    /// Lays the canvas out in columns by dependency depth.
    public func arrangeWorkflow(id: UUID) {
        guard let index = workflows.firstIndex(where: { $0.id == id }) else { return }
        let positions = workflows[index].arranged()
        for node in workflows[index].nodes.indices {
            guard let point = positions[workflows[index].nodes[node].taskID] else { continue }
            workflows[index].nodes[node].x = point.x
            workflows[index].nodes[node].y = point.y
        }
        save()
    }

    /// Remembers pan and zoom so the canvas reopens where it was left.
    public func setViewport(id: UUID, _ viewport: WorkflowViewport) {
        guard let index = workflows.firstIndex(where: { $0.id == id }),
              workflows[index].viewport != viewport else { return }
        workflows[index].viewport = viewport
        save()
    }

    /// After `id` is done: start the downstream tasks set to start on their
    /// own, and report the ones now clear to start by hand.
    private func advanceWorkflow(after id: UUID, at stamp: Date) {
        guard let workflow = workflow(containing: id) else { return }
        var advance = WorkflowAdvance(
            workflowID: workflow.id,
            workflowName: workflow.name,
            completedTaskID: id,
            started: [],
            ready: []
        )
        for next in workflow.downstream(of: id) {
            let byID = tasksByID
            guard let task = byID[next], !task.isCompleted, !task.isRunning,
                  workflow.blockers(of: next, tasks: byID).isEmpty else { continue }
            if workflow.node(next)?.autoStart == true, resume(id: next, at: stamp) {
                advance.started.append(next)
            } else {
                advance.ready.append(next)
            }
        }
        guard !advance.isEmpty else { return }
        onWorkflowAdvance?(advance)
    }

    /// Deletes a task and, if it is a parent, every subtask under it.
    @discardableResult
    public func delete(id: UUID) -> Bool {
        let doomed = tasks.filter { $0.id == id || $0.parentID == id }
        guard !doomed.isEmpty else { return false }
        tasks.removeAll { $0.id == id || $0.parentID == id }
        let kept = Set(tasks.map(\.id))
        workflows = workflows.map { $0.pruned(keeping: kept) }
        if calendarSyncEnabled, let syncer {
            doomed.flatMap(\.calendarEventIDs).forEach(syncer.remove(eventID:))
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
            workflows: workflows
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
        var workflows: [Workflow] = []
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
                // Nodes for tasks that are gone would draw as empty cards.
                workflows: snapshot.workflows.map { $0.pruned(keeping: Set(snapshot.tasks.map(\.id))) },
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
