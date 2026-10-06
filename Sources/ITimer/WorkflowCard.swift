import ITimerCore
import SwiftUI

/// A task on the canvas: its title, where it stands in the flow, and the
/// same start / pause / complete actions as its row in the list.
struct WorkflowCard: View {
    var task: TaskItem
    var node: WorkflowNode
    var state: WorkflowNodeState
    /// Upstream tasks still open.
    var blockers: Int
    var store: TaskStore
    var workflowID: UUID
    var selected: Bool
    /// Border while a line is dragged over this card: whether it can be wired.
    var linkHighlight: Color?
    var onSelect: () -> Void
    var onAddNext: () -> Void
    @State private var hovering = false
    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var renameFocused: Bool

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    private var id: String { task.id.uuidString }

    /// Orange is "waiting on you", as for a schedule that is due.
    private var stateColor: Color {
        switch state {
        case .ready: .orange
        case .running, .done: Theme.focused
        case .blocked, .paused: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Capsule()
                .fill(task.collectionID != nil ? Theme.collection(task.collectionID) : stateColor.opacity(0.7))
                .frame(width: 3)
                .padding(.vertical, 12)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 6) {
                    title
                    Spacer(minLength: 0)
                    if node.autoStart {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.focused)
                            .padding(.top, 2)
                            .help("上游完成后自动开始计时")
                            .accessibilityLabel("自动开始")
                    }
                }
                Spacer(minLength: 4)
                HStack(spacing: 2) {
                    stateChip
                    Spacer(minLength: 4)
                    actions
                        .opacity(hovering || selected ? 1 : 0.6)
                }
            }
            .padding(.leading, 9)
            .padding(.trailing, 8)
            .padding(.vertical, 9)
        }
        .frame(width: CanvasMetrics.card.width, height: CanvasMetrics.card.height)
        .background(Theme.surface, in: shape)
        .background {
            if state == .running {
                shape.fill(Theme.focused.opacity(0.08))
            }
        }
        .overlay {
            shape.strokeBorder(borderColor, lineWidth: linkHighlight != nil || selected ? 2 : 1)
        }
        .overlay(alignment: .leading) {
            Circle()
                .fill(Theme.surface)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 1))
                .frame(width: 9, height: 9)
                .offset(x: -4.5)
                .accessibilityHidden(true)
        }
        .shadow(color: .black.opacity(selected ? 0.16 : 0.07), radius: selected ? 10 : 5, y: 2)
        .opacity(state == .done ? 0.72 : 1)
        .contentShape(shape)
        .onTapGesture(perform: onSelect)
        .onHover { inside in
            // The open menu covers the card; a hover flip would rebuild it.
            guard !MenuTracking.isOpen else { return }
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workflow-card-\(id)")
    }

    private var borderColor: Color {
        if let linkHighlight { return linkHighlight }
        if selected { return .accentColor }
        switch state {
        case .running: return Theme.focused.opacity(0.55)
        case .ready: return Color.orange.opacity(0.45)
        default: return Color.primary.opacity(hovering ? 0.18 : 0.09)
        }
    }

    @ViewBuilder
    private var title: some View {
        if renaming {
            TextField("名称 #标签", text: $draft)
                .textFieldStyle(.plain)
                .font(.callout.weight(.semibold))
                .focused($renameFocused)
                .onSubmit(commitRename)
                .onExitCommand { renaming = false }
                .onChange(of: renameFocused) { _, focused in
                    if !focused && renaming { commitRename() }
                }
                .accessibilityIdentifier("workflow-rename-\(id)")
        } else {
            Text(task.title)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
                .strikethrough(state == .done, color: .secondary)
                .foregroundStyle(state == .blocked ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .onTapGesture(count: 2, perform: beginRename)
        }
    }

    private var stateChip: some View {
        HStack(spacing: 4) {
            if state == .running {
                PulseDot(color: Theme.focused, active: true, size: 6)
            } else {
                Image(systemName: stateIcon)
            }
            Text(stateText)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(stateColor)
        .help(stateHelp)
    }

    private var stateIcon: String {
        switch state {
        case .blocked: "hourglass"
        case .ready: "play.circle"
        case .running: "circle.fill"
        case .paused: "pause.circle"
        case .done: "checkmark.circle.fill"
        }
    }

    private var stateText: String {
        let spent = task.duration(asOf: store.now)
        switch state {
        case .blocked:
            return blockers > 1 ? "等待上游 \(blockers)" : "等待上游"
        case .ready:
            return task.plannedDuration.map { "可开始 · \(DurationFormat.prose($0))" } ?? "可开始"
        case .running:
            return DurationFormat.clock(spent)
        case .paused:
            return "已暂停 · \(DurationFormat.clock(spent))"
        case .done:
            return spent >= 60 ? "完成 · \(DurationFormat.prose(spent))" : "已完成"
        }
    }

    private var stateHelp: String {
        switch state {
        case .blocked:
            let names = store.workflowBlockers(of: task.id).map { "「\($0.title)」" }.joined(separator: "、")
            return "还在等 \(names) 完成"
        case .ready:
            return node.autoStart ? "上游都完成了，可以开始" : "上游都完成了，等你开始"
        default:
            return state.title
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .running:
            IconButton(title: "暂停", systemImage: "pause.fill", identifier: "workflow-pause-\(id)") {
                store.pause(id: task.id)
            }
            completeButton
        case .paused:
            IconButton(title: "继续", systemImage: "play.fill", identifier: "workflow-resume-\(id)") {
                store.resume(id: task.id)
            }
            completeButton
        case .ready, .blocked:
            IconButton(
                title: state == .blocked ? "上游还没完成，也可以先开始" : "开始计时",
                systemImage: "play.fill",
                tint: state == .ready ? .orange : .primary,
                identifier: "workflow-start-\(id)"
            ) {
                store.resume(id: task.id)
            }
            completeButton
        case .done:
            EmptyView()
        }
    }

    private var completeButton: some View {
        IconButton(title: "完成", systemImage: "checkmark", identifier: "workflow-complete-\(id)") {
            store.complete(id: task.id)
        }
    }

    @ViewBuilder
    private var menu: some View {
        switch state {
        case .done:
            Button("再来一段") { store.resume(id: task.id) }
        case .running:
            Button("暂停") { store.pause(id: task.id) }
            Button("完成") { store.complete(id: task.id) }
        case .paused:
            Button("继续") { store.resume(id: task.id) }
            Button("完成") { store.complete(id: task.id) }
        case .ready, .blocked:
            Button("开始计时") { store.resume(id: task.id) }
            Button("完成") { store.complete(id: task.id) }
        }
        if state != .done, store.runningTasks.contains(where: { $0.id != task.id }) {
            Button("只做这个（暂停其他）") { store.focus(id: task.id) }
        }
        Divider()
        Toggle("上游完成后自动开始", isOn: Binding(
            get: { node.autoStart },
            set: { store.setAutoStart(taskID: task.id, in: workflowID, $0) }
        ))
        Button("添加下一步", action: onAddNext)
        Divider()
        Button("改名", action: beginRename)
        Button("从工作流移除") { store.removeNode(taskID: task.id, from: workflowID) }
        Button("删除任务", role: .destructive) { store.delete(id: task.id) }
    }

    private func beginRename() {
        draft = TaskStore.input(for: task)
        renaming = true
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        if draft.trimmingCharacters(in: .whitespaces).isEmpty || store.retitle(id: task.id, input: draft) {
            renaming = false
        }
    }
}

/// Popover list of open tasks to put on the canvas. A task on another
/// workflow says so; picking it moves it here.
struct WorkflowTaskPicker: View {
    var store: TaskStore
    var workflowID: UUID
    var onPick: (UUID) -> Void
    @State private var query = ""

    var body: some View {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = store.tasks
            .filter { !$0.isCompleted && store.workflow(containing: $0.id)?.id != workflowID }
            .filter { needle.isEmpty || TaskStore.input(for: $0).lowercased().contains(needle) }
            .sorted { $0.createdAt > $1.createdAt }
        VStack(alignment: .leading, spacing: 8) {
            TextField("搜索未完成的任务", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("workflow-picker-search")
            if candidates.isEmpty {
                Text(needle.isEmpty ? "没有可以放上来的未完成任务。" : "没有匹配的任务。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(candidates.prefix(60)) { task in
                            row(task)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    private func row(_ task: TaskItem) -> some View {
        Button {
            onPick(task.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: task.isRunning ? "record.circle" : task.isPaused ? "pause.circle" : "circle.dashed")
                    .foregroundStyle(task.isRunning ? AnyShapeStyle(Theme.focused) : AnyShapeStyle(.tertiary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if let collection = store.collection(id: task.collectionID) {
                            CollectionPill(collection: collection)
                        }
                        if let other = store.workflow(containing: task.id) {
                            Text("在「\(other.name)」中，会移过来")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(shape: .rounded, hover: 0.08))
        .accessibilityIdentifier("workflow-pick-\(task.id.uuidString)")
    }
}
