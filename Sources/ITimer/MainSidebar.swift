import ITimerCore
import SwiftUI

/// What the main window's right-hand column shows.
enum MainDestination: Hashable {
    case analysis
    case workflow(UUID)

    /// Stored form for @AppStorage: "analysis" or "workflow:<uuid>".
    var raw: String {
        switch self {
        case .analysis: "analysis"
        case .workflow(let id): "workflow:\(id.uuidString)"
        }
    }

    init(raw: String) {
        if raw.hasPrefix("workflow:"), let id = UUID(uuidString: String(raw.dropFirst("workflow:".count))) {
            self = .workflow(id)
        } else {
            self = .analysis
        }
    }
}

/// Main window sidebar: the analysis, then every workflow canvas.
struct MainSidebar: View {
    var store: TaskStore
    @Binding var selection: MainDestination?
    @State private var renamingID: UUID?
    @State private var nameDraft = ""
    /// Workflow waiting for the delete confirmation.
    @State private var doomed: Workflow?
    @FocusState private var nameFocused: Bool

    var body: some View {
        List(selection: $selection) {
            Section("视图") {
                Label("注意力分析", systemImage: "chart.xyaxis.line")
                    .tag(MainDestination.analysis)
                    .accessibilityIdentifier("sidebar-analysis")
            }
            Section("工作流") {
                ForEach(Array(store.workflows.enumerated()), id: \.element.id) { index, workflow in
                    row(workflow, index: index)
                        .tag(MainDestination.workflow(workflow.id))
                }
                if store.workflows.isEmpty {
                    Text("把要按顺序推进的事画成一张图：谁先谁后，前一步做完，下一步就亮起来。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .selectionDisabled()
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button(action: create) {
                Label("新建工作流", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(HoverButtonStyle(
                shape: .rounded,
                hover: 0.08,
                padding: EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
            ))
            .help("新建工作流（⇧⌘N）")
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .accessibilityIdentifier("sidebar-new-workflow")
        }
        .onReceive(NotificationCenter.default.publisher(for: .iTimerNewWorkflow)) { _ in
            create()
        }
        .confirmationDialog(
            "删除工作流「\(doomed?.name ?? "")」？",
            isPresented: Binding(get: { doomed != nil }, set: { if !$0 { doomed = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除工作流", role: .destructive) {
                guard let doomed else { return }
                if selection == .workflow(doomed.id) { selection = .analysis }
                store.removeWorkflow(id: doomed.id)
                self.doomed = nil
            }
        } message: {
            Text("里面的任务都会保留，只是连线和布局会丢掉。")
        }
    }

    private func row(_ workflow: Workflow, index: Int) -> some View {
        let tasks = store.tasksByID
        let progress = workflow.progress(tasks: tasks)
        let running = workflow.nodes.contains { tasks[$0.taskID]?.isRunning == true }
        let ready = workflow.nodes.filter { workflow.state(of: $0.taskID, tasks: tasks) == .ready }.count
        return HStack(spacing: 6) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(Theme.focused)
                .frame(width: 18)
            if renamingID == workflow.id {
                TextField("工作流名", text: $nameDraft)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { renamingID = nil }
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { commitRename() }
                    }
                    .accessibilityIdentifier("sidebar-rename-workflow")
            } else {
                Text(workflow.name)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if running {
                PulseDot(color: Theme.focused, active: true, size: 6)
                    .help("有步骤正在计时")
            }
            if ready > 0 {
                Text("\(ready)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                    .help("\(ready) 步可以开始")
            }
            if progress.total > 0 {
                Text("\(progress.done)/\(progress.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("重命名") { beginRename(workflow) }
            Button("上移") { store.moveWorkflow(id: workflow.id, by: -1) }
                .disabled(index == 0)
            Button("下移") { store.moveWorkflow(id: workflow.id, by: 1) }
                .disabled(index == store.workflows.count - 1)
            Divider()
            Button("删除工作流…", role: .destructive) { doomed = workflow }
        }
        .accessibilityIdentifier("sidebar-workflow-\(workflow.id.uuidString)")
    }

    private func create() {
        guard let workflow = store.addWorkflow("新工作流") else { return }
        selection = .workflow(workflow.id)
        beginRename(workflow)
    }

    private func beginRename(_ workflow: Workflow) {
        nameDraft = workflow.name
        renamingID = workflow.id
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitRename() {
        guard let id = renamingID else { return }
        store.renameWorkflow(id: id, to: nameDraft)
        renamingID = nil
    }
}
