import AppKit
import ITimerCore
import SwiftUI

/// A goal's roadmap: cards are milestones (each a workflow), lines are
/// "reach this first". Double-clicking a card opens its workflow.
struct GoalCanvasView: View {
    var store: TaskStore
    var goalID: UUID
    /// Shows a milestone's workflow canvas.
    var open: (UUID) -> Void
    @State private var editingNote = false

    var body: some View {
        if let goal = store.goal(id: goalID) {
            let workflows = store.workflowsByID
            let summaries = store.milestoneSummaries(in: goalID)
            GraphCanvas(
                model: GoalCanvasModel(store: store, goalID: goalID),
                layout: .goal,
                wording: .goal
            ) { node, context in
                if let workflow = workflows[node.id], let summary = summaries[node.id] {
                    MilestoneCard(
                        workflow: workflow,
                        summary: summary,
                        goalID: goalID,
                        store: store,
                        selected: context.selected,
                        linkHighlight: context.linkHighlight,
                        onSelect: context.select,
                        onAddNext: context.addNext,
                        onOpen: { open(node.id) }
                    )
                }
            } header: {
                header(goal, summaries: summaries)
            } summary: {
                summary(goal, summaries: summaries, workflows: workflows)
            } picker: { pick in
                GoalWorkflowPicker(store: store, goalID: goalID, onPick: pick)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editingNote = true
                    } label: {
                        Label("目标说明", systemImage: "text.alignleft")
                    }
                    .help("改名，写下为什么做、怎样算成功")
                    .popover(isPresented: $editingNote, arrowEdge: .bottom) {
                        GoalNoteEditor(goal: goal, store: store)
                    }
                    .accessibilityIdentifier("goal-edit-note")
                }
            }
        } else {
            ContentUnavailableView("目标已删除", systemImage: "flag.checkered")
        }
    }

    /// The goal's name and why it matters, since the window title belongs
    /// to the list column.
    private func header(_ goal: Goal, summaries: [UUID: MilestoneSummary]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: "flag.checkered")
                    .foregroundStyle(Theme.focused)
                Text(goal.name)
                    .font(.headline)
                    .lineLimit(1)
                if summaries.values.contains(where: \.running) {
                    PulseDot(color: Theme.focused, active: true, size: 6)
                }
            }
            Text(goal.note.isEmpty ? "点工具栏「目标说明」，写下为什么做、怎样算成功" : goal.note)
                .font(.caption)
                .foregroundStyle(goal.note.isEmpty ? .tertiary : .secondary)
                .lineLimit(2)
                .frame(maxWidth: 360, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("goal-title")
    }

    private func summary(_ goal: Goal, summaries: [UUID: MilestoneSummary], workflows: [UUID: Workflow]) -> some View {
        let states = summaries.values.map(\.state)
        let progress = goal.progress(workflows: workflows)
        return HStack(spacing: 12) {
            CanvasLegend(color: .orange, title: "可开始", count: states.filter { $0 == .ready }.count)
            CanvasLegend(color: Theme.focused, title: "推进中", count: states.filter { $0 == .active }.count)
            CanvasLegend(color: .orange, title: "待确认", count: states.filter { $0 == .review }.count)
            CanvasLegend(color: .secondary, title: "等待上游", count: states.filter { $0 == .blocked }.count)
            Text("达成 \(progress.achieved)/\(progress.total)")
                .font(.caption.weight(.semibold).monospacedDigit())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("goal-summary")
    }
}

/// A goal as seen by the graph canvas: its milestones and their order.
@MainActor
struct GoalCanvasModel: GraphCanvasModel {
    var store: TaskStore
    var goalID: UUID

    private var goal: Goal? { store.goal(id: goalID) }

    var nodes: [CanvasNode] {
        let workflows = store.workflowsByID
        return (goal?.nodes ?? [])
            .filter { workflows[$0.workflowID] != nil }
            .map { CanvasNode(id: $0.workflowID, x: $0.x, y: $0.y) }
    }

    var links: [CanvasLink] {
        let workflows = store.workflowsByID
        return (goal?.edges ?? []).map { CanvasLink(edge: $0, met: workflows[$0.from]?.achievedAt != nil) }
    }

    var viewport: WorkflowViewport? { goal?.viewport }
    /// The task list drags tasks; milestones come from the picker instead.
    var acceptsDrops: Bool { false }

    func canConnect(from: UUID, to: UUID) -> Bool {
        goal?.canConnect(from: from, to: to) ?? false
    }

    func connect(from: UUID, to: UUID) -> Bool {
        store.connectMilestones(from: from, to: to, in: goalID)
    }

    func disconnect(_ edge: WorkflowEdge) {
        store.disconnectMilestones(from: edge.from, to: edge.to, in: goalID)
    }

    func move(_ id: UUID, x: Double, y: Double) {
        store.moveMilestone(workflowID: id, in: goalID, x: x, y: y)
    }

    func place(_ id: UUID, x: Double, y: Double) -> Bool {
        store.placeMilestone(workflowID: id, in: goalID, x: x, y: y)
    }

    func remove(_ id: UUID) {
        store.removeMilestone(workflowID: id, from: goalID)
    }

    func create(title: String, x: Double, y: Double, after: UUID?) -> UUID? {
        store.addMilestone(title: title, in: goalID, x: x, y: y, after: after)?.id
    }

    func arrange() {
        store.arrangeGoal(id: goalID)
    }

    func saveViewport(_ viewport: WorkflowViewport) {
        store.setGoalViewport(id: goalID, viewport)
    }
}

extension CanvasWording {
    static let goal = CanvasWording(
        id: "goal",
        newItem: "新里程碑",
        newItemHelp: "新建一个里程碑；选中卡片时接在它后面（也可以双击画布）",
        newHere: "在这里新建里程碑",
        addExisting: "添加已有工作流",
        addExistingHelp: "把已有的工作流放到路线图上，当作一个里程碑",
        firstPrompt: "新里程碑，回车添加",
        nextPrompt: "下一个里程碑，回车添加，Esc 结束",
        portHelp: "拖到另一张卡片：先达成它才轮到下一个；点击：添加下一个里程碑",
        portLabel: "添加下一个里程碑",
        arrangeHelp: "按先后顺序排成几列",
        emptyIcon: "flag.checkered",
        emptyTitle: "空白路线图",
        emptyText: "双击任意位置新建一个里程碑，或添加已有的工作流。\n从卡片右侧的圆点拖到另一张卡片，表示先达成它才轮到下一个。",
        firstItem: "新建第一个里程碑"
    )
}

/// Popover list of workflows to put on the roadmap. One on another goal
/// says so; picking it moves it here.
struct GoalWorkflowPicker: View {
    var store: TaskStore
    var goalID: UUID
    var onPick: (UUID) -> Void
    @State private var query = ""

    var body: some View {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tasks = store.tasksByID
        let candidates = store.workflows
            .filter { store.goal(containing: $0.id)?.id != goalID }
            .filter { needle.isEmpty || $0.name.lowercased().contains(needle) }
        VStack(alignment: .leading, spacing: 8) {
            TextField("搜索工作流", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("goal-picker-search")
            if candidates.isEmpty {
                Text(needle.isEmpty ? "没有可以放上来的工作流。" : "没有匹配的工作流。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(candidates) { workflow in
                            row(workflow, tasks: tasks)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    private func row(_ workflow: Workflow, tasks: [UUID: TaskItem]) -> some View {
        let progress = workflow.progress(tasks: tasks)
        return Button {
            onPick(workflow.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(workflow.name)
                        .lineLimit(1)
                    if let other = store.goal(containing: workflow.id) {
                        Text("在目标「\(other.name)」中，会移过来")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
                Text("\(progress.done)/\(progress.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(shape: .rounded, hover: 0.08))
        .accessibilityIdentifier("goal-pick-\(workflow.id.uuidString)")
    }
}

/// Name and "why" for a goal. Saves after a pause in typing, and on close.
struct GoalNoteEditor: View {
    var goal: Goal
    var store: TaskStore
    @State private var name: String
    @State private var note: String

    init(goal: Goal, store: TaskStore) {
        self.goal = goal
        self.store = store
        _name = State(initialValue: goal.name)
        _note = State(initialValue: goal.note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("目标名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.headline)
                .onSubmit(commitName)
                .accessibilityIdentifier("goal-name-field")
            VStack(alignment: .leading, spacing: 4) {
                Text("为什么做 · 怎样算成功")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $note)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 90, maxHeight: 160)
                    .padding(6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityIdentifier("goal-note-field")
            }
        }
        .padding(14)
        .frame(width: 340)
        .task(id: note) {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            store.setGoalNote(id: goal.id, note)
        }
        .onDisappear {
            commitName()
            store.setGoalNote(id: goal.id, note)
        }
    }

    private func commitName() {
        if !store.renameGoal(id: goal.id, to: name) { name = store.goal(id: goal.id)?.name ?? goal.name }
    }
}
