import ITimerCore
import SwiftUI

struct MainView: View {
    var store: TaskStore
    @AppStorage("mainDestination") private var destinationRaw = MainDestination.analysis.raw
    @State private var confettiSeed = 0
    @State private var celebrated: Set<UUID> = []
    @State private var primed = false

    var body: some View {
        ZStack {
            NavigationSplitView {
                MainSidebar(store: store, selection: selection)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
            } content: {
                // No title here: the window takes the detail's, so it reads
                // 注意力分析, the goal's or the workflow's name.
                MenuBarView(store: store, embedded: true)
                    .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 440)
            } detail: {
                detail
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

    /// A workflow or goal that has since been deleted falls back to the analysis.
    private var destination: MainDestination {
        let stored = MainDestination(raw: destinationRaw)
        switch stored {
        case .workflow(let id) where store.workflow(id: id) == nil: return .analysis
        case .goal(let id) where store.goal(id: id) == nil: return .analysis
        default: return stored
        }
    }

    private var selection: Binding<MainDestination?> {
        Binding(get: { destination }, set: { destinationRaw = ($0 ?? .analysis).raw })
    }

    @ViewBuilder
    private var detail: some View {
        switch destination {
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
                                destinationRaw = MainDestination.goal(goal.id).raw
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
                destinationRaw = MainDestination.workflow(workflowID).raw
            }
            .id(id)
            .navigationTitle(store.goal(id: id)?.name ?? "目标")
        }
    }
}
