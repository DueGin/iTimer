import XCTest
@testable import ITimerCore

final class MilestoneExpansionTests: XCTestCase {
    private let card = CGSize(width: 260, height: 116)
    private let taskCard = CGSize(width: 220, height: 84)

    @MainActor
    func testExpansionPersistsAndLegacyRoadmapsStartCollapsed() throws {
        let id = UUID()
        let legacy = Data("{\"workflowID\":\"\(id.uuidString)\",\"x\":12,\"y\":24}".utf8)
        XCTAssertFalse(try JSONDecoder().decode(GoalNode.self, from: legacy).expanded)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("itimer-expansion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let store = TaskStore(url: url, now: at)
        let goal = try XCTUnwrap(store.addGoal("发版", at: at))
        let flow = try XCTUnwrap(store.addMilestone(title: "验收", in: goal.id, x: 12, y: 24, at: at))
        _ = store.addWorkflowStep(title: "回归", in: flow.id, x: 400, y: -200, at: at)
        let savedWorkflow = store.workflow(id: flow.id)
        XCTAssertTrue(store.setMilestoneExpanded(workflowID: flow.id, in: goal.id, true))
        let reopened = TaskStore(url: url)
        XCTAssertTrue(try XCTUnwrap(reopened.goal(id: goal.id)?.nodes.first).expanded)
        XCTAssertEqual(reopened.workflow(id: flow.id), savedWorkflow)
        XCTAssertTrue(reopened.setMilestoneExpanded(workflowID: flow.id, in: goal.id, false))
        XCTAssertFalse(try XCTUnwrap(reopened.goal(id: goal.id)?.nodes.first).expanded)
    }

    func testBranchesAndIndependentTasksHaveDistinctSeatsAndCorrectDocks() {
        let ids = (0..<6).map { _ in UUID() }
        let workflow = Workflow(
            name: "交付",
            nodes: ids.map { WorkflowNode(taskID: $0, x: 0, y: 0) },
            edges: [
                WorkflowEdge(from: ids[0], to: ids[2]),
                WorkflowEdge(from: ids[1], to: ids[2]),
                WorkflowEdge(from: ids[2], to: ids[3]),
                WorkflowEdge(from: ids[2], to: ids[4]),
            ]
        )
        let original = workflow
        let layout = MilestoneExpansionLayout(workflow: workflow, anchor: .zero, card: card, innerCard: taskCard)

        XCTAssertEqual(Set(layout.roots.map(\.id)), Set([ids[0], ids[1], ids[5]]))
        XCTAssertEqual(Set(layout.leaves.map(\.id)), Set([ids[3], ids[4], ids[5]]))
        XCTAssertEqual(Set(layout.links.map(\.id)), Set(workflow.edges.map(\.id)))
        let rects = layout.items.map { item in
            CGRect(x: item.position.x - taskCard.width / 2, y: item.position.y - taskCard.height / 2, width: taskCard.width, height: taskCard.height)
        }
        for (index, rect) in rects.enumerated() {
            XCTAssertTrue(layout.frame.contains(rect), "every task is inside the virtual frame")
            for other in rects.dropFirst(index + 1) {
                XCTAssertFalse(rect.intersects(other), "collocated saved nodes must still be readable when expanded")
            }
        }
        XCTAssertEqual(layout.inDock.x, layout.frame.minX)
        XCTAssertEqual(layout.outDock.x, layout.frame.maxX)
        XCTAssertTrue(layout.frame.contains(CGRect(x: -card.width / 2, y: -card.height / 2, width: card.width, height: card.height)),
                      "the milestone and its tasks must visibly belong to the same group")
        XCTAssertTrue((layout.frame.minY...layout.frame.maxY).contains(layout.inDock.y))
        XCTAssertTrue((layout.frame.minY...layout.frame.maxY).contains(layout.outDock.y))
        XCTAssertEqual(workflow, original, "deriving the expansion must not modify saved workflow data")
    }

    func testMovingAnchorMovesWholeExpansionWithoutChangingItsShape() {
        let ids = [UUID(), UUID()]
        let workflow = Workflow(name: "准备", nodes: ids.map { WorkflowNode(taskID: $0, x: -400, y: -200) })
        let first = MilestoneExpansionLayout(workflow: workflow, anchor: .zero, card: card, innerCard: taskCard)
        let moved = MilestoneExpansionLayout(workflow: workflow, anchor: CGPoint(x: -123, y: 276), card: card, innerCard: taskCard)
        XCTAssertEqual(first.frame.size, moved.frame.size)
        for item in first.items {
            let other = moved.items.first { $0.id == item.id }!
            XCTAssertEqual(other.position.x - item.position.x, -123, accuracy: 0.001)
            XCTAssertEqual(other.position.y - item.position.y, 276, accuracy: 0.001)
        }
        XCTAssertEqual(moved.frame.origin.x - first.frame.origin.x, -123, accuracy: 0.001)
        XCTAssertEqual(moved.frame.origin.y - first.frame.origin.y, 276, accuracy: 0.001)
    }

    func testEmptyAndFilteredWorkflowsKeepAnEmptyFrameAndNoDanglingLinks() {
        let kept = UUID(), removed = UUID()
        let workflow = Workflow(
            name: "准备",
            nodes: [WorkflowNode(taskID: kept, x: 0, y: 0), WorkflowNode(taskID: removed, x: 280, y: 0)],
            edges: [WorkflowEdge(from: kept, to: removed)]
        )
        let filtered = MilestoneExpansionLayout(workflow: workflow, anchor: .zero, card: card, innerCard: taskCard, kept: { $0 == kept })
        XCTAssertEqual(filtered.items.map(\.id), [kept])
        XCTAssertTrue(filtered.links.isEmpty)
        XCTAssertEqual(filtered.roots.map(\.id), [kept])
        XCTAssertEqual(filtered.leaves.map(\.id), [kept])

        let empty = MilestoneExpansionLayout(workflow: Workflow(name: "空工作流"), anchor: .zero, card: card, innerCard: taskCard)
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertTrue(empty.links.isEmpty)
        XCTAssertGreaterThan(empty.frame.width, 0)
        XCTAssertGreaterThan(empty.frame.height, 0)
        XCTAssertTrue(empty.footprint(card: card, innerCard: taskCard).contains(empty.frame))
    }

    func testExpandedRoadmapAvoidsNeighborsAndMultipleWideGroupsWithoutSavingPositions() {
        let flows = (0..<12).map { index in
            let tasks = (0..<5).map { _ in UUID() }
            return Workflow(name: "里程碑 \(index)",
                            nodes: tasks.map { WorkflowNode(taskID: $0, x: 0, y: 0) },
                            edges: zip(tasks, tasks.dropFirst()).map { WorkflowEdge(from: $0, to: $1) })
        }
        let workflows = Dictionary(uniqueKeysWithValues: flows.map { ($0.id, $0) })
        let nodes = flows.enumerated().map { index, flow in
            GoalNode(workflowID: flow.id, x: Double(index / 2) * 340, y: Double(index % 2) * 160, expanded: index % 3 == 0)
        }
        let edges = stride(from: 0, to: flows.count - 2, by: 2).map { WorkflowEdge(from: flows[$0].id, to: flows[$0 + 2].id) }
        var goal = Goal(name: "长路线图", nodes: nodes, edges: edges)
        let original = goal
        let at = MilestoneExpansionLayout.placements(in: goal, workflows: workflows, card: card, innerCard: taskCard)
        let blocks = nodes.map { node -> CGRect in
            let center = at[node.id]!
            if node.expanded {
                return MilestoneExpansionLayout(workflow: workflows[node.id]!, anchor: center, card: card, innerCard: taskCard)
                    .footprint(card: card, innerCard: taskCard)
            }
            return CGRect(x: center.x - card.width / 2, y: center.y - card.height / 2, width: card.width, height: card.height)
        }
        for (index, block) in blocks.enumerated() {
            for other in blocks.dropFirst(index + 1) { XCTAssertFalse(block.intersects(other)) }
        }
        XCTAssertGreaterThan(at[flows[1].id]!.y, nodes[1].y, "same-column neighbors make room below")
        XCTAssertGreaterThan(at[flows[2].id]!.x, blocks[0].maxX, "the next milestone stays beyond the whole group")
        XCTAssertEqual(goal, original)
        goal.nodes = nodes.map { var node = $0; node.expanded = false; return node }
        let folded = MilestoneExpansionLayout.placements(in: goal, workflows: workflows, card: card, innerCard: taskCard)
        for node in nodes { XCTAssertEqual(folded[node.id], CGPoint(x: node.x, y: node.y)) }
    }
}
