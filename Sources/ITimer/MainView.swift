import ITimerCore
import SwiftUI

struct MainView: View {
    var store: TaskStore
    @AppStorage("mainDestination") private var destinationRaw = MainDestination.tasks.raw
    /// Where 目标 and 工作流 were last, so switching back returns there.
    @AppStorage("lastGoalsDestination") private var lastGoalsRaw = MainDestination.goals.raw
    @AppStorage("lastWorkflowsDestination") private var lastWorkflowsRaw = MainDestination.workflows.raw
    @AppStorage("listPanelCollapsed") private var listCollapsed = false
    @AppStorage("taskFilter") private var taskFilterRaw = TaskFilter.all.raw
    /// Held at `.all`: the rail must never be folded away with the list.
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var confettiSeed = 0
    @State private var celebrated: Set<UUID> = []
    @State private var primed = false

    var body: some View {
        ZStack {
            NavigationSplitView(columnVisibility: $columns) {
                sidebar
            } detail: {
                detail
                    .toolbar {
                        if module.hasList {
                            ToolbarItem(placement: .navigation) {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) { listCollapsed.toggle() }
                                } label: {
                                    Label(listCollapsed ? "展开列表" : "收起列表", systemImage: "sidebar.left")
                                }
                                .keyboardShortcut("s", modifiers: [.control, .command])
                                .help(listCollapsed ? "展开\(module.title)列表（⌃⌘S）" : "收起\(module.title)列表（⌃⌘S）")
                                .accessibilityIdentifier("list-panel-toggle")
                            }
                        }
                    }
            }
            .onChange(of: columns) { _, new in
                if new != .all { columns = .all }
            }
            .onChange(of: destinationRaw, initial: true) { _, _ in
                remember(destination)
            }
            if confettiSeed > 0 {
                ConfettiView(seed: confettiSeed)
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 1040, minHeight: 600)
        .accessibilityIdentifier("main-window")
        .onChange(of: store.tasks, initial: true) { _, new in
            let done = new.filter(\.isCompleted)
            if !primed {
                celebrated = Set(done.map(\.id))
                primed = true
                return
            }
            for task in done where !celebrated.contains(task.id) {
                celebrated.insert(task.id)
                guard task.duration(asOf: store.now) >= 5 * 60 else { continue }
                confettiSeed += 1
                let seed = confettiSeed
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3.2))
                    if confettiSeed == seed {
                        confettiSeed = 0
                    }
                }
            }
        }
    }

    /// A workflow or goal that has since been deleted falls back to its
    /// module with nothing picked.
    private var destination: MainDestination {
        MainDestination(raw: destinationRaw).resolved(in: store)
    }

    private var module: MainModule { destination.module(in: store) }

    private var selection: Binding<MainDestination?> {
        Binding(get: { destination }, set: { go($0 ?? .tasks) })
    }

    private var showsList: Bool { module.hasList && !listCollapsed }

    private var taskFilter: Binding<TaskFilter> {
        Binding(get: { TaskFilter(raw: taskFilterRaw) }, set: { taskFilterRaw = $0.raw })
    }

    /// The rail, and the module's list beside it unless folded.
    private var sidebar: some View {
        HStack(spacing: 0) {
            MainRail(store: store, module: module, select: open)
            if showsList {
                Divider()
                if module == .tasks {
                    TaskListPanel(store: store, filter: taskFilter)
                } else {
                    MainSidebar(store: store, module: module, selection: selection)
                }
            }
        }
        // The column takes its new width a beat after the content changes;
        // pinned left, the rail stays put instead of sliding in from the
        // middle of the old width.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        // The system's toggle would hide the rail along with the list.
        .toolbar(removing: .sidebarToggle)
        // Folding narrows the column to the rail instead of hiding it.
        .navigationSplitViewColumnWidth(
            min: showsList ? MainRail.width + 200 : MainRail.width,
            ideal: showsList ? MainRail.width + 230 : MainRail.width,
            max: showsList ? MainRail.width + 320 : MainRail.width
        )
    }

    private func go(_ destination: MainDestination) {
        destinationRaw = destination.raw
    }

    /// Notes where 目标 or 工作流 is, wherever the change came from (the
    /// rail, a list row, a roadmap card, the 目标 menu).
    private func remember(_ destination: MainDestination) {
        switch destination.module(in: store) {
        case .goals: lastGoalsRaw = destination.raw
        case .workflows: lastWorkflowsRaw = destination.raw
        case .tasks, .analysis: break
        }
    }

    /// Switches modules from the rail: back to where that module was left,
    /// else its first item.
    private func open(_ target: MainModule) {
        switch target {
        case .tasks: go(.tasks)
        case .analysis: go(.analysis)
        case .goals:
            let last = MainDestination(raw: lastGoalsRaw).resolved(in: store)
            if last.module(in: store) == .goals, last != .goals {
                go(last)
            } else {
                go(store.goals.first.map { .goal($0.id) } ?? .goals)
            }
        case .workflows:
            let last = MainDestination(raw: lastWorkflowsRaw).resolved(in: store)
            if last.module(in: store) == .workflows, last != .workflows {
                go(last)
            } else {
                go(store.standaloneWorkflows.first.map { .workflow($0.id) } ?? .workflows)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch destination {
        case .tasks:
            let filter = TaskFilter(raw: taskFilterRaw)
            MenuBarView(store: store, embedded: true, filter: filter)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .navigationTitle(filter == .all ? "任务" : "任务 › \(filter.title)")
        case .goals:
            ContentUnavailableView {
                Label("还没有目标", systemImage: "flag.checkered")
            } description: {
                Text("想做成一件大事？先定个目标，再把路上的里程碑排出先后：先做什么，后做什么。")
            } actions: {
                Button("新建目标") { createGoal() }
                    .accessibilityIdentifier("empty-new-goal")
            }
            .navigationTitle("目标")
        case .workflows:
            ContentUnavailableView {
                Label("没有独立的工作流", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text("把要按顺序推进的事画成一张图：谁先谁后，前一步做完，下一步就亮起来。")
            } actions: {
                Button("新建工作流") { createWorkflow() }
                    .accessibilityIdentifier("empty-new-workflow")
            }
            .navigationTitle("工作流")
        case .analysis:
            AnalysisView(store: store)
                .navigationTitle("注意力分析")
        case .workflow(let id):
            let goal = store.goal(containing: id)
            let name = store.workflow(id: id)?.name ?? "工作流"
            WorkflowCanvasView(store: store, workflowID: id)
                .id(id)
                .navigationTitle(goal.map { "\($0.name) › \(name)" } ?? name)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        if let goal {
                            Button {
                                go(.goal(goal.id))
                            } label: {
                                Label("返回路线图", systemImage: "chevron.backward")
                            }
                            .help("回到目标「\(goal.name)」的路线图")
                            .accessibilityIdentifier("back-to-roadmap")
                        }
                    }
                }
        case .goal(let id):
            GoalCanvasView(store: store, goalID: id) { workflowID in
                go(.workflow(workflowID))
            }
            .id(id)
            .navigationTitle(store.goal(id: id)?.name ?? "目标")
        }
    }

    private func createGoal() {
        guard let goal = store.addGoal("新目标") else { return }
        MainRouter.shared.pendingRename = .goal(goal.id)
        listCollapsed = false
        go(.goal(goal.id))
    }

    private func createWorkflow() {
        guard let workflow = store.addWorkflow("新工作流") else { return }
        MainRouter.shared.pendingRename = .workflow(workflow.id)
        listCollapsed = false
        go(.workflow(workflow.id))
    }
}
