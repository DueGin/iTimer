import ITimerCore
import SwiftUI

/// What the main window's right-hand side shows.
enum MainDestination: Hashable {
    case tasks
    case analysis
    /// The 目标 module with no goal picked (there is none yet).
    case goals
    /// The 工作流 module with no workflow picked.
    case workflows
    case workflow(UUID)
    case goal(UUID)

    /// Stored form for @AppStorage: "tasks", "analysis", "goals",
    /// "workflows", "workflow:<uuid>" or "goal:<uuid>".
    var raw: String {
        switch self {
        case .tasks: "tasks"
        case .analysis: "analysis"
        case .goals: "goals"
        case .workflows: "workflows"
        case .workflow(let id): "workflow:\(id.uuidString)"
        case .goal(let id): "goal:\(id.uuidString)"
        }
    }

    init(raw: String) {
        if raw.hasPrefix("workflow:"), let id = UUID(uuidString: String(raw.dropFirst("workflow:".count))) {
            self = .workflow(id)
        } else if raw.hasPrefix("goal:"), let id = UUID(uuidString: String(raw.dropFirst("goal:".count))) {
            self = .goal(id)
        } else {
            switch raw {
            case "analysis": self = .analysis
            case "goals": self = .goals
            case "workflows": self = .workflows
            default: self = .tasks
            }
        }
    }

    /// The rail entry this belongs to. A milestone's workflow is part of
    /// its goal, so it stays under 目标.
    @MainActor
    func module(in store: TaskStore) -> MainModule {
        switch self {
        case .tasks: .tasks
        case .analysis: .analysis
        case .goals, .goal: .goals
        case .workflows: .workflows
        case .workflow(let id): store.goal(containing: id) == nil ? .workflows : .goals
        }
    }

    /// What is left to show once the item it points at has been deleted.
    @MainActor
    func resolved(in store: TaskStore) -> MainDestination {
        switch self {
        case .goal(let id) where store.goal(id: id) == nil: .goals
        case .workflow(let id) where store.workflow(id: id) == nil: .workflows
        default: self
        }
    }
}

/// The main window's rail entries, top to bottom.
enum MainModule: String, CaseIterable {
    case tasks
    case goals
    case workflows
    case analysis

    var title: String {
        switch self {
        case .tasks: "任务"
        case .goals: "目标"
        case .workflows: "工作流"
        case .analysis: "分析"
        }
    }

    var systemImage: String {
        switch self {
        case .tasks: "checklist"
        case .goals: "flag.checkered"
        case .workflows: "point.3.connected.trianglepath.dotted"
        case .analysis: "chart.xyaxis.line"
        }
    }

    /// ⌘1 to ⌘4.
    var shortcut: KeyEquivalent {
        KeyEquivalent(Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1)))
    }

    /// Modules with a list panel next to the rail.
    var hasList: Bool { self == .goals || self == .workflows }
}

/// The list panel next to the rail: every goal with its milestones under
/// it (目标), or the workflows that are not on any goal (工作流).
struct MainSidebar: View {
    var store: TaskStore
    var module: MainModule
    @Binding var selection: MainDestination?
    @AppStorage("listPanelCollapsed") private var listCollapsed = false
    /// Goals whose milestones are folded away, as comma-joined ids.
    @AppStorage("collapsedGoals") private var collapsedGoalsRaw = ""
    @State private var renaming: MainRouter.Rename?
    @State private var nameDraft = ""
    /// Workflow waiting for the delete confirmation.
    @State private var doomed: Workflow?
    /// Goal waiting for the delete confirmation.
    @State private var doomedGoal: Goal?
    @FocusState private var nameFocused: Bool
    /// Whether the rename field has held focus yet. The page that opens
    /// with a new goal or workflow can grab focus first; losing it before
    /// ever having it must not end the rename.
    @State private var nameHadFocus = false

    var body: some View {
        List(selection: $selection) {
            if module == .goals {
                ForEach(Array(store.goals.enumerated()), id: \.element.id) { index, goal in
                    goalRow(goal, index: index)
                        .tag(MainDestination.goal(goal.id))
                    if !collapsedGoals.contains(goal.id) {
                        ForEach(store.milestones(in: goal.id)) { workflow in
                            workflowRow(workflow, milestoneOf: goal)
                                .padding(.leading, 16)
                                .tag(MainDestination.workflow(workflow.id))
                        }
                    }
                }
                if store.goals.isEmpty {
                    hint("想做成一件大事？先定个目标，再把路上的里程碑排出先后：先做什么，后做什么。")
                }
            } else {
                let standalone = store.standaloneWorkflows
                ForEach(Array(standalone.enumerated()), id: \.element.id) { index, workflow in
                    workflowRow(workflow, milestoneOf: nil, index: index, count: standalone.count)
                        .tag(MainDestination.workflow(workflow.id))
                }
                if standalone.isEmpty {
                    hint(store.workflows.isEmpty
                        ? "把要按顺序推进的事画成一张图：谁先谁后，前一步做完，下一步就亮起来。"
                        : "工作流都在目标的路线图上了。不属于任何目标的工作流会列在这里。")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Text(module.title)
                    .font(.headline)
                Spacer()
                IconButton(
                    title: module == .goals ? "新建目标（⌥⌘N）" : "新建工作流（⇧⌘N）",
                    systemImage: "plus",
                    identifier: "sidebar-add",
                    action: module == .goals ? createGoal : createWorkflow
                )
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
        }
        .safeAreaInset(edge: .bottom) {
            Group {
                if module == .goals {
                    bottomButton("新建目标", systemImage: "flag", help: "新建目标（⌥⌘N）", id: "sidebar-new-goal", action: createGoal)
                } else {
                    bottomButton("新建工作流", systemImage: "plus", help: "新建工作流（⇧⌘N）", id: "sidebar-new-workflow", action: createWorkflow)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .onChange(of: MainRouter.shared.pendingRename, initial: true) { _, request in
            guard let request else { return }
            MainRouter.shared.pendingRename = nil
            switch request {
            case .goal(let id):
                if let goal = store.goal(id: id) { beginRename(goal) }
            case .workflow(let id):
                if let workflow = store.workflow(id: id) { beginRename(workflow) }
            }
        }
        // Opening a milestone (from its roadmap card) unfolds its goal, so
        // the selected row is visible.
        .onChange(of: selection) { _, new in
            guard case .workflow(let id) = new, let goal = store.goal(containing: id) else { return }
            setCollapsed(goal.id, false)
        }
        .confirmationDialog(
            "删除工作流「\(doomed?.name ?? "")」？",
            isPresented: Binding(get: { doomed != nil }, set: { if !$0 { doomed = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除工作流", role: .destructive) {
                guard let doomed else { return }
                if selection == .workflow(doomed.id) {
                    selection = store.goal(containing: doomed.id).map { .goal($0.id) } ?? .workflows
                }
                store.removeWorkflow(id: doomed.id)
                self.doomed = nil
            }
        } message: {
            if let doomed, let goal = store.goal(containing: doomed.id) {
                Text("里面的任务都会保留，只是连线和布局会丢掉。它也会从目标「\(goal.name)」的路线图上移除。")
            } else {
                Text("里面的任务都会保留，只是连线和布局会丢掉。")
            }
        }
        .confirmationDialog(
            "删除目标「\(doomedGoal?.name ?? "")」？",
            isPresented: Binding(get: { doomedGoal != nil }, set: { if !$0 { doomedGoal = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除目标", role: .destructive) {
                guard let doomedGoal else { return }
                let showing = selection == .goal(doomedGoal.id)
                    || doomedGoal.nodes.contains { selection == .workflow($0.workflowID) }
                if showing { selection = .goals }
                store.removeGoal(id: doomedGoal.id)
                self.doomedGoal = nil
            }
        } message: {
            Text("\(doomedGoal?.nodes.count ?? 0) 个里程碑（工作流）和其中的任务都会保留，变成独立的工作流；只丢掉路线图上的连线和布局。")
        }
    }

    // MARK: rows

    private func goalRow(_ goal: Goal, index: Int) -> some View {
        let summaries = store.milestoneSummaries(in: goal.id)
        let progress = goal.progress(workflows: store.workflowsByID)
        let review = summaries.values.filter { $0.state == .review }.count
        let collapsed = collapsedGoals.contains(goal.id)
        return HStack(spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { setCollapsed(goal.id, !collapsed) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 12, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(goal.nodes.isEmpty ? 0 : 1)
            .disabled(goal.nodes.isEmpty)
            .help(collapsed ? "展开里程碑" : "收起里程碑")
            .accessibilityLabel(collapsed ? "展开里程碑" : "收起里程碑")
            .accessibilityIdentifier("sidebar-goal-toggle-\(goal.id.uuidString)")
            Image(systemName: "flag.checkered")
                .foregroundStyle(Theme.focused)
                .frame(width: 16)
            nameField(.goal(goal.id), name: goal.name, placeholder: "目标名")
            Spacer(minLength: 4)
            if summaries.values.contains(where: \.running) {
                PulseDot(color: Theme.focused, active: true, size: 6)
                    .help("有里程碑正在计时")
            }
            if review > 0 {
                countBadge(review, help: "\(review) 个里程碑的任务都做完了，等你确认达成")
            }
            if progress.total > 0 {
                Text("\(progress.achieved)/\(progress.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("已达成 \(progress.achieved) 个里程碑，共 \(progress.total) 个")
            }
        }
        .contextMenu {
            Button("重命名") { beginRename(goal) }
            Button("上移") { store.moveGoal(id: goal.id, by: -1) }
                .disabled(index == 0)
            Button("下移") { store.moveGoal(id: goal.id, by: 1) }
                .disabled(index == store.goals.count - 1)
            Divider()
            Button("删除目标…", role: .destructive) { doomedGoal = goal }
        }
        .accessibilityIdentifier("sidebar-goal-\(goal.id.uuidString)")
    }

    /// A workflow row. Under a goal it reads as a milestone (its order comes
    /// from the roadmap, so no 上移 / 下移); otherwise it can join a goal.
    private func workflowRow(_ workflow: Workflow, milestoneOf goal: Goal?, index: Int = 0, count: Int = 0) -> some View {
        let tasks = store.tasksByID
        let progress = workflow.progress(tasks: tasks)
        let running = workflow.nodes.contains { tasks[$0.taskID]?.isRunning == true }
        // A milestone still waiting on its upstream has nothing to start yet.
        let waiting = goal.map { !$0.blockers(of: workflow.id, workflows: store.workflowsByID).isEmpty } ?? false
        let ready = waiting ? 0 : workflow.nodes.filter { workflow.state(of: $0.taskID, tasks: tasks) == .ready }.count
        return HStack(spacing: 6) {
            Image(systemName: goal == nil ? "point.3.connected.trianglepath.dotted" : workflow.achievedAt != nil ? "flag.fill" : "flag")
                .foregroundStyle(Theme.focused)
                .frame(width: 18)
            nameField(.workflow(workflow.id), name: workflow.name, placeholder: "工作流名")
            Spacer(minLength: 4)
            if running {
                PulseDot(color: Theme.focused, active: true, size: 6)
                    .help("有步骤正在计时")
            }
            if ready > 0 {
                countBadge(ready, help: "\(ready) 步可以开始")
            }
            if progress.total > 0 {
                Text("\(progress.done)/\(progress.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("重命名") { beginRename(workflow) }
            if let goal {
                Button("从目标移除") { store.removeMilestone(workflowID: workflow.id, from: goal.id) }
            } else {
                Button("上移") { store.moveWorkflow(id: workflow.id, by: -1) }
                    .disabled(index == 0)
                Button("下移") { store.moveWorkflow(id: workflow.id, by: 1) }
                    .disabled(index == count - 1)
                if !store.goals.isEmpty {
                    Menu("加入目标") {
                        ForEach(store.goals) { target in
                            Button(target.name) { store.placeMilestone(workflowID: workflow.id, in: target.id) }
                        }
                    }
                }
            }
            Divider()
            Button("删除工作流…", role: .destructive) { doomed = workflow }
        }
        .accessibilityIdentifier("sidebar-workflow-\(workflow.id.uuidString)")
    }

    @ViewBuilder
    private func nameField(_ target: MainRouter.Rename, name: String, placeholder: String) -> some View {
        if renaming == target {
            TextField(placeholder, text: $nameDraft)
                .textFieldStyle(.plain)
                .focused($nameFocused)
                .onSubmit(commitRename)
                .onExitCommand { renaming = nil }
                .onChange(of: nameFocused) { _, focused in
                    if focused {
                        nameHadFocus = true
                    } else if nameHadFocus {
                        commitRename()
                    }
                }
                .accessibilityIdentifier("sidebar-rename")
        } else {
            Text(name)
                .lineLimit(1)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .selectionDisabled()
    }

    private func countBadge(_ count: Int, help: String) -> some View {
        Text("\(count)")
            .font(.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.orange.opacity(0.15), in: Capsule())
            .help(help)
    }

    private func bottomButton(_ title: String, systemImage: String, help: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(HoverButtonStyle(
            shape: .rounded,
            hover: 0.08,
            padding: EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        ))
        .help(help)
        .accessibilityIdentifier(id)
    }

    // MARK: folding

    private var collapsedGoals: Set<UUID> {
        Set(collapsedGoalsRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    private func setCollapsed(_ goalID: UUID, _ collapsed: Bool) {
        var folded = collapsedGoals
        guard folded.contains(goalID) != collapsed else { return }
        if collapsed { folded.insert(goalID) } else { folded.remove(goalID) }
        // Forget goals that are gone.
        folded.formIntersection(store.goals.map(\.id))
        collapsedGoalsRaw = folded.map(\.uuidString).sorted().joined(separator: ",")
    }

    // MARK: actions

    private func createGoal() {
        guard let goal = store.addGoal("新目标") else { return }
        selection = .goal(goal.id)
        beginRename(goal)
    }

    private func createWorkflow() {
        guard let workflow = store.addWorkflow("新工作流") else { return }
        selection = .workflow(workflow.id)
        beginRename(workflow)
    }

    private func beginRename(_ goal: Goal) {
        beginRename(.goal(goal.id), name: goal.name)
    }

    private func beginRename(_ workflow: Workflow) {
        beginRename(.workflow(workflow.id), name: workflow.name)
    }

    private func beginRename(_ target: MainRouter.Rename, name: String) {
        nameDraft = name
        nameHadFocus = false
        renaming = target
        listCollapsed = false
        // The row may not be on screen yet (a window that is just opening),
        // and the page it opens claims focus as it appears: keep asking
        // until the field has it.
        Task { @MainActor in
            for delay in [150, 300, 500, 800] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard renaming == target, !nameHadFocus else { return }
                nameFocused = true
            }
        }
    }

    private func commitRename() {
        switch renaming {
        case .goal(let id): store.renameGoal(id: id, to: nameDraft)
        case .workflow(let id): store.renameWorkflow(id: id, to: nameDraft)
        case nil: return
        }
        renaming = nil
        nameHadFocus = false
    }
}
