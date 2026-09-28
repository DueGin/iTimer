import ITimerCore
import SwiftUI

/// Values being edited in the composer. `editingID` nil = new schedule.
struct ScheduleDraft: Equatable {
    var editingID: UUID?
    var title: String = ""
    /// Start can only change before the item has been started.
    var startEditable = true
    var start: Date
    /// false = time to be decided (时间待定); `start` is kept so switching
    /// back restores the last picked slot.
    var hasTime = true
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
            start: task.scheduledStart ?? (task.isPending ? ScheduleOptions.suggestedStart(after: now) : now),
            hasTime: !task.isUndated,
            duration: task.plannedDuration,
            reminderLead: task.reminderLead ?? (task.isUndated ? ScheduleOptions.defaultReminderLead : nil)
        )
    }

    /// What to store: nil while the time is still to be decided.
    var scheduledStart: Date? { hasTime ? start : nil }

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
    /// Inline day list. Not a Menu/Picker: those take focus and the
    /// MenuBarExtra panel closes under them.
    @State var dayListOpen = false

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
                if dayListOpen {
                    dayList
                }
                divider
                if draft.hasTime {
                    row("时间") { timeControls }
                    divider
                }
            }
            row("预计") {
                SegmentBar(
                    options: ScheduleOptions.durations.map { (Self.shortDuration($0), Optional($0)) } + [("不定", nil)],
                    selection: $draft.duration
                )
                .accessibilityIdentifier("schedule-duration")
            }
            if draft.hasTime || !draft.startEditable {
                divider
                row("提醒") {
                    SegmentBar(
                        options: ScheduleOptions.reminderLeads.map { (Self.shortReminder($0), $0) },
                        selection: $draft.reminderLead
                    )
                    .accessibilityIdentifier("schedule-reminder")
                }
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
                .disabled(!draft.hasTime || calendar.isDate(draft.start, inSameDayAs: now) || draft.start < now)
            Button {
                withAnimation(.easeOut(duration: 0.15)) { dayListOpen.toggle() }
            } label: {
                HStack(spacing: 5) {
                    if draft.hasTime {
                        Text(draft.start, format: .dateTime.month(.defaultDigits).day().weekday(.abbreviated))
                            .monospacedDigit()
                        if let relative = relativeDay {
                            badge(relative)
                        }
                    } else {
                        Text("时间待定")
                        badge("先记下")
                    }
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(dayListOpen ? 180 : 0))
                }
                .font(.callout)
                .padding(.horizontal, 7)
                .frame(minWidth: 128, minHeight: 22)
                .background(Color.primary.opacity(dayListOpen ? 0.1 : 0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("选择日期，或先不定时间")
            .accessibilityIdentifier("schedule-day-menu")
            StepButton(systemImage: "chevron.right", help: "后一天") { shiftDay(1) }
        }
        .accessibilityIdentifier("schedule-day")
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.focused)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Theme.focused.opacity(0.12), in: Capsule())
    }

    /// Dropdown body: 待定 plus the next two weeks.
    private var dayList: some View {
        let today = calendar.startOfDay(for: now)
        let days = (0..<14).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
            dayChip(title: "待定", subtitle: "先不定时间", selected: !draft.hasTime) { pickUndated() }
                .accessibilityIdentifier("schedule-day-undated")
            ForEach(days, id: \.self) { day in
                dayChip(
                    title: Self.dayName(day, today: today, calendar: calendar),
                    subtitle: day.formatted(.dateTime.month(.defaultDigits).day()),
                    selected: draft.hasTime && calendar.isDate(draft.start, inSameDayAs: day)
                ) { pick(day) }
            }
        }
        .padding(.leading, 52)
        .padding(.trailing, 12)
        .padding(.bottom, 8)
        .transition(.opacity)
        .accessibilityIdentifier("schedule-day-list")
    }

    private func dayChip(title: String, subtitle: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(title)
                    .font(.caption.weight(selected ? .semibold : .medium))
                Text(subtitle)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(selected ? Theme.focused : Color.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .foregroundStyle(selected ? Theme.focused : Color.primary)
            .background(
                selected ? Theme.focused.opacity(0.14) : Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 今天 / 明天 / 后天, then the weekday.
    static func dayName(_ day: Date, today: Date, calendar: Calendar = .current) -> String {
        switch calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: day)).day {
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        default: return day.formatted(.dateTime.weekday(.abbreviated))
        }
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
        if draft.startEditable && !draft.hasTime {
            parts.append("时间待定，想好了再排")
            if let duration = draft.duration { parts.append("预计\(DurationFormat.prose(duration))") }
            parts.append("不提醒")
            return parts.joined(separator: " · ")
        }
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
        guard draft.hasTime else {
            pick(calendar.startOfDay(for: now))
            return
        }
        draft.start = calendar.date(byAdding: .day, value: days, to: draft.start) ?? draft.start
    }

    /// Move to `day`, keeping the picked time of day; a slot already past
    /// today becomes the next sensible start.
    private func pick(_ day: Date) {
        let time = calendar.dateComponents([.hour, .minute], from: draft.start)
        var target = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: day) ?? day
        if target < now { target = ScheduleOptions.suggestedStart(after: now) }
        draft.start = target
        draft.hasTime = true
        withAnimation(.easeOut(duration: 0.15)) { dayListOpen = false }
    }

    private func pickUndated() {
        draft.hasTime = false
        withAnimation(.easeOut(duration: 0.15)) { dayListOpen = false }
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
