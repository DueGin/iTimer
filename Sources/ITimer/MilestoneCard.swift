import ITimerCore
import SwiftUI

/// A milestone on a goal's roadmap: its workflow's name, what "reached"
/// means, how far its tasks have got, the time put in, and the target day.
/// Double-click opens the workflow.
struct MilestoneCard: View {
    var workflow: Workflow
    var summary: MilestoneSummary
    var goalID: UUID
    var store: TaskStore
    var selected: Bool
    /// Border while a line is dragged over this card: whether it can be wired.
    var linkHighlight: Color?
    var onSelect: () -> Void
    var onAddNext: () -> Void
    var onOpen: () -> Void
    @State private var hovering = false
    @State private var renaming = false
    @State private var draft = ""
    @State private var inspecting = false
    @FocusState private var renameFocused: Bool

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    private var id: String { workflow.id.uuidString }

    /// Orange is "waiting on you": clear to start, or done and awaiting a yes.
    private var stateColor: Color {
        switch summary.state {
        case .ready, .review: .orange
        case .active, .achieved: Theme.focused
        case .blocked: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Capsule()
                .fill(stateColor.opacity(0.75))
                .frame(width: 3)
                .padding(.vertical, 14)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 6) {
                    title
                    Spacer(minLength: 0)
                    if summary.state == .achieved {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.focused)
                            .help("已达成")
                    }
                }
                if !workflow.criteria.isEmpty {
                    Text(workflow.criteria)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.top, 2)
                        .help("完成标准：\(workflow.criteria)")
                }
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    stateChip
                    Spacer(minLength: 4)
                    dateText
                }
                HStack(spacing: 6) {
                    Text(progressText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    actions
                        .opacity(hovering || selected || summary.state == .review ? 1 : 0.6)
                }
                .padding(.top, 3)
            }
            .padding(.leading, 10)
            .padding(.trailing, 9)
            .padding(.vertical, 10)
        }
        .frame(width: CanvasLayout.goal.card.width, height: CanvasLayout.goal.card.height)
        .background(Theme.surface, in: shape)
        .background {
            if summary.running {
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
        .opacity(summary.state == .achieved ? 0.78 : 1)
        .contentShape(shape)
        // The title's own double-click (rename) wins over this one.
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture(perform: onSelect)
        .onHover { inside in
            // The open menu covers the card; a hover flip would rebuild it.
            guard !MenuTracking.isOpen else { return }
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
        .contextMenu { menu }
        .popover(isPresented: $inspecting, arrowEdge: .bottom) {
            MilestoneInspector(workflow: workflow, summary: summary, store: store)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("milestone-card-\(id)")
    }

    private var borderColor: Color {
        if let linkHighlight { return linkHighlight }
        if selected { return .accentColor }
        switch summary.state {
        case .active where summary.running: return Theme.focused.opacity(0.55)
        case .ready, .review: return Color.orange.opacity(0.45)
        default: return Color.primary.opacity(hovering ? 0.18 : 0.09)
        }
    }

    @ViewBuilder
    private var title: some View {
        if renaming {
            TextField("里程碑名称", text: $draft)
                .textFieldStyle(.plain)
                .font(.body.weight(.semibold))
                .focused($renameFocused)
                .onSubmit(commitRename)
                .onExitCommand { renaming = false }
                .onChange(of: renameFocused) { _, focused in
                    if !focused && renaming { commitRename() }
                }
                .accessibilityIdentifier("milestone-rename-\(id)")
        } else {
            Text(workflow.name)
                .font(.body.weight(.semibold))
                .lineLimit(2)
                .foregroundStyle(summary.state == .blocked ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .onTapGesture(count: 2, perform: beginRename)
        }
    }

    private var stateChip: some View {
        HStack(spacing: 4) {
            if summary.running {
                PulseDot(color: Theme.focused, active: true, size: 6)
            } else {
                Image(systemName: stateIcon)
            }
            Text(summary.state.title)
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(stateColor)
        .help(stateHelp)
    }

    private var stateIcon: String {
        switch summary.state {
        case .blocked: "hourglass"
        case .ready: "play.circle"
        case .active: "circle.lefthalf.filled"
        case .review: "questionmark.circle"
        case .achieved: "flag.checkered"
        }
    }

    private var stateHelp: String {
        switch summary.state {
        case .blocked:
            let names = summary.blockers.compactMap { store.workflow(id: $0)?.name }.map { "「\($0)」" }.joined(separator: "、")
            return "还在等 \(names) 达成"
        case .ready:
            return "上游都达成了，可以开始推进"
        case .active:
            return summary.running ? "有任务正在计时" : "已经开始推进"
        case .review:
            return "任务都做完了，达成了吗？"
        case .achieved:
            return "已达成"
        }
    }

    private var progressText: String {
        var parts = ["\(summary.done)/\(summary.total) 项"]
        if summary.invested >= 60 { parts.append(DurationFormat.prose(summary.invested)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var dateText: some View {
        if let achieved = workflow.achievedAt {
            Text(achieved, format: .dateTime.month().day())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("达成于这一天")
        } else if let days = summary.daysLeft {
            Text(days > 0 ? "还剩 \(days) 天" : days == 0 ? "今天到期" : "已逾期 \(-days) 天")
                .font(.caption.weight(days <= 0 ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(days < 0 ? Color.orange : days == 0 ? Color.orange : Color.secondary)
                .help(workflow.targetDate.map { "目标日期 \($0.formatted(.dateTime.year().month().day()))" } ?? "")
        }
    }

    @ViewBuilder
    private var actions: some View {
        if summary.state == .review {
            Button("标记达成") { store.setMilestoneAchieved(workflowID: workflow.id, true) }
                .buttonStyle(PillButtonStyle(tint: .orange))
                .help("任务都做完了，达成了吗？")
                .accessibilityIdentifier("milestone-achieve-\(id)")
        }
        IconButton(title: "目标日期与完成标准", systemImage: "calendar.badge.clock", identifier: "milestone-inspect-\(id)") {
            inspecting = true
        }
        IconButton(title: "打开工作流（双击卡片）", systemImage: "arrow.up.right.square", identifier: "milestone-open-\(id)", action: onOpen)
    }

    @ViewBuilder
    private var menu: some View {
        Button("打开工作流", action: onOpen)
        if workflow.achievedAt == nil {
            Button("标记达成") { store.setMilestoneAchieved(workflowID: workflow.id, true) }
        } else {
            Button("撤销达成") { store.setMilestoneAchieved(workflowID: workflow.id, false) }
        }
        Button("目标日期与完成标准…") { inspecting = true }
        Divider()
        Button("添加下一个里程碑", action: onAddNext)
        Button("改名", action: beginRename)
        Button("从目标移除") { store.removeMilestone(workflowID: workflow.id, from: goalID) }
    }

    private func beginRename() {
        draft = workflow.name
        renaming = true
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        if draft.trimmingCharacters(in: .whitespaces).isEmpty || store.renameWorkflow(id: workflow.id, to: draft) {
            renaming = false
        }
    }
}

/// Target day and success criteria for one milestone, plus what it took.
struct MilestoneInspector: View {
    var workflow: Workflow
    var summary: MilestoneSummary
    var store: TaskStore
    @State private var criteria: String
    @State private var hasDate: Bool
    @State private var date: Date

    init(workflow: Workflow, summary: MilestoneSummary, store: TaskStore) {
        self.workflow = workflow
        self.summary = summary
        self.store = store
        _criteria = State(initialValue: workflow.criteria)
        _hasDate = State(initialValue: workflow.targetDate != nil)
        _date = State(initialValue: workflow.targetDate ?? Calendar.current.date(byAdding: .day, value: 14, to: store.now) ?? store.now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(workflow.name)
                .font(.headline)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 4) {
                Text("完成标准")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $criteria)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 54, maxHeight: 90)
                    .padding(6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if criteria.isEmpty {
                            Text("怎样算达成？例如「10 个付费用户」")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityIdentifier("milestone-criteria")
            }
            Toggle("设定目标日期", isOn: $hasDate)
                .accessibilityIdentifier("milestone-has-date")
            if hasDate {
                DatePicker("目标日期", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.field)
                    .labelsHidden()
                    .accessibilityIdentifier("milestone-date")
            }
            Divider()
            LabeledContent("任务", value: "\(summary.done)/\(summary.total) 项完成")
            LabeledContent("投入", value: summary.invested >= 60 ? DurationFormat.prose(summary.invested) : "还没有计时")
            if let achieved = workflow.achievedAt {
                LabeledContent("达成于", value: achieved.formatted(.dateTime.year().month().day()))
            }
        }
        .font(.callout)
        .padding(14)
        .frame(width: 300)
        // Every save rewrites the data file, so wait for a pause in typing.
        .task(id: criteria) {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            store.setMilestoneCriteria(workflowID: workflow.id, criteria)
        }
        .onChange(of: hasDate) { _, on in
            store.setMilestoneTargetDate(workflowID: workflow.id, on ? date : nil)
        }
        .onChange(of: date) { _, new in
            if hasDate { store.setMilestoneTargetDate(workflowID: workflow.id, new) }
        }
        .onDisappear {
            store.setMilestoneCriteria(workflowID: workflow.id, criteria)
        }
    }
}
