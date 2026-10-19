import ITimerCore
import SwiftUI

/// The task list's right-hand drawer: beside the list in the main window,
/// sliding over it in the panel. A title bar with a close button (Esc),
/// the content scrolling below.
struct SideDrawer<Content: View>: View {
    static var width: CGFloat { 340 }

    var title: String
    var onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                Spacer()
                IconButton(title: "关闭（Esc）", systemImage: "xmark", identifier: "drawer-close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                content
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("side-drawer")
    }
}

/// Everything about one task, edited in place: name, time, estimate,
/// reminder and tags save themselves after a pause, like the note; subtasks
/// and progress are added right here.
struct TaskDetailView: View {
    var task: TaskItem
    var store: TaskStore
    var now: Date
    /// Opens another task's details: a subtask, or the parent.
    var onOpen: (UUID) -> Void
    /// Opened to add a subtask: the field takes focus, then says so.
    var focusSubtask = false
    var onSubtaskFocused: () -> Void = {}
    var onSubtaskAdded: () -> Void = {}
    @State private var draft: ScheduleDraft
    /// The draft as last loaded or saved; `draft` differing from it is an
    /// edit still waiting to be saved.
    @State private var saved: ScheduleDraft
    @State private var subtaskDraft = ""
    @FocusState private var subtaskFocused: Bool

    init(
        task: TaskItem,
        store: TaskStore,
        now: Date,
        onOpen: @escaping (UUID) -> Void,
        focusSubtask: Bool = false,
        onSubtaskFocused: @escaping () -> Void = {},
        onSubtaskAdded: @escaping () -> Void = {}
    ) {
        self.task = task
        self.store = store
        self.now = now
        self.onOpen = onOpen
        self.focusSubtask = focusSubtask
        self.onSubtaskFocused = onSubtaskFocused
        self.onSubtaskAdded = onSubtaskAdded
        let draft = ScheduleDraft.editing(task, asOf: now)
        _draft = State(initialValue: draft)
        _saved = State(initialValue: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            status
            ScheduleComposer(draft: $draft, now: now, onSave: commit)
            if task.isRoot {
                subtasks
            }
            JournalView(task: task, store: store, now: now)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-detail")
        // Each save rewrites the data file and the calendar event, so wait
        // for a pause; closing the drawer mid-pause still saves.
        .task(id: draft) {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            commit()
        }
        .onDisappear(perform: commit)
        // Started, postponed, renamed or retagged from the list meanwhile.
        .onChange(of: Fields(task)) { _, _ in reload() }
        .onAppear { if focusSubtask { takeSubtaskFocus() } }
        .onChange(of: focusSubtask) { _, wants in if wants { takeSubtaskFocus() } }
    }

    /// What the form shows; a change from elsewhere reloads it.
    private struct Fields: Equatable {
        var title: String
        var tags: [String]
        var start: Date?
        var duration: TimeInterval?
        var reminder: TimeInterval?
        var pending: Bool
        var completed: Bool

        init(_ task: TaskItem) {
            title = task.title
            tags = task.tags
            start = task.scheduledStart
            duration = task.plannedDuration
            reminder = task.reminderLead
            pending = task.isPending
            completed = task.isCompleted
        }
    }

    // MARK: status

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(statusText)
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("task-detail-status")
            if let parent = store.parent(of: task) {
                Button { onOpen(parent.id) } label: {
                    HStack(spacing: 3) {
                        Text("↳ 属于「\(parent.title)」")
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("打开「\(parent.title)」的详情")
                .accessibilityIdentifier("task-detail-parent")
            }
        }
    }

    private var statusColor: Color {
        if task.isRunning { return Theme.focused }
        if task.isDue(asOf: now) { return .orange }
        return Color.secondary.opacity(task.isCompleted ? 0.4 : 0.7)
    }

    private var statusText: String {
        let spent = task.duration(asOf: now)
        if task.isCompleted { return "已完成 · 共 \(DurationFormat.prose(spent))" }
        if task.isRunning { return "计时中 · \(DurationFormat.clock(spent))" }
        if !task.isPending { return "已暂停 · 已计 \(DurationFormat.prose(spent))" }
        if task.isUndated { return "时间待定" }
        return task.isDue(asOf: now) ? "到点待开始" : "未开始"
    }

    // MARK: subtasks

    private var subtasks: some View {
        let children = store.subtasks(of: task.id)
        let finished = children.filter(\.isCompleted).count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                sectionTitle("子任务")
                if !children.isEmpty {
                    Text("\(finished)/\(children.count)")
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(finished == children.count ? AnyShapeStyle(Theme.focused) : AnyShapeStyle(.secondary))
                }
            }
            if children.isEmpty && task.isCompleted {
                Text("没有子任务。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(children) { child in
                    subtaskRow(child)
                }
            }
            // A finished task takes no new steps.
            if !task.isCompleted {
                subtaskField
            }
        }
    }

    private func subtaskRow(_ child: TaskItem) -> some View {
        HStack(spacing: 6) {
            if child.isCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.focused.opacity(0.8))
                    .frame(width: 22, height: 22)
            } else {
                IconButton(
                    title: child.isRunning ? "暂停" : child.isPending ? "开始计时" : "继续",
                    systemImage: child.isRunning ? "pause.fill" : "play.fill",
                    tint: Theme.focused,
                    identifier: "detail-subtask-toggle-\(child.id.uuidString)"
                ) {
                    if child.isRunning { store.pause(id: child.id) } else { store.resume(id: child.id) }
                }
            }
            Button { onOpen(child.id) } label: {
                HStack(spacing: 6) {
                    Text(child.title)
                        .font(.callout)
                        .foregroundStyle(child.isCompleted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(subtaskState(child))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(child.isDue(asOf: now) ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开「\(child.title)」的详情")
            .accessibilityIdentifier("detail-subtask-\(child.id.uuidString)")
        }
        .padding(.vertical, 1)
    }

    private func subtaskState(_ child: TaskItem) -> String {
        if child.isCompleted { return DurationFormat.prose(child.duration(asOf: now)) }
        if !child.isPending { return DurationFormat.clock(child.duration(asOf: now)) }
        guard let start = child.scheduledStart else { return "待定" }
        return TaskRow.timeLabel(start, now: now)
    }

    /// Each Return adds one step (time to be decided, not started) and
    /// keeps the field for the next.
    private var subtaskField: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 22)
            TextField("添加子任务，回车添加", text: $subtaskDraft)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($subtaskFocused)
                .onSubmit(commitSubtask)
                .accessibilityIdentifier("subtask-input-\(task.id.uuidString)")
        }
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(
            subtaskFocused ? Theme.focused.opacity(0.07) : Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
    }

    private func takeSubtaskFocus() {
        DispatchQueue.main.async { subtaskFocused = true }
        onSubtaskFocused()
    }

    private func commitSubtask() {
        guard store.addSchedule(
            title: subtaskDraft,
            parentID: task.id,
            start: nil,
            plannedDuration: nil,
            reminderLead: nil
        ) != nil else { return }
        subtaskDraft = ""
        subtaskFocused = true
        onSubtaskAdded()
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    // MARK: saving

    /// Writes what changed since the last save. A blank name is not saved;
    /// the stored one stays.
    private func commit() {
        guard draft != saved, let current = store.tasks.first(where: { $0.id == task.id }) else { return }
        let value = draft
        let before = saved
        saved = value
        if value.titleValid {
            let labels = value.resolved
            if labels.title != current.title {
                store.rename(id: task.id, title: labels.title)
            }
            store.setTags(id: task.id, labels.tags)
        } else if value.tags != before.tags {
            store.setTags(id: task.id, value.tags)
        }
        guard value.scheduleEditable,
              value.scheduledStart != before.scheduledStart
                || value.duration != before.duration
                || value.reminderLead != before.reminderLead else { return }
        store.updateSchedule(id: task.id, start: value.scheduledStart, plannedDuration: value.duration, reminderLead: value.reminderLead)
    }

    /// Saves anything pending, then shows what the store now holds.
    private func reload() {
        commit()
        guard let current = store.tasks.first(where: { $0.id == task.id }) else { return }
        let fresh = ScheduleDraft.editing(current, asOf: now)
        draft = fresh
        saved = fresh
    }
}
