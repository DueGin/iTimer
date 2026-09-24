import AppKit
import ITimerCore
import SwiftUI

struct MenuBarView: View {
    var store: TaskStore
    var embedded = false
    @Environment(\.openWindow) private var openWindow
    @State private var draft = ""
    @State private var editingID: UUID?
    @State private var renameDraft = ""
    @FocusState private var draftFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            hero
            if let lastError = store.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            taskList
            newTaskRow
            if embedded {
                Divider()
                calendarRow
            } else {
                Divider()
                footer
            }
        }
        .padding(embedded ? 18 : 16)
        .frame(width: embedded ? nil : 400, height: embedded ? nil : popupHeight)
        .frame(maxWidth: embedded ? .infinity : nil, maxHeight: embedded ? .infinity : nil, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menu-panel")
        // Note: do NOT makeKey()/activate the panel window here. Doing so
        // steals focus from the status item and macOS dismisses the panel.
        .onReceive(NotificationCenter.default.publisher(for: .iTimerStartTask)) { note in
            // Only one visible instance may create the task — popup and
            // sidebar both subscribe, and both would otherwise insert a copy.
            guard !embedded, let title = note.userInfo?["title"] as? String else { return }
            if let at = note.userInfo?["at"] as? Date {
                _ = store.addTask(title: title, at: at)
            } else {
                draft = title
                startDraft()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .iTimerPauseFirst)) { _ in
            guard !embedded, let id = store.runningTasks.first?.id else { return }
            store.pause(id: id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .iTimerOpenAnalysis)) { _ in
            guard !embedded else { return }
            revealAnalysis()
        }
        .onReceive(NotificationCenter.default.publisher(for: .iTimerFocusNewTask)) { _ in
            draftFocused = true
        }
    }

    // MARK: header

    /// MenuBarExtra windows do not grow past their ideal height, and a
    /// compressed ScrollView swallows all but the last task. Size explicitly.
    private var popupHeight: CGFloat {
        let rows = store.runningTasks.count + store.pausedTasks.count
        let sections = (store.runningTasks.isEmpty ? 0 : 1) + (store.pausedTasks.isEmpty ? 0 : 1)
        let listHeight: CGFloat = rows == 0 ? 64 : min(CGFloat(rows) * 62 + CGFloat(sections) * 24, 340)
        return 152 + listHeight + 118
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(store.now, format: .dateTime.weekday(.wide).month().day())
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(nil)
            Spacer()
            let streak = StreakCache.shared.streak(store: store)
            if streak >= 2 {
                Label("\(streak) 天", systemImage: "flame.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("连续专注 \(streak) 天")
            }
            Text(DurationFormat.prose(todayTotal))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("today-total")
        }
    }

    // MARK: hero

    private var hero: some View {
        HStack(alignment: .center, spacing: 14) {
            PulseDot(color: Theme.verdict(store.liveVerdict), active: store.runningCount > 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(heroTitle)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(Theme.verdict(store.liveVerdict).opacity(store.runningCount > 0 ? 1 : 0.35))
                Text(playfulVerdict)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("hero-timer")
    }

    private var heroTitle: String {
        let count = store.runningCount
        if count == 0 { return DurationFormat.clock(todayTotal) }
        let clock = DurationFormat.clock(store.longestRunningElapsed)
        return count == 1 ? clock : "\(count)·\(clock)"
    }

    private var playfulVerdict: String {
        switch store.liveVerdict {
        case .idle: "今日合计 · 歇着也是恢复"
        case .focused: "单核运转中"
        case .mild: "左右脑互搏"
        case .brainSplit: "脑子裂成 \(store.runningCount) 瓣"
        }
    }

    // MARK: tasks

    @ViewBuilder
    private var taskList: some View {
        if store.runningTasks.isEmpty && store.pausedTasks.isEmpty {
            Text("没有人生的计时是白费的——从一个任务开始。结尾加个 #标签，统计会帮你归类。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !store.runningTasks.isEmpty {
                        sectionTitle("进行中")
                        ForEach(store.runningTasks) { task in
                            TaskRow(task: task, store: store, editingID: $editingID, renameDraft: $renameDraft)
                        }
                    }
                    if !store.pausedTasks.isEmpty {
                        sectionTitle("已暂停")
                        ForEach(store.pausedTasks) { task in
                            TaskRow(task: task, store: store, editingID: $editingID, renameDraft: $renameDraft)
                        }
                    }
                }
            }
            .frame(maxHeight: embedded ? .infinity : 340)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.top, 6)
    }

    private var newTaskRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.secondary)
            TextField("做什么？结尾可加 #标签", text: $draft)
                .textFieldStyle(.plain)
                .focused($draftFocused)
                .onSubmit(startDraft)
                .accessibilityIdentifier("new-task-field")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(draftFocused ? 0.25 : 0.07), lineWidth: 1)
        }
    }

    private var calendarRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .foregroundStyle(.secondary)
            Toggle("同步到日历", isOn: calendarBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("calendar-sync-toggle")
            Spacer()
            if let status = calendarStatus {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if case .denied = CalendarManager.shared.syncer.availability {
                Link("去开启", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    .font(.caption2)
            }
        }
    }

    private var calendarBinding: Binding<Bool> {
        Binding(
            get: { store.calendarSyncEnabled },
            set: { on in
                if on {
                    Task { await CalendarManager.shared.requestEnable() }
                } else {
                    store.setCalendarSyncEnabled(false)
                }
            }
        )
    }

    private var calendarStatus: String? {
        guard store.calendarSyncEnabled else { return nil }
        switch CalendarManager.shared.syncer.availability {
        case .granted(let name): return "写入「\(name)」"
        case .denied: return "无权限"
        case .notDetermined: return "待授权"
        }
    }

    private var footer: some View {
        HStack {
            Button("分析") { revealAnalysis() }
                .accessibilityIdentifier("open-analysis")
            Spacer()
            Button("退出") { NSApp.terminate(nil) }
                .accessibilityIdentifier("quit-app")
        }
        .controlSize(.small)
    }

    private func startDraft() {
        guard store.addTask(title: draft) != nil else { return }
        draft = ""
        editingID = nil
    }

    private var todayTotal: TimeInterval {
        let window = AnalysisRange.today.window(asOf: store.now, tasks: store.tasks)
        return store.tasks.reduce(0) { $0 + $1.duration(asOf: store.now, within: window) }
    }

    private func revealAnalysis() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "analysis")
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct TaskRow: View {
    var task: TaskItem
    var store: TaskStore
    @Binding var editingID: UUID?
    @Binding var renameDraft: String
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                PulseDot(color: task.isRunning ? Theme.focused : .secondary, active: task.isRunning)
                if editingID == task.id {
                    TextField("任务名", text: $renameDraft)
                        .textFieldStyle(.plain)
                        .onSubmit(commitRename)
                        .accessibilityIdentifier("rename-field-\(task.id.uuidString)")
                } else {
                    Text(task.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                }
                ForEach(task.tags, id: \.self) { tag in
                    tagPill(tag)
                }
                Spacer(minLength: 8)
                Text(DurationFormat.clock(task.duration(asOf: store.now)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(task.isRunning ? Color.primary : Color.secondary)
            }
            controls
                .opacity(hovering || editingID == task.id ? 1 : 0.5)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) {
                hovering = inside
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-row-\(task.id.uuidString)")
    }

    private func tagPill(_ tag: String) -> some View {
        Text(tag)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Theme.tag(tag))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.tag(tag).opacity(0.14), in: Capsule())
    }

    private var controls: some View {
        HStack(spacing: 6) {
            if task.isRunning {
                actionButton("暂停", systemImage: "pause.fill", id: "pause-\(task.id.uuidString)") {
                    store.pause(id: task.id)
                }
            } else {
                actionButton("继续", systemImage: "play.fill", id: "resume-\(task.id.uuidString)") {
                    store.resume(id: task.id)
                }
            }
            actionButton("完成", systemImage: "checkmark", id: "complete-\(task.id.uuidString)") {
                store.complete(id: task.id)
            }
            Spacer(minLength: 0)
            if editingID == task.id {
                actionButton("保存", systemImage: "checkmark.circle", id: "rename-\(task.id.uuidString)") {
                    commitRename()
                }
            } else {
                actionButton("改名", systemImage: "pencil", id: "rename-\(task.id.uuidString)") {
                    editingID = task.id
                    renameDraft = task.title
                }
            }
            actionButton("删除", systemImage: "trash", id: "delete-\(task.id.uuidString)") {
                store.delete(id: task.id)
            }
        }
    }

    private func actionButton(_ title: String, systemImage: String, id: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Capsule())
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func commitRename() {
        if store.rename(id: task.id, title: renameDraft) {
            editingID = nil
        }
    }
}
