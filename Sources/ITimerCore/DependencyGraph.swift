import Foundation

/// A card on a canvas, keyed by what it stands for (a task, a workflow).
public protocol GraphNode {
    var id: UUID { get }
    /// Center of the card, in canvas points. The canvas has no bounds.
    var x: Double { get set }
    var y: Double { get set }
}

/// Cards wired by "this one first" edges that never close a loop. A
/// workflow wires tasks; a goal wires its milestones the same way.
public protocol DependencyGraph {
    associatedtype Node: GraphNode
    var nodes: [Node] { get set }
    var edges: [WorkflowEdge] { get set }
}

extension DependencyGraph {
    public func contains(_ id: UUID) -> Bool {
        nodes.contains { $0.id == id }
    }

    public func node(_ id: UUID) -> Node? {
        nodes.first { $0.id == id }
    }

    /// Nodes that have to be done before `id`, in edge order.
    public func upstream(of id: UUID) -> [UUID] {
        edges.filter { $0.to == id }.map(\.from)
    }

    /// Nodes waiting on `id`, in edge order.
    public func downstream(of id: UUID) -> [UUID] {
        edges.filter { $0.from == id }.map(\.to)
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

    /// Drops nodes whose subject is gone, and every edge touching them.
    public func pruned(keeping ids: Set<UUID>) -> Self {
        var copy = self
        copy.nodes.removeAll { !ids.contains($0.id) }
        let kept = Set(copy.nodes.map(\.id))
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
        for node in nodes { incoming[node.id] = upstream(of: node.id).count }
        // Kahn's order; ties keep the canvas's top-to-bottom reading order.
        var queue = nodes.filter { incoming[$0.id] == 0 }
            .sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            .map(\.id)
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
        for node in nodes where !order.contains(node.id) { order.append(node.id) }

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

    /// Moves every node to its `arranged` spot.
    public mutating func applyArrangement(columnGap: Double = 280, rowGap: Double = 120) {
        let positions = arranged(columnGap: columnGap, rowGap: rowGap)
        for index in nodes.indices {
            guard let point = positions[nodes[index].id] else { continue }
            nodes[index].x = point.x
            nodes[index].y = point.y
        }
    }
}
