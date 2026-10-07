import XCTest
@testable import ITimerCore

final class GoalTests: XCTestCase {
    private var directory: URL!
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itimer-goal-tests-\(UUID().uuidString)", isDirectory: true)
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

    /// A goal with one empty milestone per title, left to right.
    @MainActor
    private func makeRoadmap(_ store: TaskStore, _ titles: [String]) throws -> (Goal, [UUID]) {
        let goal = try XCTUnwrap(store.addGoal("上线"))
        var ids: [UUID] = []
        for (index, title) in titles.enumerated() {
            let milestone = try XCTUnwrap(store.addMilestone(title: title, in: goal.id, x: Double(index) * Goal.columnGap, y: 0, at: t0))
            ids.append(milestone.id)
        }
        return (try XCTUnwrap(store.goal(id: goal.id)), ids)
    }

    @MainActor
    func testConnectMilestonesRefusesLoopsRepeatsAndStrangers() throws {
        let store = makeStore()
        let (goal, ids) = try makeRoadmap(store, ["原型", "内测", "发布"])
        let outsider = try XCTUnwrap(store.addWorkflow("杂事"))
        XCTAssertTrue(store.connectMilestones(from: ids[0], to: ids[1], in: goal.id))
        XCTAssertTrue(store.connectMilestones(from: ids[1], to: ids[2], in: goal.id))
        XCTAssertFalse(store.connectMilestones(from: ids[0], to: ids[1], in: goal.id), "no repeats")
        XCTAssertFalse(store.connectMilestones(from: ids[2], to: ids[0], in: goal.id), "no loops")
        XCTAssertFalse(store.connectMilestones(from: ids[1], to: ids[1], in: goal.id), "no self-edges")
        XCTAssertFalse(store.connectMilestones(from: outsider.id, to: ids[0], in: goal.id), "both ends on the roadmap")

        XCTAssertTrue(store.disconnectMilestones(from: ids[1], to: ids[2], in: goal.id))
        XCTAssertFalse(store.disconnectMilestones(from: ids[1], to: ids[2], in: goal.id))
        XCTAssertTrue(store.connectMilestones(from: ids[2], to: ids[0], in: goal.id), "the loop is gone once the edge is")
    }

    @MainActor
    func testAWorkflowSitsOnOneGoalAtATime() throws {
        let store = makeStore()
        let (first, ids) = try makeRoadmap(store, ["原型", "内测"])
        store.connectMilestones(from: ids[0], to: ids[1], in: first.id)
        let second = try XCTUnwrap(store.addGoal("上线"))
        XCTAssertEqual(second.name, "上线 2", "names get a number instead of failing")

        XCTAssertTrue(store.placeMilestone(workflowID: ids[1], in: second.id, x: 0, y: 0))
        XCTAssertEqual(store.goal(containing: ids[1])?.id, second.id)
        XCTAssertFalse(try XCTUnwrap(store.goal(id: first.id)).contains(ids[1]))
        XCTAssertTrue(try XCTUnwrap(store.goal(id: first.id)).edges.isEmpty, "its lines go with it")

        XCTAssertTrue(store.placeMilestone(workflowID: ids[1], in: second.id, x: 120, y: 48))
        let node = try XCTUnwrap(store.goal(id: second.id)?.node(ids[1]))
        XCTAssertEqual(node.x, 120)
        XCTAssertEqual(node.y, 48)
        XCTAssertEqual(store.goal(id: second.id)?.nodes.count, 1, "placing again only moves it")
        XCTAssertFalse(store.placeMilestone(workflowID: UUID(), in: second.id))
    }

    @MainActor
    func testRemovingWorkflowPrunesGoalAndRemovingGoalKeepsWorkflows() throws {
        let store = makeStore()
        let (goal, ids) = try makeRoadmap(store, ["原型", "内测", "发布"])
        store.connectMilestones(from: ids[0], to: ids[1], in: goal.id)
        store.connectMilestones(from: ids[1], to: ids[2], in: goal.id)
        let step = try XCTUnwrap(store.addWorkflowStep(title: "画线框", in: ids[0], x: 0, y: 0, at: t0))

        store.removeWorkflow(id: ids[1])
        let pruned = try XCTUnwrap(store.goal(id: goal.id))
        XCTAssertEqual(Set(pruned.nodes.map(\.workflowID)), [ids[0], ids[2]])
        XCTAssertTrue(pruned.edges.isEmpty)

        XCTAssertTrue(store.standaloneWorkflows.isEmpty)
        store.removeGoal(id: goal.id)
        XCTAssertNil(store.goal(id: goal.id))
        XCTAssertEqual(Set(store.standaloneWorkflows.map(\.id)), [ids[0], ids[2]], "milestones stay as workflows")
        XCTAssertNotNil(store.tasks.first { $0.id == step.id }, "and their tasks stay too")
    }

    @MainActor
    func testMilestoneStates() throws {
        let store = makeStore()
        let (goal, ids) = try makeRoadmap(store, ["原型", "内测", "空的"])
        store.connectMilestones(from: ids[0], to: ids[1], in: goal.id)
        let sketch = try XCTUnwrap(store.addWorkflowStep(title: "画线框", in: ids[0], x: 0, y: 0, at: t0))
        let invite = try XCTUnwrap(store.addWorkflowStep(title: "邀请用户", in: ids[1], x: 0, y: 0, at: t0))
        let survey = try XCTUnwrap(store.addWorkflowStep(title: "发问卷", in: ids[1], x: 280, y: 0, at: t0))

        XCTAssertEqual(store.milestoneSummary(of: ids[0])?.state, .ready)
        XCTAssertEqual(store.milestoneSummary(of: ids[1])?.state, .blocked)
        XCTAssertEqual(store.milestoneSummary(of: ids[1])?.blockers, [ids[0]])
        XCTAssertEqual(store.milestoneSummary(of: ids[2])?.state, .ready, "an empty milestone is never up for review")

        store.resume(id: invite.id, at: t0)
        XCTAssertEqual(store.milestoneSummary(of: ids[1])?.state, .active, "starting ahead of the upstream is allowed")

        store.complete(id: invite.id, at: t0.addingTimeInterval(60))
        store.complete(id: survey.id, at: t0.addingTimeInterval(60))
        XCTAssertEqual(store.milestoneSummary(of: ids[1])?.state, .review, "done tasks do not reach a milestone")

        store.complete(id: sketch.id, at: t0.addingTimeInterval(60))
        XCTAssertEqual(store.milestoneSummary(of: ids[0])?.state, .review, "finished without timing still counts")
        XCTAssertTrue(store.setMilestoneAchieved(workflowID: ids[0], true, at: t0))
        XCTAssertEqual(store.milestoneSummary(of: ids[0])?.state, .achieved)
        XCTAssertEqual(store.workflow(id: ids[0])?.achievedAt, t0)
        XCTAssertEqual(store.milestoneSummary(of: ids[1])?.blockers, [])
        XCTAssertEqual(store.goal(id: goal.id)?.progress(workflows: store.workflowsByID).achieved, 1)

        XCTAssertTrue(store.setMilestoneAchieved(workflowID: ids[0], false))
        XCTAssertEqual(store.milestoneSummary(of: ids[0])?.state, .review)
        XCTAssertNil(store.milestoneSummary(of: UUID()))
    }

    @MainActor
    func testInvestedTimeCountsSubtasksOnce() throws {
        let store = makeStore()
        let (_, ids) = try makeRoadmap(store, ["原型"])
        let parent = try XCTUnwrap(store.addWorkflowStep(title: "做页面", in: ids[0], x: 0, y: 0, at: t0))
        store.resume(id: parent.id, at: t0)
        store.pause(id: parent.id, at: t0.addingTimeInterval(600))
        let child = try XCTUnwrap(store.addSubtask(parentID: parent.id, title: "配色", at: t0.addingTimeInterval(600)))
        store.pause(id: child.id, at: t0.addingTimeInterval(900))
        XCTAssertEqual(try XCTUnwrap(store.milestoneSummary(of: ids[0])).invested, 900, accuracy: 0.001)

        // The subtask is also a card on the same canvas: still counted once.
        XCTAssertTrue(store.place(taskID: child.id, in: ids[0], x: 280, y: 0))
        let summary = try XCTUnwrap(store.milestoneSummary(of: ids[0]))
        XCTAssertEqual(summary.invested, 900, accuracy: 0.001)
        XCTAssertEqual(summary.total, 2)
        XCTAssertFalse(summary.running)

        store.resume(id: child.id, at: t0.addingTimeInterval(900))
        let goal = try XCTUnwrap(store.goal(containing: ids[0]))
        let running = try XCTUnwrap(goal.summary(
            of: ids[0],
            workflows: store.workflowsByID,
            tasks: store.tasksByID,
            subtasks: store.subtasksByParent,
            now: t0.addingTimeInterval(960)
        ))
        XCTAssertTrue(running.running)
        XCTAssertEqual(running.invested, 960, accuracy: 0.001, "a running task counts up to now")
    }

    @MainActor
    func testTargetDateDaysLeft() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let store = makeStore()
        let (_, ids) = try makeRoadmap(store, ["原型"])
        // t0 is 2023-11-15 06:13 in Shanghai.
        let in3Days = t0.addingTimeInterval(3 * 86400 + 12 * 3600)
        XCTAssertTrue(store.setMilestoneTargetDate(workflowID: ids[0], in3Days, calendar: calendar))
        XCTAssertEqual(store.workflow(id: ids[0])?.targetDate, calendar.startOfDay(for: in3Days), "kept as the start of the day")
        XCTAssertEqual(store.workflow(id: ids[0])?.daysLeft(asOf: t0, calendar: calendar), 3)
        XCTAssertEqual(store.workflow(id: ids[0])?.daysLeft(asOf: t0.addingTimeInterval(3 * 86400), calendar: calendar), 0)
        XCTAssertEqual(store.workflow(id: ids[0])?.daysLeft(asOf: t0.addingTimeInterval(5 * 86400), calendar: calendar), -2)

        XCTAssertTrue(store.setMilestoneTargetDate(workflowID: ids[0], nil))
        XCTAssertNil(store.workflow(id: ids[0])?.targetDate)
        XCTAssertNil(store.milestoneSummary(of: ids[0])?.daysLeft)
        XCTAssertFalse(store.setMilestoneTargetDate(workflowID: UUID(), t0))
    }

    @MainActor
    func testAddMilestoneCreatesWiredWorkflow() throws {
        let store = makeStore()
        let (goal, ids) = try makeRoadmap(store, ["原型"])
        let next = try XCTUnwrap(store.addMilestone(title: "原型", in: goal.id, x: 340, y: 0, after: ids[0], at: t0))
        XCTAssertEqual(next.name, "原型 2", "a new workflow, so the name gets a number")
        XCTAssertEqual(store.goal(id: goal.id)?.upstream(of: next.id), [ids[0]])
        XCTAssertEqual(store.goal(id: goal.id)?.node(next.id)?.x, 340)
        XCTAssertEqual(store.milestones(in: goal.id).map(\.id), [ids[0], next.id], "read left to right")
        XCTAssertNil(store.addMilestone(title: "  ", in: goal.id, x: 0, y: 0))
        XCTAssertNil(store.addMilestone(title: "无处安放", in: UUID(), x: 0, y: 0))
        XCTAssertEqual(store.workflows.count, 2, "a refused milestone leaves no workflow behind")
    }

    @MainActor
    func testCriteriaAndNoteAreCleaned() throws {
        let store = makeStore()
        let (goal, ids) = try makeRoadmap(store, ["内测"])
        XCTAssertTrue(store.setMilestoneCriteria(workflowID: ids[0], "  10 个付费用户\n\n\n续费过一次  "))
        XCTAssertEqual(store.workflow(id: ids[0])?.criteria, "10 个付费用户\n\n续费过一次")
        XCTAssertTrue(store.setGoalNote(id: goal.id, " 先养活自己 "))
        XCTAssertEqual(store.goal(id: goal.id)?.note, "先养活自己")
        XCTAssertTrue(store.renameGoal(id: goal.id, to: "  独立 开发 "))
        XCTAssertEqual(store.goal(id: goal.id)?.name, "独立 开发")
        XCTAssertFalse(store.renameGoal(id: goal.id, to: "   "))
    }

    @MainActor
    func testGoalsSurviveReloadAndPruneOnLoad() throws {
        let store = makeStore()
        let (goal, ids) = try makeRoadmap(store, ["原型", "内测"])
        store.connectMilestones(from: ids[0], to: ids[1], in: goal.id)
        store.setGoalNote(id: goal.id, "先养活自己")
        store.setGoalViewport(id: goal.id, WorkflowViewport(x: 10, y: 20, scale: 0.8))
        store.setMilestoneCriteria(workflowID: ids[1], "10 个付费用户")
        store.setMilestoneTargetDate(workflowID: ids[1], t0)
        store.setMilestoneAchieved(workflowID: ids[0], true, at: t0)

        let reloaded = TaskStore(url: store.url, now: t0)
        let saved = try XCTUnwrap(reloaded.goal(id: goal.id))
        XCTAssertEqual(saved.note, "先养活自己")
        XCTAssertEqual(saved.viewport, WorkflowViewport(x: 10, y: 20, scale: 0.8))
        XCTAssertEqual(saved.edges, [WorkflowEdge(from: ids[0], to: ids[1])])
        XCTAssertEqual(reloaded.workflow(id: ids[1])?.criteria, "10 个付费用户")
        XCTAssertEqual(reloaded.workflow(id: ids[1])?.targetDate, Calendar.current.startOfDay(for: t0))
        XCTAssertEqual(reloaded.workflow(id: ids[0])?.achievedAt, t0)

        // Hand-edited: a card for a workflow that is gone, and one workflow
        // on two goals. The first goal keeps it.
        let gone = UUID().uuidString
        let shared = UUID().uuidString
        let file = """
        {"brainSplitThreshold":3,"tasks":[],"version":3,
         "workflows":[{"id":"\(shared)","name":"共享","createdAt":"2023-11-14T22:13:20Z","nodes":[],"edges":[]}],
         "goals":[
          {"id":"\(UUID().uuidString)","name":"甲","createdAt":"2023-11-14T22:13:20Z",
           "nodes":[{"workflowID":"\(shared)","x":0,"y":0},{"workflowID":"\(gone)","x":340,"y":0}],
           "edges":[{"from":"\(shared)","to":"\(gone)"}]},
          {"id":"\(UUID().uuidString)","name":"乙","createdAt":"2023-11-14T22:13:20Z",
           "nodes":[{"workflowID":"\(shared)","x":0,"y":0}],"edges":[]}]}
        """
        let url = directory.appendingPathComponent("hand.json")
        try file.write(to: url, atomically: true, encoding: .utf8)
        let hand = TaskStore(url: url, now: t0)
        XCTAssertNil(hand.lastError)
        XCTAssertEqual(hand.goals.map { $0.nodes.count }, [1, 0])
        XCTAssertTrue(hand.goals[0].edges.isEmpty)
        XCTAssertEqual(hand.goal(containing: try XCTUnwrap(UUID(uuidString: shared)))?.name, "甲")

        // A 1.6 file: no goals, workflows without milestone fields.
        let legacy = """
        {"brainSplitThreshold":3,"calendarSyncEnabled":false,"tasks":[],"version":2,
         "workflows":[{"id":"\(UUID().uuidString)","name":"发版","createdAt":"2023-11-14T22:13:20Z","nodes":[],"edges":[]}]}
        """
        let legacyURL = directory.appendingPathComponent("legacy.json")
        try legacy.write(to: legacyURL, atomically: true, encoding: .utf8)
        let old = TaskStore(url: legacyURL, now: t0)
        XCTAssertNil(old.lastError)
        XCTAssertEqual(old.goals, [])
        XCTAssertEqual(old.workflows.first?.criteria, "")
        XCTAssertNil(old.workflows.first?.achievedAt)
    }

    @MainActor
    func testArrangeGoalColumnsByDepth() throws {
        let store = makeStore()
        let (goal, ids) = try makeRoadmap(store, ["原型", "内测", "官网", "发布"])
        store.connectMilestones(from: ids[0], to: ids[1], in: goal.id)
        store.connectMilestones(from: ids[0], to: ids[2], in: goal.id)
        store.connectMilestones(from: ids[1], to: ids[3], in: goal.id)
        store.connectMilestones(from: ids[2], to: ids[3], in: goal.id)
        store.moveMilestone(workflowID: ids[3], in: goal.id, x: 50, y: 900)
        store.arrangeGoal(id: goal.id)
        let arranged = try XCTUnwrap(store.goal(id: goal.id))
        let x = { (id: UUID) in arranged.node(id)?.x ?? .nan }
        XCTAssertEqual(x(ids[0]), 0)
        XCTAssertEqual(x(ids[1]), Goal.columnGap)
        XCTAssertEqual(x(ids[2]), Goal.columnGap)
        XCTAssertEqual(x(ids[3]), 2 * Goal.columnGap)
        XCTAssertEqual(abs((arranged.node(ids[1])?.y ?? 0) - (arranged.node(ids[2])?.y ?? 0)), Goal.rowGap)
    }
}
