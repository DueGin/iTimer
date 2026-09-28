import ITimerCore
import SwiftUI

/// Values being edited in the composer. `editingID` nil = new schedule.
struct ScheduleDraft: Equatable {
    var editingID: UUID?
    var title: String = ""
    /// Start can only change before the item has been started.
    var startEditable = true
    var start: Date
    var duration: TimeInterval? = ScheduleOptions.defaultDuration
    var reminderLead: TimeInterval? = ScheduleOptions.defaultReminderLead

    static func new(title: String = "", asOf now: Date) -> ScheduleDraft {
        ScheduleDraft(title: title, start: ScheduleOptions.suggestedStart(after: now))
    }

    static func editing(_ task: TaskItem, asOf now: Date) -> ScheduleDraft {
        ScheduleDraft(
            editingID: task.id,
            title: task.title,
            startEditable: task.isPending,
            start: task.scheduledStart ?? now,
            duration: task.plannedDuration,
            reminderLead: task.reminderLead
        )
    }

    var titleValid: Bool {
        !TitleParser.parse(title.trimmingCharacters(in: .whitespacesAndNewlines)).title.isEmpty
    }
}

/// Inline form for creating or editing a schedule. Deliberately built from
/// plain buttons and a field-style time picker: popover/menu pickers steal
/// focus and make the MenuBarExtra panel dismiss itself.
struct ScheduleComposer: View {
    @Binding var draft: ScheduleDraft
    var now: Date
    var onSave: () -> Void
    var onStartNow: () -> Void
    var onCancel: () -> Void
    @FocusState private var titleFocused: Bool

    private var calendar: Calendar { .current }
    private var isNew: Bool { draft.editingID == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(isNew ? "新建日程" : "编辑日程")
                    .font(.headline)
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("schedule-cancel")
            }
            titleField
            form
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("schedule-summary")
            actions
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("schedule-composer")
        .onAppear {
            DispatchQueue.main.async { titleFocused = true }
        }
    }

    // MARK: title

    private var titleField: some View {
        TextField("日程名称，结尾可加 #标签", text: $draft.title)
            .textFieldStyle(.plain)
            .font(.title3)
            .focused($titleFocused)
            .onSubmit { if draft.titleValid { onSave() } }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(titleFocused ? Theme.focused.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: 1)
            }
            .accessibilityIdentifier("schedule-title")
    }

    // MARK: form

    private var form: some View {
        VStack(spacing: 0) {
            if draft.startEditable {
                row("日期") { dayStepper }
                divider
                row("时间") { timeControls }
                divider
            }
            row("预计") {
                SegmentBar(
                    options: ScheduleOptions.durations.map { (Self.shortDuration($0), Optional($0)) } + [("不定", nil)],
                    selection: $draft.duration
                )
                .accessibilityIdentifier("schedule-duration")
            }
            divider
            row("提醒") {
                SegmentBar(
                    options: ScheduleOptions.reminderLeads.map { (Self.shortReminder($0), $0) },
                    selection: $draft.reminderLead
                )
                .accessibilityIdentifier("schedule-reminder")
            }
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private var divider: some View {
        Divider().padding(.leading, 52)
    }

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 38)
    }

    private var dayStepper: some View {
        HStack(spacing: 4) {
            StepButton(systemImage: "chevron.left", help: "前一天") { shiftDay(-1) }
                .disabled(calendar.isDate(draft.start, inSameDayAs: now) || draft.start < now)
            HStack(spacing: 5) {
                Text(draft.start, format: .dateTime.month(.defaultDigits).day().weekday(.abbreviated))
                    .monospacedDigit()
                if let relative = relativeDay {
                    Text(relative)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.focused)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.focused.opacity(0.12), in: Capsule())
                }
            }
            .font(.callout)
            .frame(minWidth: 118)
            StepButton(systemImage: "chevron.right", help: "后一天") { shiftDay(1) }
        }
        .accessibilityIdentifier("schedule-day")
    }

    private var timeControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                timeStepper
                quickTimes([nil, 9, 14, 20])
            }
            HStack(spacing: 8) {
                timeStepper
                quickTimes([nil])
            }
            timeStepper
        }
    }

    private var timeStepper: some View {
        HStack(spacing: 4) {
            StepButton(systemImage: "minus", help: "提前 15 分钟") { draft.start = draft.start.addingTimeInterval(-15 * 60) }
            DatePicker("时间", selection: $draft.start, displayedComponents: .hourAndMinute)
                .datePickerStyle(.field)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("schedule-start")
            StepButton(systemImage: "plus", help: "推后 15 分钟") { draft.start = draft.start.addingTimeInterval(15 * 60) }
        }
    }

    /// nil = now; otherwise the next occurrence of that hour on the chosen day.
    private func quickTimes(_ hours: [Int?]) -> some View {
        HStack(spacing: 4) {
            ForEach(hours, id: \.self) { hour in
                let label = hour.map { "\($0):00" } ?? "现在"
                Button {
                    if let hour { setHour(hour) } else { draft.start = now }
                } label: {
                    Text(label)
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
    }

    // MARK: actions

    private var actions: some View {
        HStack(spacing: 8) {
            if isNew {
                Button(action: onStartNow) {
                    Label("现在就开始", systemImage: "play.fill")
                }
                .buttonStyle(ActionButtonStyle())
                .disabled(!draft.titleValid)
                .help("跳过排期，按这个预计时长立即计时")
                .accessibilityIdentifier("schedule-start-now")
            }
            Spacer()
            Button(action: onSave) {
                Label(isNew ? "添加日程" : "保存", systemImage: isNew ? "plus" : "checkmark")
            }
            .buttonStyle(ActionButtonStyle(prominent: true))
            .disabled(!draft.titleValid)
            .accessibilityIdentifier("schedule-save")
        }
    }

    // MARK: derived

    private var relativeDay: String? {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: draft.start)
        switch calendar.dateComponents([.day], from: today, to: day).day {
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        default: return nil
        }
    }

    private var summary: String {
        var parts: [String] = []
        if draft.startEditable {
            let start = TaskRow.timeLabel(draft.start, now: now)
            if let duration = draft.duration {
                let end = TaskRow.timeLabel(draft.start.addingTimeInterval(duration), now: now, forceTime: true)
                parts.append("\(start) – \(end)")
            } else {
                parts.append("\(start) 开始")
            }
        } else {
            parts.append("已开始计时")
            if let duration = draft.duration { parts.append("预计\(DurationFormat.prose(duration))") }
        }
        if let lead = draft.reminderLead {
            parts.append(lead <= 0 ? "准时提醒" : "提前\(DurationFormat.prose(lead))提醒")
        } else {
            parts.append("不提醒")
        }
        return parts.joined(separator: " · ")
    }

    private func shiftDay(_ days: Int) {
        draft.start = calendar.date(byAdding: .day, value: days, to: draft.start) ?? draft.start
    }

    private func setHour(_ hour: Int) {
        var target = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: draft.start) ?? draft.start
        if target < now, let next = calendar.date(byAdding: .day, value: 1, to: target) {
            target = next
        }
        draft.start = target
    }

    static func shortDuration(_ value: TimeInterval) -> String {
        let minutes = Int(value / 60)
        if minutes < 60 { return "\(minutes)分" }
        if minutes % 60 == 0 { return "\(minutes / 60)时" }
        return String(format: "%.1f时", Double(minutes) / 60)
    }

    static func shortReminder(_ lead: TimeInterval?) -> String {
        guard let lead else { return "关" }
        if lead <= 0 { return "准时" }
        return "前" + shortDuration(lead)
    }
}

/// Small square icon button used for steppers.
private struct StepButton: View {
    var systemImage: String
    var help: String
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .frame(width: 22, height: 22)
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.4))
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Segmented control drawn by hand: the system one can't hold optional
/// values and looks heavy at this size.
struct SegmentBar<Value: Hashable>: View {
    var options: [(label: String, value: Value)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.caption.weight(selected ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
