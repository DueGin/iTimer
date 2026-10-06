import XCTest
@testable import ITimerCore

final class WorkflowTests: XCTestCase {
    private var directory: URL!
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itimer-workflow-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    @MainActor
    private func makeStore() -> TaskStore {
        TaskStore(url: directory.appendingPathComponent("state.json"), now: t0)
    }

    /// A workflow with one undated step per title, left to right.
    @MainActor
    private func makeFlow(_ store: TaskStore, _ titles: [String]) throws -> (Workflow, [UUID]) {
        let flow = try XCTUnwrap(store.addWorkflow("发版"))
        var ids: [UUID] = []
        for (index, title) in titles.enumerated() {
            let step = try XCTUnwrap(store.addWorkflowStep(title: title, in: flow.id, x: Double(index) * 280, y: 0, at: t0))
            ids.append(step.id)
        }
        return (try XCTUnwrap(store.workflow(id: flow.id)), ids)
    }

    @MainActor
    func testConnectRefusesLoopsRepeatsAndStrangers() throws {
        let store = makeStore()
        let (flow, ids) = try makeFlow(store, ["写代码", "测试", "发布"])
        let outsider = try XCTUnwrap(store.addTask(title: "回消息", at: t0))
        XCTAssertTrue(store.connect(from: ids[0], to: ids[1], in: flow.id))
        XCTAssertTrue(store.connect(from: ids[1], to: ids[2], in: flow.id))
        XCTAssertFalse(store.connect(from: ids[0], to: ids[1], in: flow.id), "no repeats")
        XCTAssertFalse(store.connect(from: ids[2], to: ids[0], in: flow.id), "no loops, even long ones")
        XCTAssertFalse(store.connect(from: ids[1], to: ids[1], in: flow.id), "no self-edges")
        XCTAssertFalse(store.connect(from: outsider.id, to: ids[0], in: flow.id), "both ends must be on the canvas")
        XCTAssertEqual(store.workflow(id: flow.id)?.edges.count, 2)

        XCTAssertTrue(store.disconnect(from: ids[1], to: ids[2], in: flow.id))
        XCTAssertFalse(store.disconnect(from: ids[1], to: ids[2], in: flow.id))
        XCTAssertTrue(store.connect(from: ids[2], to: ids[0], in: flow.id), "the loop is gone once the edge is")
    }

    @MainActor
    func testStateWaitsForEveryUpstream() throws {
        let store = makeStore()
        let (flow, ids) = try makeFlow(store, ["设计", "文案", "上线"])
        store.connect(from: ids[0], to: ids[2], in: flow.id)
        store.connect(from: ids[1], to: ids[2], in: flow.id)

        XCTAssertEqual(store.workflowState(of: ids[0]), .ready)
        XCTAssertEqual(store.workflowState(of: ids[2]), .blocked)
        XCTAssertEqual(store.workflowBlockers(of: ids[2]).map(\.id), [ids[0], ids[1]])

        store.resume(id: ids[0], at: t0.addingTimeInterval(60))
        XCTAssertEqual(store.workflowState(of: ids[0]), .running)
        store.complete(id: ids[0], at: t0.addingTimeInterval(120))
        XCTAssertEqual(store.workflowState(of: ids[0]), .done)
        XCTAssertEqual(store.workflowState(of: ids[2]), .blocked, "still waiting on 文案")

        store.complete(id: ids[1], at: t0.addingTimeInterval(180))
        XCTAssertEqual(store.workflowState(of: ids[2]), .ready)
        XCTAssertTrue(store.workflowBlockers(of: ids[2]).isEmpty)

        let progress = try XCTUnwrap(store.workflow(id: flow.id)).progress(tasks: store.tasksByID)
        XCTAssertEqual(progress.done, 2)
        XCTAssertEqual(progress.total, 3)

        // Starting early is allowed; a blocked task that was started then
        // paused reads as paused, not blocked.
        let early = try XCTUnwrap(store.addWorkflowStep(title: "复盘", in: flow.id, x: 840, y: 0, after: ids[2], at: t0))
        store.resume(id: early.id, at: t0.addingTimeInterval(200))
        store.pause(id: early.id, at: t0.addingTimeInterval(260))
        XCTAssertEqual(store.workflowState(of: early.id), .paused)
    }

    @MainActor
    func testFinishingUpstreamStartsOnlyOptedInSteps() throws {
        let store = makeStore()
        let (flow, ids) = try makeFlow(store, ["写代码", "自动跑测试", "人工验收", "发布"])
        store.connect(from: ids[0], to: ids[1], in: flow.id)
        store.connect(from: ids[0], to: ids[2], in: flow.id)
        store.connect(from: ids[1], to: ids[3], in: flow.id)
        store.connect(from: ids[2], to: ids[3], in: flow.id)
        XCTAssertTrue(store.setAutoStart(taskID: ids[1], in: flow.id, true))
        XCTAssertTrue(store.setAutoStart(taskID: ids[3], in: flow.id, true))
        XCTAssertEqual(store.workflowState(of: ids[1]), .blocked, "opting in does not start a blocked step")

        var advances: [WorkflowAdvance] = []
        store.onWorkflowAdvance = { advances.append($0) }

        store.resume(id: ids[0], at: t0)
        store.complete(id: ids[0], at: t0.addingTimeInterval(600))
        XCTAssertEqual(advances.count, 1)
        XCTAssertEqual(advances.last?.started, [ids[1]])
        XCTAssertEqual(advances.last?.ready, [ids[2]])
        XCTAssertEqual(advances.last?.workflowName, "发版")
        XCTAssertEqual(store.workflowState(of: ids[1]), .running)
        XCTAssertEqual(store.tasks.first { $0.id == ids[1] }?.segments.first?.startedAt, t0.addingTimeInterval(600))
        XCTAssertEqual(store.workflowState(of: ids[2]), .ready, "manual steps wait for the user")

        store.complete(id: ids[1], at: t0.addingTimeInterval(900))
        XCTAssertEqual(advances.count, 1, "发布 still waits on 人工验收: nothing to report")
        XCTAssertEqual(store.workflowState(of: ids[3]), .blocked)

        store.complete(id: ids[2], at: t0.addingTimeInterval(1200))
        XCTAssertEqual(advances.last?.started, [ids[3]])
        XCTAssertEqual(store.workflowState(of: ids[3]), .running)

        // Tasks off any workflow complete without a report.
        let loose = try XCTUnwrap(store.addTask(title: "回消息", at: t0))
        store.complete(id: loose.id, at: t0.addingTimeInterval(1300))
        XCTAssertEqual(advances.count, 2)
    }

    @MainActor
    func testATaskSitsOnOneWorkflowAtATime() throws {
        let store = makeStore()
        let (first, ids) = try makeFlow(store, ["写代码", "测试"])
        store.connect(from: ids[0], to: ids[1], in: first.id)
        let second = try XCTUnwrap(store.addWorkflow("发版"))
        XCTAssertEqual(second.name, "发版 2", "names stay distinct")

        XCTAssertTrue(store.place(taskID: ids[1], in: second.id))
        XCTAssertEqual(store.workflow(containing: ids[1])?.id, second.id)
        XCTAssertEqual(store.workflow(id: first.id)?.nodes.map(\.taskID), [ids[0]])
        XCTAssertEqual(store.workflow(id: first.id)?.edges, [], "edges into the moved task go with it")
        XCTAssertEqual(store.workflow(id: second.id)?.node(ids[1])?.x, 0, "an empty canvas starts at the origin")

        XCTAssertTrue(store.place(taskID: ids[0], in: second.id))
        XCTAssertEqual(store.workflow(id: second.id)?.node(ids[0])?.x, 280, "next slot is right of the rightmost card")

        XCTAssertTrue(store.place(taskID: ids[0], in: second.id, x: 50, y: 60))
        XCTAssertEqual(store.workflow(id: second.id)?.nodes.count, 2, "placing again only moves")
        XCTAssertEqual(store.workflow(id: second.id)?.node(ids[0])?.y, 60)
        XCTAssertFalse(store.place(taskID: UUID(), in: second.id))
    }

    @MainActor
    func testRemovingKeepsTasksAndDeletingPrunes() throws {
        let store = makeStore()
        let (flow, ids) = try makeFlow(store, ["一", "二", "三"])
        store.connect(from: ids[0], to: ids[1], in: flow.id)
        store.connect(from: ids[1], to: ids[2], in: flow.id)

        XCTAssertTrue(store.removeNode(taskID: ids[2], from: flow.id))
        XCTAssertTrue(store.tasks.contains { $0.id == ids[2] }, "taking a task off the canvas keeps it")
        XCTAssertEqual(store.workflow(id: flow.id)?.edges, [WorkflowEdge(from: ids[0], to: ids[1])])

        XCTAssertTrue(store.delete(id: ids[1]))
        XCTAssertEqual(store.workflow(id: flow.id)?.nodes.map(\.taskID), [ids[0]])
        XCTAssertEqual(store.workflow(id: flow.id)?.edges, [])

        store.removeWorkflow(id: flow.id)
        XCTAssertNil(store.workflow(id: flow.id))
        XCTAssertTrue(store.tasks.contains { $0.id == ids[0] }, "removing a workflow keeps its tasks")
    }

    @MainActor
    func testWorkflowsSurviveReloadAndOldFilesStillOpen() throws {
        let store = makeStore()
        let (flow, ids) = try makeFlow(store, ["写代码", "测试"])
        store.connect(from: ids[0], to: ids[1], in: flow.id)
        store.setAutoStart(taskID: ids[1], in: flow.id, true)
        store.setViewport(id: flow.id, WorkflowViewport(x: 12, y: -40, scale: 0.75))
        XCTAssertTrue(store.renameWorkflow(id: flow.id, to: "  每周   发版  "))

        let reloaded = TaskStore(url: store.url, now: t0)
        let saved = try XCTUnwrap(reloaded.workflow(id: flow.id))
        XCTAssertEqual(saved.name, "每周 发版")
        XCTAssertEqual(saved.edges, [WorkflowEdge(from: ids[0], to: ids[1])])
        XCTAssertEqual(saved.node(ids[1])?.autoStart, true)
        XCTAssertEqual(saved.node(ids[1])?.x, 280)
        XCTAssertEqual(saved.viewport, WorkflowViewport(x: 12, y: -40, scale: 0.75))

        // A 1.5 file has no workflows key at all.
        let legacy = """
        {"brainSplitThreshold":3,"calendarSyncEnabled":false,"collections":[],"tasks":[],"version":2}
        """
        let url = directory.appendingPathComponent("legacy.json")
        try legacy.write(to: url, atomically: true, encoding: .utf8)
        let old = TaskStore(url: url, now: t0)
        XCTAssertNil(old.lastError)
        XCTAssertEqual(old.workflows, [])
    }

    @MainActor
    func testStepAfterUpstreamIsWiredAndFiledAlongside() throws {
        let store = makeStore()
        let collection = try XCTUnwrap(store.addCollection("副业"))
        let flow = try XCTUnwrap(store.addWorkflow("上架"))
        let first = try XCTUnwrap(store.addSchedule(title: "截图", collectionID: collection.id, start: nil, plannedDuration: nil, reminderLead: nil, at: t0))
        XCTAssertTrue(store.place(taskID: first.id, in: flow.id, x: 0, y: 0))
        let next = try XCTUnwrap(store.addWorkflowStep(title: "提交审核 #上架", in: flow.id, x: 280, y: 0, after: first.id, at: t0))
        XCTAssertTrue(next.isUndated, "a new step waits to be started")
        XCTAssertEqual(next.tags, ["上架"])
        XCTAssertEqual(next.collectionID, collection.id)
        XCTAssertEqual(store.workflow(id: flow.id)?.upstream(of: next.id), [first.id])
        XCTAssertNil(store.addWorkflowStep(title: "  ", in: flow.id, x: 0, y: 0))
        XCTAssertNil(store.addWorkflowStep(title: "无处安放", in: UUID(), x: 0, y: 0))
    }

    func testArrangeColumnsByDepthAndKeepsTheOrigin() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let flow = Workflow(
            name: "排版",
            nodes: [
                WorkflowNode(taskID: d, x: 900, y: 500),
                WorkflowNode(taskID: c, x: 100, y: 400),
                WorkflowNode(taskID: b, x: 400, y: 300),
                WorkflowNode(taskID: a, x: 100, y: 200),
            ],
            edges: [
                WorkflowEdge(from: a, to: b),
                WorkflowEdge(from: b, to: d),
                WorkflowEdge(from: c, to: d),
            ]
        )
        let layout = flow.arranged(columnGap: 300, rowGap: 100)
        XCTAssertEqual(layout[a]?.x, 100, "sources in the first column, at the old left edge")
        XCTAssertEqual(layout[c]?.x, 100)
        XCTAssertEqual(layout[b]?.x, 400)
        XCTAssertEqual(layout[d]?.x, 700, "depth is the longest path, not the shortest")
        XCTAssertEqual(layout[a]?.y, 200, "reading order kept: a was above c")
        XCTAssertEqual(layout[c]?.y, 300)
        XCTAssertEqual(layout[b]?.y, 250, "a lone card sits centered against the tallest column")
    }
}
