import Foundation

/// A task placed on a workflow canvas. The task itself lives in the store;
/// the node only says where it sits and how it reacts to its upstream.
public struct WorkflowNode: Codable, Equatable, Identifiable, Sendable {
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
public struct Workflow: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var nodes: [WorkflowNode]
    public var edges: [WorkflowEdge]
    /// Last pan and zoom. nil = fit the nodes when opened.
    public var viewport: WorkflowViewport?

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        nodes: [WorkflowNode] = [],
        edges: [WorkflowEdge] = [],
        viewport: WorkflowViewport? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.nodes = nodes
        self.edges = edges
        self.viewport = viewport
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, nodes, edges, viewport
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        nodes = try container.decodeIfPresent([WorkflowNode].self, forKey: .nodes) ?? []
        edges = try container.decodeIfPresent([WorkflowEdge].self, forKey: .edges) ?? []
        viewport = try container.decodeIfPresent(WorkflowViewport.self, forKey: .viewport)
    }

    /// One line, short enough for a sidebar.
    public static func clean(_ name: String) -> String {
        let collapsed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(collapsed.prefix(30))
    }

    public func contains(_ taskID: UUID) -> Bool {
        nodes.contains { $0.taskID == taskID }
    }

    public func node(_ taskID: UUID) -> WorkflowNode? {
        nodes.first { $0.taskID == taskID }
    }

    /// Tasks that have to be done before `taskID`, in edge order.
    public func upstream(of taskID: UUID) -> [UUID] {
        edges.filter { $0.to == taskID }.map(\.from)
    }

    /// Tasks waiting on `taskID`, in edge order.
    public func downstream(of taskID: UUID) -> [UUID] {
        edges.filter { $0.from == taskID }.map(\.to)
    }

    /// Whether following edges from `start` ever arrives at `target`.
    public func reaches(from start: UUID, to target: UUID) -> Bool {
        var stack = [start]
        var seen: Set<UUID> = []
        while let current = stack.popLast() {
            if current == target { return true }
            guard seen.insert(current).inserted else { continue }
            stack.append(contentsOf: downstream(of: current))
        }
        return false
    }

    /// A new edge is fine between two different nodes on this canvas, once,
    /// and only if it does not close a loop.
    public func canConnect(from: UUID, to: UUID) -> Bool {
        guard from != to, contains(from), contains(to) else { return false }
        guard !edges.contains(WorkflowEdge(from: from, to: to)) else { return false }
        return !reaches(from: to, to: from)
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

    /// Drops nodes for tasks that are gone, and every edge touching them.
    public func pruned(keeping taskIDs: Set<UUID>) -> Workflow {
        var copy = self
        copy.nodes.removeAll { !taskIDs.contains($0.taskID) }
        let kept = Set(copy.nodes.map(\.taskID))
        copy.edges.removeAll { !kept.contains($0.from) || !kept.contains($0.to) }
        return copy
    }

    /// Column per dependency depth (longest path from a start), rows in
    /// each column ordered by where their upstream sits so lines cross
    /// less. Anchored at the current top-left so the canvas does not jump.
    public func arranged(columnGap: Double = 280, rowGap: Double = 120) -> [UUID: (x: Double, y: Double)] {
        guard !nodes.isEmpty else { return [:] }
        var depth: [UUID: Int] = [:]
        var incoming: [UUID: Int] = [:]
        for node in nodes { incoming[node.taskID] = upstream(of: node.taskID).count }
        // Kahn's order; ties keep the canvas's top-to-bottom reading order.
        var queue = nodes.filter { incoming[$0.taskID] == 0 }
            .sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            .map(\.taskID)
        var order: [UUID] = []
        while !queue.isEmpty {
            let current = queue.removeFirst()
            order.append(current)
            for next in downstream(of: current) {
                depth[next] = max(depth[next] ?? 0, (depth[current] ?? 0) + 1)
                incoming[next, default: 0] -= 1
                if incoming[next] == 0 { queue.append(next) }
            }
        }
        // A cycle cannot be saved through the store, but a hand-edited file
        // could hold one; leftovers go in the first column.
        for node in nodes where !order.contains(node.taskID) { order.append(node.taskID) }

        var columns: [[UUID]] = []
        for id in order {
            let column = depth[id] ?? 0
            while columns.count <= column { columns.append([]) }
            columns[column].append(id)
        }
        var row: [UUID: Double] = [:]
        for (index, column) in columns.enumerated() {
            let sorted: [UUID]
            if index == 0 {
                sorted = column
            } else {
                // Barycenter of the upstream rows already placed.
                sorted = column.enumerated().sorted { lhs, rhs in
                    let a = barycenter(lhs.element, rows: row) ?? Double(lhs.offset)
                    let b = barycenter(rhs.element, rows: row) ?? Double(rhs.offset)
                    return a == b ? lhs.offset < rhs.offset : a < b
                }.map(\.element)
            }
            for (position, id) in sorted.enumerated() { row[id] = Double(position) }
        }

        let tallest = Double(columns.map(\.count).max() ?? 1)
        let originX = nodes.map(\.x).min() ?? 0
        let originY = nodes.map(\.y).min() ?? 0
        var result: [UUID: (x: Double, y: Double)] = [:]
        for (index, column) in columns.enumerated() {
            // Short columns sit centered against the tallest one.
            let lift = (tallest - Double(column.count)) / 2
            for id in column {
                result[id] = (originX + Double(index) * columnGap, originY + ((row[id] ?? 0) + lift) * rowGap)
            }
        }
        return result
    }

    private func barycenter(_ id: UUID, rows: [UUID: Double]) -> Double? {
        let placed = upstream(of: id).compactMap { rows[$0] }
        guard !placed.isEmpty else { return nil }
        return placed.reduce(0, +) / Double(placed.count)
    }

    /// Where a node added without a spot should go: right of the rightmost
    /// card, level with it; the origin on an empty canvas.
    public func nextSlot(columnGap: Double = 280) -> (x: Double, y: Double) {
        guard let rightmost = nodes.max(by: { $0.x < $1.x }) else { return (0, 0) }
        return (rightmost.x + columnGap, rightmost.y)
    }
}
