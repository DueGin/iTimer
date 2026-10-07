import ITimerCore
import SwiftUI

/// Which tasks the main window's 任务 page lists: the rows of its list
/// panel, a status or a tag.
enum TaskFilter: Hashable {
    case all
    case due
    case running
    case paused
    case upcoming
    case undated
    case doneToday
    case tag(String)

    static let statuses: [TaskFilter] = [.all, .due, .running, .paused, .upcoming, .undated, .doneToday]

    /// Stored form for @AppStorage: "all", "running", … or "tag:<name>".
    var raw: String {
        switch self {
        case .all: "all"
        case .due: "due"
        case .running: "running"
        case .paused: "paused"
        case .upcoming: "upcoming"
        case .undated: "undated"
        case .doneToday: "doneToday"
        case .tag(let tag): "tag:\(tag)"
        }
    }

    init(raw: String) {
        if raw.hasPrefix("tag:") {
            self = .tag(String(raw.dropFirst("tag:".count)))
        } else {
            self = Self.statuses.first { $0.raw == raw } ?? .all
        }
    }

    var title: String {
        switch self {
        case .all: "全部"
        case .due: "到点待开始"
        case .running: "进行中"
        case .paused: "已暂停"
        case .upcoming: "接下来"
        case .undated: "时间待定"
        case .doneToday: "今日完成"
        case .tag(let tag): "#\(tag)"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "tray.full"
        case .due: "alarm"
        case .running: "play.circle"
        case .paused: "pause.circle"
        case .upcoming: "calendar"
        case .undated: "questionmark.circle"
        case .doneToday: "checkmark.circle"
        case .tag: "number"
        }
    }

    /// Under a tag, only tasks carrying it; statuses pick whole sections.
    func admits(_ task: TaskItem) -> Bool {
        guard case .tag(let tag) = self else { return true }
        return task.tags.contains(tag)
    }

    /// The one status section listed, by `MenuBarView`'s section order
    /// (到点待开始, 进行中, 已暂停, 接下来, 时间待定); nil = every section.
    var section: Int? {
        switch self {
        case .due: 0
        case .running: 1
        case .paused: 2
        case .upcoming: 3
        case .undated: 4
        case .all, .doneToday, .tag: nil
        }
    }

    /// Whether today's finished tasks are listed.
    var showsDone: Bool {
        switch self {
        case .all, .doneToday, .tag: true
        case .due, .running, .paused, .upcoming, .undated: false
        }
    }

    /// The tasks its row counts — the same ones the page lists for it.
    @MainActor
    func members(in store: TaskStore) -> [TaskItem] {
        switch self {
        case .all: store.tasks.filter { !$0.isCompleted }
        case .due: store.dueSchedules
        case .running: store.runningTasks
        case .paused: store.pausedTasks
        case .upcoming: store.upcomingSchedules
        case .undated: store.undatedSchedules
        case .doneToday: store.completedToday()
        case .tag: (store.tasks.filter { !$0.isCompleted } + store.completedToday()).filter(admits)
        }
    }

    /// Tags on what the page can show (open tasks and today's finished
    /// ones), most used first.
    @MainActor
    static func tags(in store: TaskStore) -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for task in store.tasks.filter({ !$0.isCompleted }) + store.completedToday() {
            for tag in task.tags { counts[tag, default: 0] += 1 }
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }
}

/// The 任务 page's list panel: smart lists by status, then tags.
struct TaskListPanel: View {
    var store: TaskStore
    @Binding var filter: TaskFilter

    var body: some View {
        let tags = TaskFilter.tags(in: store)
        List(selection: Binding(get: { filter }, set: { filter = $0 ?? .all })) {
            ForEach(TaskFilter.statuses, id: \.self) { status in
                let count = status.members(in: store).count
                // 到点待开始 only matters while something is waiting.
                if status != .due || count > 0 || filter == .due {
                    row(status, count: count)
                }
            }
            if !tags.isEmpty {
                Section("标签") {
                    ForEach(tags, id: \.tag) { entry in
                        row(.tag(entry.tag), count: entry.count)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            ListPanelHeader(title: MainModule.tasks.title, addHelp: "新建任务（⌘N）") {
                NotificationCenter.default.post(name: .iTimerFocusNewTask, object: nil)
            }
        }
        // A tag whose last task is gone takes its row with it.
        .onChange(of: tags.map(\.tag)) { _, names in
            if case .tag(let tag) = filter, !names.contains(tag) { filter = .all }
        }
    }

    private func row(_ entry: TaskFilter, count: Int) -> some View {
        HStack(spacing: 6) {
            Label(entry.title, systemImage: entry.systemImage)
                .lineLimit(1)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(entry == .due ? Color.orange : Color.secondary)
            }
        }
        .tag(entry)
        .accessibilityIdentifier("task-filter-\(entry.raw)")
    }
}
