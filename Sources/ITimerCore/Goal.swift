import Foundation

/// A milestone on a goal's roadmap: the workflow it stands for and where
/// its card sits.
public struct GoalNode: Codable, Equatable, Identifiable, Sendable, GraphNode {
    public var workflowID: UUID
    public var x: Double
    public var y: Double

    public var id: UUID { workflowID }

    public init(workflowID: UUID, x: Double, y: Double) {
        self.workflowID = workflowID
        self.x = x
        self.y = y
    }

    private enum CodingKeys: String, CodingKey {
        case workflowID, x, y
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workflowID = try container.decode(UUID.self, forKey: .workflowID)
        x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 0
    }
}

/// Where a milestone stands, read from its workflow and its upstream.
public enum MilestoneState: String, CaseIterable, Equatable, Sendable {
    /// Nothing started, and an upstream milestone is not reached yet.
    case blocked
    /// Nothing started, nothing upstream in the way.
    case ready
    /// Some task on it has been started (even ahead of its upstream).
    case active
    /// Every task is done, but nobody said it was reached.
    case review
    /// Marked reached.
    case achieved

    public var title: String {
        switch self {
        case .blocked: "等待上游"
        case .ready: "可开始"
        case .active: "推进中"
        case .review: "待确认"
        case .achieved: "已达成"
        }
    }
}

/// What a milestone card shows.
public struct MilestoneSummary: Equatable, Sendable {
    public var state: MilestoneState
    /// Tasks on the workflow canvas, done and in all.
    public var done: Int
    public var total: Int
    /// Time spent on the workflow's tasks and their subtasks.
    public var invested: TimeInterval
    public var running: Bool
    /// Upstream milestones not reached yet.
    public var blockers: [UUID]
    /// Days until the target date; negative once past it. nil = no date.
    public var daysLeft: Int?
}

/// A big goal: why it matters, and the milestones on the way, wired
/// "reach this first". A workflow sits on at most one goal; the edges
/// never form a cycle.
public struct Goal: Codable, Equatable, Identifiable, Sendable, DependencyGraph {
    public var id: UUID
    public var name: String
    /// Why it matters and what success looks like. Empty = not written.
    public var note: String
    public var createdAt: Date
    public var nodes: [GoalNode]
    public var edges: [WorkflowEdge]
    /// Last pan and zoom. nil = fit the cards when opened.
    public var viewport: WorkflowViewport?

    /// Milestone cards are larger than task cards, so they sit further apart.
    public static let columnGap: Double = 340
    public static let rowGap: Double = 160

    public init(
        id: UUID = UUID(),
        name: String,
        note: String = "",
        createdAt: Date = Date(),
        nodes: [GoalNode] = [],
        edges: [WorkflowEdge] = [],
        viewport: WorkflowViewport? = nil
    ) {
        self.id = id
        self.name = name
        self.note = note
        self.createdAt = createdAt
        self.nodes = nodes
        self.edges = edges
        self.viewport = viewport
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, note, createdAt, nodes, edges, viewport
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        nodes = try container.decodeIfPresent([GoalNode].self, forKey: .nodes) ?? []
        edges = try container.decodeIfPresent([WorkflowEdge].self, forKey: .edges) ?? []
        viewport = try container.decodeIfPresent(WorkflowViewport.self, forKey: .viewport)
    }

    /// Upstream milestones not reached yet. One that no longer exists does
    /// not block anything.
    public func blockers(of workflowID: UUID, workflows: [UUID: Workflow]) -> [UUID] {
        upstream(of: workflowID).filter { id in
            workflows[id].map { $0.achievedAt == nil } ?? false
        }
    }

    /// Reached and in all, over the milestones whose workflow still exists.
    public func progress(workflows: [UUID: Workflow]) -> (achieved: Int, total: Int) {
        let present = nodes.compactMap { workflows[$0.workflowID] }
        return (present.filter { $0.achievedAt != nil }.count, present.count)
    }

    public func summary(
        of workflowID: UUID,
        workflows: [UUID: Workflow],
        tasks: [UUID: TaskItem],
        subtasks: [UUID: [TaskItem]],
        now: Date,
        calendar: Calendar = .current
    ) -> MilestoneSummary? {
        guard contains(workflowID), let workflow = workflows[workflowID] else { return nil }
        let progress = workflow.progress(tasks: tasks)
        let involved = workflow.involvedTaskIDs(subtasks: subtasks).compactMap { tasks[$0] }
        let blockers = blockers(of: workflowID, workflows: workflows)
        let state: MilestoneState
        if workflow.achievedAt != nil {
            state = .achieved
        } else if progress.total > 0 && progress.done == progress.total {
            state = .review
        } else if involved.contains(where: { !$0.isPending }) {
            state = .active
        } else if !blockers.isEmpty {
            state = .blocked
        } else {
            state = .ready
        }
        return MilestoneSummary(
            state: state,
            done: progress.done,
            total: progress.total,
            invested: involved.reduce(0) { $0 + $1.duration(asOf: now) },
            running: involved.contains(where: \.isRunning),
            blockers: blockers,
            daysLeft: workflow.daysLeft(asOf: now, calendar: calendar)
        )
    }
}

extension Workflow {
    /// Tasks on the canvas and their subtasks, each once.
    public func involvedTaskIDs(subtasks: [UUID: [TaskItem]]) -> Set<UUID> {
        var ids = Set(nodes.map(\.taskID))
        for node in nodes {
            for child in subtasks[node.taskID] ?? [] { ids.insert(child.id) }
        }
        return ids
    }

    /// Whole days from today to the target date; negative once past it.
    public func daysLeft(asOf now: Date, calendar: Calendar = .current) -> Int? {
        guard let targetDate else { return nil }
        let today = calendar.startOfDay(for: now)
        let target = calendar.startOfDay(for: targetDate)
        return calendar.dateComponents([.day], from: today, to: target).day
    }
}
