import ITimerCore
import SwiftUI

/// The 目标 menu in the menu bar: make a goal, or jump to one's roadmap.
/// Works with the main window closed — it opens the window on the way.
struct GoalCommands: View {
    var store: TaskStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("mainDestination") private var destinationRaw = MainDestination.analysis.raw

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
        open(.goal(goal.id))
    }
}
