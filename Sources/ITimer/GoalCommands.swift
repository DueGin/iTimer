import ITimerCore
import SwiftUI

/// The 目标 menu in the menu bar: make a goal, or jump to one's roadmap.
/// Works with the main window closed — it opens the window on the way.
struct GoalCommands: View {
    var store: TaskStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("mainDestination") private var destinationRaw = MainDestination.tasks.raw
    @AppStorage("listPanelCollapsed") private var listCollapsed = false

    var body: some View {
        Button("新建目标", action: create)
            .keyboardShortcut("n", modifiers: [.command, .option])
        Divider()
        if store.goals.isEmpty {
            Button("还没有目标") {}
                .disabled(true)
        }
        ForEach(store.goals) { goal in
            Button(goal.name) { open(.goal(goal.id)) }
        }
    }

    private func open(_ destination: MainDestination) {
        destinationRaw = destination.raw
        MainWindow.reveal(openWindow)
    }

    private func create() {
        guard let goal = store.addGoal("新目标") else { return }
        MainRouter.shared.pendingRename = .goal(goal.id)
        listCollapsed = false
        open(.goal(goal.id))
    }
}

/// 文件 › 新建任务 / 新建工作流. Each opens the main window on the module
/// it belongs to, so it works from the menu bar panel too.
struct NewItemCommands: View {
    var store: TaskStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("mainDestination") private var destinationRaw = MainDestination.tasks.raw
    @AppStorage("listPanelCollapsed") private var listCollapsed = false

    var body: some View {
        Button("新建任务") {
            destinationRaw = MainDestination.tasks.raw
            MainWindow.reveal(openWindow)
            // After the 任务 page is on screen.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .iTimerFocusNewTask, object: nil)
            }
        }
        .keyboardShortcut("n", modifiers: .command)
        Button("新建工作流") {
            guard let workflow = store.addWorkflow("新工作流") else { return }
            MainRouter.shared.pendingRename = .workflow(workflow.id)
            listCollapsed = false
            destinationRaw = MainDestination.workflow(workflow.id).raw
            MainWindow.reveal(openWindow)
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
    }
}
