import ITimerCore
import SwiftUI

struct MainView: View {
    var store: TaskStore
    @State private var confettiSeed = 0
    @State private var celebrated: Set<UUID> = []
    @State private var primed = false

    var body: some View {
        ZStack {
            NavigationSplitView {
                MenuBarView(store: store, embedded: true)
                    .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 440)
                    .navigationTitle("日程")
            } detail: {
                AnalysisView(store: store)
                    .navigationTitle("注意力分析")
            }
            if confettiSeed > 0 {
                ConfettiView(seed: confettiSeed)
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 920, minHeight: 600)
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
}
