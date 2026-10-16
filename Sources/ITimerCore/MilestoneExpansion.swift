import CoreGraphics
import Foundation

/// Where a milestone's tasks sit around its card on the roadmap while it
/// is expanded. Purely derived from the workflow's own canvas and edges:
/// expanding never rewrites task coordinates or dependencies, and the
/// layout is identical every time for the same workflow.
public struct MilestoneExpansionLayout: Equatable, Sendable {
    public struct Item: Equatable, Sendable, Identifiable {
        public var taskID: UUID
        /// Center of the task card on the roadmap canvas.
        public var position: CGPoint
        /// Column by dependency depth; a task without edges is a root and
        /// a leaf at once.
        public var depth: Int
        public var root: Bool
        public var leaf: Bool

        public var id: UUID { taskID }

        public init(taskID: UUID, position: CGPoint, depth: Int, root: Bool, leaf: Bool) {
            self.taskID = taskID
            self.position = position
            self.depth = depth
            self.root = root
            self.leaf = leaf
        }
    }

    public struct Link: Equatable, Sendable, Identifiable {
        public var from: UUID
        public var to: UUID

        public var id: String { "\(from.uuidString)>\(to.uuidString)" }

        public init(from: UUID, to: UUID) {
            self.from = from
            self.to = to
        }
    }

    /// Center of the milestone card the group hangs from.
    public var anchor: CGPoint
    public var items: [Item]
    /// The workflow's real edges, between tasks that are placed.
    public var links: [Link]
    /// The dashed frame around the milestone and all its tasks.
    public var frame: CGRect
    /// Entry dock on the frame's left side, exit dock on the right.
    public var inDock: CGPoint
    public var outDock: CGPoint

    public var roots: [Item] { items.filter(\.root) }
    public var leaves: [Item] { items.filter(\.leaf) }

    /// How far the inner cards sit from the milestone card and from each
    /// other. Wider than a workflow's own spacing so the dashed frame does
    /// not lean on the neighbor cards.
    public static let followGap: Double = 84
    public static let columnGap: Double = 300
    public static let rowGap: Double = 120
    /// Space between the inner cards and the dashed frame.
    public static let padding: Double = 36

    public init(anchor: CGPoint, items: [Item], links: [Link], frame: CGRect, inDock: CGPoint, outDock: CGPoint) {
        self.anchor = anchor
        self.items = items
        self.links = links
        self.frame = frame
        self.inDock = inDock
        self.outDock = outDock
    }

    /// Lays `workflow`'s tasks out right of the milestone card centered at
    /// `anchor`, in the same arrangement the canvas's tidy-up makes: one
    /// column per dependency depth, rows ordered by upstream barycenter,
    /// and a short column centered against the tallest one. Only display
    /// positions come from this — the workflow's own node coordinates are
    /// never touched. Tasks whose `TaskItem` is gone are filtered by
    /// `kept`; edges to them drop too.
    public init(
        workflow: Workflow,
        anchor: CGPoint,
        card: CGSize,
        innerCard: CGSize,
        kept: (UUID) -> Bool = { _ in true }
    ) {
        self.anchor = anchor

        let seats = Dictionary(
            workflow.nodes.filter { kept($0.taskID) }.map { ($0.taskID, CGPoint(x: $0.x, y: $0.y)) },
            uniquingKeysWith: { first, _ in first }
        )
        let ids = Set(seats.keys)
        let links = workflow.edges
            .filter { ids.contains($0.from) && ids.contains($0.to) }
            .map { Link(from: $0.from, to: $0.to) }

        var depth: [UUID: Int] = [:]
        for id in ids { depth[id] = 0 }
        // Longest path from a root, bounded by the node count so a cycle in
        // a hand-edited file cannot loop forever.
        for _ in 0..<max(ids.count, 1) {
            var settled = true
            for edge in links {
                let through = (depth[edge.from] ?? 0) + 1
                if through > (depth[edge.to] ?? 0) {
                    depth[edge.to] = through
                    settled = false
                }
            }
            if settled { break }
        }

        let upstream = Dictionary(grouping: links, by: \.to).mapValues { $0.map(\.from) }
        let downstream = Dictionary(grouping: links, by: \.from).mapValues { $0.map(\.to) }
        let startX = anchor.x + card.width / 2 + Self.followGap + innerCard.width / 2

        // Rows and column offsets come from the canvas's own tidy-up, so an
        // expanded milestone reads exactly like the workflow does after
        // "自动整理": one column per depth, rows ordered by upstream
        // barycenter, short columns centered against the tallest. Only the
        // seed positions of the visible tasks feed it; nothing is written
        // back, so the workflow keeps its saved coordinates.
        let listed = workflow.pruned(keeping: ids)
        let tidy = listed.arranged(
            columnGap: Double(Self.columnGap),
            rowGap: Double(Self.rowGap)
        )
        let originX = listed.nodes.map(\.x).min() ?? 0
        let originY = listed.nodes.map(\.y).min() ?? 0
        var positions: [UUID: CGPoint] = [:]
        for id in ids {
            guard let spot = tidy[id] else { continue }
            positions[id] = CGPoint(
                x: startX + spot.x - originX,
                // Row 0 stays level with the milestone card, so the group
                // keeps its place on the roadmap however tall it grows.
                y: anchor.y + spot.y - originY
            )
        }

        var items: [Item] = []
        items.reserveCapacity(positions.count)
        for (id, position) in positions {
            items.append(Item(
                taskID: id,
                position: position,
                depth: depth[id] ?? 0,
                root: (upstream[id] ?? []).isEmpty,
                leaf: (downstream[id] ?? []).isEmpty
            ))
        }
        self.items = items.sorted { lhs, rhs in
            lhs.depth == rhs.depth
                ? (lhs.position.y, lhs.position.x) < (rhs.position.y, rhs.position.x)
                : lhs.depth < rhs.depth
        }
        self.links = links
        let milestoneBounds = CGRect(x: anchor.x - card.width / 2, y: anchor.y - card.height / 2,
                                     width: card.width, height: card.height)

        guard let first = items.first else {
            // An empty workflow still gets a frame, so the empty state has
            // somewhere to sit.
            let emptyBounds = CGRect(x: anchor.x + card.width / 2 + Self.followGap, y: anchor.y - 60, width: 240, height: 120)
            frame = milestoneBounds.union(emptyBounds).insetBy(dx: -Self.padding, dy: -Self.padding)
            inDock = CGPoint(x: frame.minX, y: anchor.y)
            outDock = CGPoint(x: frame.maxX, y: anchor.y)
            return
        }
        var bounds = CGRect(
            x: first.position.x - innerCard.width / 2,
            y: first.position.y - innerCard.height / 2,
            width: innerCard.width,
            height: innerCard.height
        )
        for item in items.dropFirst() {
            bounds = bounds.union(CGRect(
                x: item.position.x - innerCard.width / 2,
                y: item.position.y - innerCard.height / 2,
                width: innerCard.width,
                height: innerCard.height
            ))
        }
        frame = bounds.union(milestoneBounds).insetBy(dx: -Self.padding, dy: -Self.padding)
        // Outside lines dock level with the milestone card, clamped onto
        // the frame so a tall stack still meets them on its side.
        let dockY = min(max(anchor.y, frame.minY), frame.maxY)
        inDock = CGPoint(x: frame.minX, y: dockY)
        outDock = CGPoint(x: frame.maxX, y: dockY)
    }

    /// The milestone card and its inner cards as one block, in roadmap
    /// canvas points. Fitting the window and checking for overlaps use
    /// this, so an expanded milestone is treated with its tasks, not as
    /// the bare card.
    public func footprint(card: CGSize, innerCard: CGSize) -> CGRect {
        let cardRect = CGRect(x: anchor.x - card.width / 2, y: anchor.y - card.height / 2, width: card.width, height: card.height)
        return cardRect.union(frame)
    }

    /// Display positions only: expanding reserves the full group, while
    /// folding restores the saved roadmap. Place predecessors first and
    /// carry their displacement forward, so downstream cards stay beyond
    /// the group's exit. Same-column neighbors move down instead of
    /// making a second, needlessly wide chain.
    public static func placements(
        in goal: Goal,
        workflows: [UUID: Workflow],
        card: CGSize,
        innerCard: CGSize,
        kept: (UUID) -> Bool = { _ in true }
    ) -> [UUID: CGPoint] {
        let nodes = goal.nodes.filter { workflows[$0.id] != nil }
        var result = Dictionary(nodes.map { ($0.id, CGPoint(x: $0.x, y: $0.y)) }, uniquingKeysWith: { first, _ in first })
        guard nodes.contains(where: \.expanded) else { return result }
        let ids = Set(nodes.map(\.id))
        let edges = goal.edges.filter { ids.contains($0.from) && ids.contains($0.to) }
        let parents = Dictionary(grouping: edges, by: \.to).mapValues { $0.map(\.from) }
        let saved = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func column(_ node: GoalNode) -> Double { (node.x / Goal.columnGap).rounded() }
        let ordered = nodes.sorted {
            (column($0), $0.y, $0.x, $0.id.uuidString) < (column($1), $1.y, $1.x, $1.id.uuidString)
        }
        var pending = ordered
        var blocks: [(node: GoalNode, rect: CGRect)] = []
        var placed = Set<UUID>()
        while !pending.isEmpty {
            // The fallback keeps hand-edited cyclic files finite.
            let index = pending.firstIndex { (parents[$0.id] ?? []).allSatisfy { placed.contains($0) } } ?? 0
            let node = pending.remove(at: index)
            let local: CGRect
            if node.expanded, let workflow = workflows[node.id] {
                local = Self(workflow: workflow, anchor: .zero, card: card, innerCard: innerCard, kept: kept)
                    .footprint(card: card, innerCard: innerCard)
            } else {
                local = CGRect(x: -card.width / 2, y: -card.height / 2, width: card.width, height: card.height)
            }
            let inherited = (parents[node.id] ?? []).compactMap { id -> CGFloat? in
                guard let original = saved[id], let shown = result[id], placed.contains(id) else { return nil }
                return max(0, shown.x - original.x)
            }.max() ?? 0
            var point = CGPoint(x: node.x + inherited, y: node.y)
            for parent in blocks where (parents[node.id] ?? []).contains(parent.node.id) {
                if parent.node.expanded || parent.rect.minX > parent.node.x - card.width / 2 + 1 {
                    point.x = max(point.x, parent.rect.maxX + 60 - local.minX)
                }
            }
            // Each pass clears at least one occupied block; monotonic
            // movement cannot reenter a block already cleared.
            while let collision = blocks.first(where: {
                $0.rect.insetBy(dx: -28, dy: -28).intersects(local.offsetBy(dx: point.x, dy: point.y))
            }) {
                if column(collision.node) == column(node), !(parents[node.id] ?? []).contains(collision.node.id) {
                    point.y = collision.rect.maxY + 28 - local.minY
                } else {
                    point.x = collision.rect.maxX + 28 - local.minX
                }
            }
            result[node.id] = point
            placed.insert(node.id)
            blocks.append((node, local.offsetBy(dx: point.x, dy: point.y)))
        }
        return result
    }
}
