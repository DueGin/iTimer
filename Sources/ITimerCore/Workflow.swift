import Foundation

/// A task placed on a workflow canvas. The task itself lives in the store;
/// the node only says where it sits and how it reacts to its upstream.
public struct WorkflowNode: Codable, Equatable, Identifiable, Sendable, GraphNode {
    public var taskID: UUID
    /// Center of the card, in canvas points. The canvas has no bounds.
    public var x: Double
    public var y: Double
    /// Start timing by itself once every upstream task is done. Off, the
    /// node only lights up as ready and waits for the user.
    public var autoStart: Bool

    public var id: UUID { taskID }

    public init(taskID: UUID, x: Double, y: Double, autoStart: Bool = false) {
        self.taskID = taskID
        self.x = x
        self.y = y
        self.autoStart = autoStart
    }

    private enum CodingKeys: String, CodingKey {
        case taskID, x, y, autoStart
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try container.decode(UUID.self, forKey: .taskID)
        x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 0
        autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
    }
}

/// A dependency: `from` has to be done before `to` is ready.
public struct WorkflowEdge: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var from: UUID
    public var to: UUID

    public var id: String { "\(from.uuidString)>\(to.uuidString)" }

    public init(from: UUID, to: UUID) {
        self.from = from
        self.to = to
    }
}

/// Where a canvas was left: screen = canvas × scale + offset.
public struct WorkflowViewport: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var scale: Double

    public init(x: Double, y: Double, scale: Double) {
        self.x = x
        self.y = y
        self.scale = scale
    }
}

/// How far a workflow task has got, read from the task and its upstream.
public enum WorkflowNodeState: String, Equatable, Sendable {
    /// Never started, and some upstream task is not done yet.
    case blocked
    /// Not running, not done, and nothing upstream is in the way.
    case ready
    case running
    /// Started before, not running now, upstream all done.
    case paused
    case done

    public var title: String {
        switch self {
        case .blocked: "等待上游"
        case .ready: "可开始"
        case .running: "进行中"
        case .paused: "已暂停"
        case .done: "已完成"
        }
    }
}

/// What finishing one task did to the workflow it sits in.
public struct WorkflowAdvance: Equatable, Sendable {
    public var workflowID: UUID
    public var workflowName: String
    public var completedTaskID: UUID
    /// Downstream tasks that started timing on their own.
    public var started: [UUID]
    /// Downstream tasks that are now clear to start, waiting on the user.
    public var ready: [UUID]

    public var isEmpty: Bool { started.isEmpty && ready.isEmpty }
}

/// A named canvas of tasks wired by dependencies. A task sits on at most
/// one workflow; the edges never form a cycle.
public struct Workflow: Codable, Equatable, Identifiable, Sendable, DependencyGraph {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var nodes: [WorkflowNode]
    public var edges: [WorkflowEdge]
    /// Last pan and zoom. nil = fit the nodes when opened.
    public var viewport: WorkflowViewport?
    /// As a milestone on a goal: what "reached" means. Empty = not set.
    public var criteria: String
    /// As a milestone: the day it should be reached by (start of that day).
    public var targetDate: Date?
    /// As a milestone: marked reached by hand. Finishing every task does
    /// not set it — a milestone is an outcome, not a checklist.
    public var achievedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        nodes: [WorkflowNode] = [],
        edges: [WorkflowEdge] = [],
        viewport: WorkflowViewport? = nil,
        criteria: String = "",
        targetDate: Date? = nil,
        achievedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.nodes = nodes
        self.edges = edges
        self.viewport = viewport
        self.criteria = criteria
        self.targetDate = targetDate
        self.achievedAt = achievedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, nodes, edges, viewport, criteria, targetDate, achievedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        nodes = try container.decodeIfPresent([WorkflowNode].self, forKey: .nodes) ?? []
        edges = try container.decodeIfPresent([WorkflowEdge].self, forKey: .edges) ?? []
        viewport = try container.decodeIfPresent(WorkflowViewport.self, forKey: .viewport)
        criteria = try container.decodeIfPresent(String.self, forKey: .criteria) ?? ""
        targetDate = try container.decodeIfPresent(Date.self, forKey: .targetDate)
        achievedAt = try container.decodeIfPresent(Date.self, forKey: .achievedAt)
    }

    /// One line, short enough for a sidebar.
    public static func clean(_ name: String) -> String {
        let collapsed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(collapsed.prefix(30))
    }

    /// Upstream tasks still in the way. A task that no longer exists does
    /// not block anything.
    public func blockers(of taskID: UUID, tasks: [UUID: TaskItem]) -> [UUID] {
        upstream(of: taskID).filter { id in
            tasks[id].map { !$0.isCompleted } ?? false
        }
    }

    public func state(of taskID: UUID, tasks: [UUID: TaskItem]) -> WorkflowNodeState? {
        guard contains(taskID), let task = tasks[taskID] else { return nil }
        if task.isCompleted { return .done }
        if task.isRunning { return .running }
        if task.isPending && !blockers(of: taskID, tasks: tasks).isEmpty { return .blocked }
        return task.isPending ? .ready : .paused
    }

    /// Done and total, over the nodes whose task still exists.
    public func progress(tasks: [UUID: TaskItem]) -> (done: Int, total: Int) {
        let present = nodes.compactMap { tasks[$0.taskID] }
        return (present.filter(\.isCompleted).count, present.count)
    }
}
