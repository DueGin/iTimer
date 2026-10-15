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
            let model = GoalCanvasModel(store: store, goalID: goalID)
            GraphCanvas(
                model: model,
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
                        onOpen: { open(node.id) },
                        expanded: model.isExpanded(node.id),
                        onToggleExpanded: { model.setExpanded(node.id, !model.isExpanded(node.id)) }
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
/// Expanded milestones show their workflow's tasks in a dashed frame next
/// to the card; the layout is derived, never stored, so expanding never
/// touches the real dependencies or task coordinates.
@MainActor
struct GoalCanvasModel: GraphCanvasModel {
    var store: TaskStore
    var goalID: UUID
    private var goal: Goal? { store.goal(id: goalID) }

    private var placements: [UUID: CGPoint] {
        guard let goal else { return [:] }
        return MilestoneExpansionLayout.placements(
            in: goal, workflows: store.workflowsByID,
            card: CanvasLayout.goal.card, innerCard: Self.innerCard,
            kept: { store.tasksByID[$0] != nil }
        )
    }

    var nodes: [CanvasNode] {
        let workflows = store.workflowsByID
        let at = placements
        return (goal?.nodes ?? [])
            .filter { workflows[$0.workflowID] != nil }
            .map { CanvasNode(id: $0.workflowID, x: Double(at[$0.workflowID]?.x ?? CGFloat($0.x)), y: Double(at[$0.workflowID]?.y ?? CGFloat($0.y))) }
    }

    var links: [CanvasLink] {
        let workflows = store.workflowsByID
        return (goal?.edges ?? []).map { CanvasLink(edge: $0, met: workflows[$0.from]?.achievedAt != nil) }
    }

    var viewport: WorkflowViewport? { goal?.viewport }
    /// The task list drags tasks; milestones come from the picker instead.
    var acceptsDrops: Bool { false }

    func isExpanded(_ id: UUID) -> Bool {
        goal?.node(id)?.expanded ?? false
    }

    func setExpanded(_ id: UUID, _ expanded: Bool) {
        store.setMilestoneExpanded(workflowID: id, in: goalID, expanded)
    }

    private static let innerCard = CanvasMetrics.card

    /// The derived layout of an expanded milestone at `anchor`, shifted
    /// mid-drag.
    private func expansion(of id: UUID, anchor: CGPoint, moved: [UUID: CGSize]) -> MilestoneExpansionLayout? {
        guard goal?.node(id)?.expanded == true,
              let workflow = store.workflow(id: id) else { return nil }
        let layout = MilestoneExpansionLayout(
            workflow: workflow,
            anchor: anchor,
            card: CanvasLayout.goal.card,
            innerCard: Self.innerCard,
            kept: { store.tasksByID[$0] != nil }
        )
        guard let shift = moved[id], shift != .zero else { return layout }
        return MilestoneExpansionLayout(
            anchor: CGPoint(x: layout.anchor.x + shift.width, y: layout.anchor.y + shift.height),
            items: layout.items.map {
                MilestoneExpansionLayout.Item(
                    taskID: $0.taskID,
                    position: CGPoint(x: $0.position.x + shift.width, y: $0.position.y + shift.height),
                    depth: $0.depth,
                    root: $0.root,
                    leaf: $0.leaf
                )
            },
            links: layout.links,
            frame: layout.frame.offsetBy(dx: shift.width, dy: shift.height),
            inDock: CGPoint(x: layout.inDock.x + shift.width, y: layout.inDock.y + shift.height),
            outDock: CGPoint(x: layout.outDock.x + shift.width, y: layout.outDock.y + shift.height)
        )
    }

    func overlay(moved: [UUID: CGSize], transform: CanvasTransform, clearSelection: @escaping () -> Void) -> some View {
        let at = placements
        let expansions = nodes.compactMap { node -> (UUID, MilestoneExpansionLayout)? in
            let anchor = at[node.id] ?? CGPoint(x: node.x, y: node.y)
            return expansion(of: node.id, anchor: anchor, moved: moved).map { (node.id, $0) }
        }
        return ForEach(expansions, id: \.0) { id, layout in
            MilestoneExpansionView(store: store, workflowID: id, layout: layout, transform: transform, clearSelection: clearSelection)
        }
    }

    func decorations(moved: [UUID: CGSize]) -> [CanvasDecoration] {
        let at = placements
        return nodes.compactMap { node in
            let anchor = at[node.id] ?? CGPoint(x: node.x, y: node.y)
            return expansion(of: node.id, anchor: anchor, moved: moved).map {
                CanvasDecoration(owner: node.id, rect: $0.frame, inDock: $0.inDock, outDock: $0.outDock)
            }
        }
    }

    func footprint(of id: UUID, card: CGSize) -> CGRect {
        guard let spot = placements[id] else { return .zero }
        let cardRect = CGRect(x: spot.x - card.width / 2, y: spot.y - card.height / 2, width: card.width, height: card.height)
        guard let layout = expansion(of: id, anchor: spot, moved: [:]) else { return cardRect }
        return cardRect.union(layout.frame)
    }

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
        guard let shown = placements[id], let saved = goal?.node(id) else { return }
        store.moveMilestone(workflowID: id, in: goalID,
                            x: saved.x + x - shown.x, y: saved.y + y - shown.y)
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

/// An expanded milestone on the roadmap: the workflow's real tasks in a
/// dashed frame right of the card, wired by the workflow's own edges, plus
/// the bridges that hand external lines to the inner roots and from the
/// inner leaves. The cards are the same WorkflowCard the workflow canvas
/// shows, so starting or pausing a task works right here; only dragging
/// and rewiring stay on the workflow's own canvas.
struct MilestoneExpansionView: View {
    var store: TaskStore
    var workflowID: UUID
    var layout: MilestoneExpansionLayout
    /// Canvas-to-screen, so the group pans and zooms with the cards.
    var transform: CanvasTransform
    var clearSelection: () -> Void

    private var workflow: Workflow? { store.workflow(id: workflowID) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            bridges
            innerEdges
            ForEach(layout.items) { item in
                if let task = store.tasksByID[item.taskID], let node = workflow?.node(item.taskID) {
                    WorkflowCard(
                        task: task,
                        node: node,
                        state: workflow?.state(of: item.taskID, tasks: store.tasksByID) ?? .ready,
                        blockers: workflow?.blockers(of: item.taskID, tasks: store.tasksByID).count ?? 0,
                        store: store,
                        workflowID: workflowID,
                        selected: false,
                        linkHighlight: nil,
                        onSelect: clearSelection,
                        onAddNext: nil
                    )
                    .simultaneousGesture(TapGesture().onEnded { clearSelection() })
                    .scaleEffect(transform.scale)
                    .position(transform.screen(item.position))
                }
            }
            if layout.items.isEmpty {
                emptyState
            }
            groupHeader
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("milestone-group-\(workflowID.uuidString)")
    }

    /// The lines that make the group part of the roadmap: the entry dock
    /// to every root task, and every leaf task to the exit dock. A task
    /// without edges is both, so it meets the outside on either side.
    private var bridges: some View {
        let milestoneDone = workflow?.achievedAt != nil
        let entry = CGPoint(x: layout.anchor.x + CanvasLayout.goal.card.width / 2 + MilestoneExpansionLayout.followGap - MilestoneExpansionLayout.padding,
                            y: layout.anchor.y)
        var geometry = [EdgeGeometry(
            id: "bridge-entry-\(workflowID.uuidString)",
            start: transform.screen(layout.inDock),
            end: transform.screen(CGPoint(x: layout.anchor.x - CanvasLayout.goal.card.width / 2, y: layout.anchor.y)),
            scale: transform.scale,
            style: milestoneDone ? .met : .waiting
        )]
        geometry.append(EdgeGeometry(
            id: "bridge-card-\(workflowID.uuidString)",
            start: transform.screen(CGPoint(x: layout.anchor.x + CanvasLayout.goal.card.width / 2, y: layout.anchor.y)),
            end: transform.screen(entry), scale: transform.scale,
            style: milestoneDone ? .met : .waiting
        ))
        if layout.items.isEmpty {
            geometry.append(EdgeGeometry(
                id: "bridge-empty-\(workflowID.uuidString)", start: transform.screen(entry),
                end: transform.screen(layout.outDock), scale: transform.scale, style: .waiting,
                via: [CGPoint(x: entry.x + 14, y: entry.y),
                      CGPoint(x: entry.x + 14, y: layout.frame.maxY - 14),
                      CGPoint(x: layout.outDock.x - 14, y: layout.frame.maxY - 14),
                      CGPoint(x: layout.outDock.x - 14, y: layout.outDock.y)].map(transform.screen)
            ))
        }
        for item in layout.items where item.root {
            geometry.append(EdgeGeometry(
                id: "bridge-in-\(workflowID.uuidString)-\(item.taskID.uuidString)",
                edge: nil,
                start: transform.screen(entry),
                end: transform.screen(CGPoint(x: item.position.x - CanvasMetrics.card.width / 2, y: item.position.y)),
                scale: transform.scale,
                style: milestoneDone ? .met : .waiting
            ))
        }
        for item in layout.items where item.leaf {
            // A leaf in an earlier column (including an independent
            // task) exits along the lower gutter, clear of later cards.
            let early = item.depth < (layout.items.map(\.depth).max() ?? 0)
            let rail = item.position.x + CanvasMetrics.card.width / 2 + 20
            let bottom = layout.frame.maxY - 14
            let exit = layout.outDock.x - 14
            let bends = early ? [
                CGPoint(x: rail, y: item.position.y), CGPoint(x: rail, y: bottom),
                CGPoint(x: exit, y: bottom), CGPoint(x: exit, y: layout.outDock.y)
            ].map(transform.screen) : []
            geometry.append(EdgeGeometry(
                id: "bridge-out-\(workflowID.uuidString)-\(item.taskID.uuidString)",
                edge: nil,
                start: transform.screen(CGPoint(x: item.position.x + CanvasMetrics.card.width / 2, y: item.position.y)),
                end: transform.screen(layout.outDock),
                scale: transform.scale,
                style: store.tasksByID[item.taskID]?.isCompleted == true ? .met : .waiting,
                via: bends
            ))
        }
        return EdgeLayer(edges: geometry)
            .allowsHitTesting(false)
    }

    /// The workflow's real edges, leaving a card's right side and arriving
    /// at the next card's left side, as on the workflow canvas.
    private var innerEdges: some View {
        let byID = Dictionary(layout.items.map { ($0.taskID, $0) }, uniquingKeysWith: { first, _ in first })
        let tasks = store.tasksByID
        let geometry: [EdgeGeometry] = (workflow?.edges ?? []).compactMap { edge in
            guard let from = byID[edge.from], let to = byID[edge.to] else { return nil }
            let skip = to.depth > from.depth + 1
            let startRail = from.position.x + CanvasMetrics.card.width / 2 + 20
            let endRail = to.position.x - CanvasMetrics.card.width / 2 - 20
            let bends = skip ? [
                CGPoint(x: startRail, y: from.position.y), CGPoint(x: startRail, y: layout.frame.maxY - 14),
                CGPoint(x: endRail, y: layout.frame.maxY - 14), CGPoint(x: endRail, y: to.position.y)
            ].map(transform.screen) : []
            return EdgeGeometry(
                id: "inner-\(workflowID.uuidString)-\(edge.id)",
                edge: nil,
                start: transform.screen(CGPoint(x: from.position.x + CanvasMetrics.card.width / 2, y: from.position.y)),
                end: transform.screen(CGPoint(x: to.position.x - CanvasMetrics.card.width / 2, y: to.position.y)),
                scale: transform.scale,
                style: tasks[edge.from]?.isCompleted == true ? .met : .waiting,
                via: bends
            )
        }
        return EdgeLayer(edges: geometry)
            .allowsHitTesting(false)
    }

    /// An empty workflow still expands: the frame says there is nothing
    /// inside yet, and points at the real canvas.
    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "tray")
                .font(.system(size: 16))
                .foregroundStyle(.tertiary)
            Text("这个里程碑还没有任务")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("双击里程碑卡片进入工作流添加")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(width: 240, height: 120)
        .scaleEffect(transform.scale)
        .position(transform.screen(CGPoint(x: layout.anchor.x + CanvasLayout.goal.card.width / 2 + MilestoneExpansionLayout.followGap + 120, y: layout.anchor.y)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("milestone-group-empty-\(workflowID.uuidString)")
    }

    private var groupHeader: some View {
        let textScale = max(0.65, transform.scale)
        return HStack(spacing: 8) {
            Image(systemName: "flag")
                .font(.system(size: 11 / textScale, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(workflow?.name ?? "里程碑")
                .font(.system(size: 12 / textScale, weight: .semibold))
                .lineLimit(1)
                .help(workflow?.name ?? "里程碑")
                .accessibilityIdentifier("milestone-group-title-\(workflowID.uuidString)")
            Text("\(layout.items.count) 项任务")
                .font(.system(size: 10 / textScale))
                .foregroundStyle(.secondary)
            Spacer()
            IconButton(title: "收起里程碑", systemImage: "rectangle.compress.vertical", identifier: "milestone-collapse-\(workflowID.uuidString)") {
                if let goal = store.goal(containing: workflowID) {
                    store.setMilestoneExpanded(workflowID: workflowID, in: goal.id, false)
                }
            }
        }
        .frame(width: layout.frame.width - 24, height: 24)
        .scaleEffect(transform.scale)
        .position(transform.screen(CGPoint(x: layout.frame.midX, y: layout.frame.minY + 16)))
    }
}
