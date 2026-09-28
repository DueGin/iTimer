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
    var tags: [String] = []
    var category: String?

    /// `title` may carry `#标签 @分类` from the quick field; they move into
    /// the pickers.
    static func new(title: String = "", asOf now: Date) -> ScheduleDraft {
        let parsed = TitleParser.parse(title)
        return ScheduleDraft(
            title: parsed.title,
            start: ScheduleOptions.suggestedStart(after: now),
            tags: parsed.tags,
            category: parsed.category
        )
    }

    static func editing(_ task: TaskItem, asOf now: Date) -> ScheduleDraft {
        ScheduleDraft(
            editingID: task.id,
            title: task.title,
            startEditable: task.isPending,
            start: task.scheduledStart ?? (task.isPending ? ScheduleOptions.suggestedStart(after: now) : now),
            hasTime: !task.isUndated,
            duration: task.plannedDuration,
            reminderLead: task.reminderLead ?? (task.isUndated ? ScheduleOptions.defaultReminderLead : nil),
            tags: task.tags,
            category: task.category
        )
    }

    /// What to store: nil while the time is still to be decided.
    var scheduledStart: Date? { hasTime ? start : nil }

    /// Title, tags and category with anything typed as `#`/`@` in the
    /// title folded in.
    var resolved: ParsedTitle {
        let parsed = TitleParser.parse(title.trimmingCharacters(in: .whitespacesAndNewlines))
        return ParsedTitle(
            title: parsed.title,
            tags: TitleParser.merge(tags, parsed.tags),
            category: parsed.category ?? category
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
    var categories: [TaskCategory] = TaskStore.shared.categories
    var knownTags: [String] = TaskStore.shared.knownTags
    @FocusState private var titleFocused: Bool
    /// Inline day list. Not a Menu/Picker: those take focus and the
    /// MenuBarExtra panel closes under them.
    @State var dayListOpen = false
    /// Month the dropdown calendar shows; nil = the picked day's month.
    @State private var shownMonth: Date?

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
        TextField("日程名称", text: $draft.title)
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
                row("日期") { dayRow }
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
            divider
            row("分类") {
                CategoryPicker(selection: $draft.category, categories: categories)
            }
            divider
            row("标签") {
                TagEditor(tags: $draft.tags, known: knownTags)
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

    /// Shortcuts laid out inline; the last button opens a month calendar
    /// for any other day and shows that day once picked.
    private var dayRow: some View {
        let today = calendar.startOfDay(for: now)
        let items = shortcuts(today: today)
        let custom = draft.hasTime && !items.contains { calendar.isDate(draft.start, inSameDayAs: $0.day) }
        return HStack(spacing: 4) {
            shortcut("待定", selected: !draft.hasTime) { pickUndated() }
                .help("先记下，不定日期和时间")
                .accessibilityIdentifier("schedule-day-undated")
            ForEach(items, id: \.title) { item in
                shortcut(item.title, selected: draft.hasTime && calendar.isDate(draft.start, inSameDayAs: item.day)) {
                    pick(item.day)
                }
                .help(item.day.formatted(.dateTime.month(.defaultDigits).day().weekday(.abbreviated)))
            }
            Button {
                shownMonth = nil
                withAnimation(.easeOut(duration: 0.15)) { dayListOpen.toggle() }
            } label: {
                HStack(spacing: 3) {
                    if custom {
                        Text(customDayLabel)
                            .monospacedDigit()
                    } else {
                        Image(systemName: "calendar")
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .rotationEffect(.degrees(dayListOpen ? 180 : 0))
                }
                .font(.caption.weight(custom ? .semibold : .medium))
                .foregroundStyle(custom ? Theme.focused : Color.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    custom ? Theme.focused.opacity(0.14) : Color.primary.opacity(dayListOpen ? 0.1 : 0.05),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("选择其他日期")
            .accessibilityIdentifier("schedule-day-menu")
        }
        .accessibilityIdentifier("schedule-day")
    }

    /// "10/8", or "2027/1/5" outside this year.
    private var customDayLabel: String {
        let parts = calendar.dateComponents([.year, .month, .day], from: draft.start)
        let short = "\(parts.month ?? 0)/\(parts.day ?? 0)"
        return calendar.isDate(draft.start, equalTo: now, toGranularity: .year) ? short : "\(parts.year ?? 0)/" + short
    }

    /// Dropdown body: a month calendar that pages to any future date.
    private var dayList: some View {
        let today = calendar.startOfDay(for: now)
        let month = shownMonth ?? Self.monthStart(draft.hasTime ? draft.start : now, calendar: calendar)
        return MonthGrid(
            month: month,
            today: today,
            selection: draft.hasTime ? draft.start : nil,
            calendar: calendar,
            onPage: { offset in
                shownMonth = calendar.date(byAdding: .month, value: offset, to: month).map { Self.monthStart($0, calendar: calendar) }
            },
            onPick: pick
        )
        .padding(.leading, 52)
        .padding(.trailing, 12)
        .padding(.bottom, 10)
        .transition(.opacity)
        .accessibilityIdentifier("schedule-day-list")
    }

    private func shortcuts(today: Date) -> [(title: String, day: Date)] {
        var items: [(String, Date)] = []
        for (offset, title) in [(0, "今天"), (1, "明天"), (2, "后天")] {
            if let day = calendar.date(byAdding: .day, value: offset, to: today) { items.append((title, day)) }
        }
        // Next Monday, at least three days out so it never repeats the above.
        if let monday = calendar.nextDate(
            after: calendar.date(byAdding: .day, value: 2, to: today) ?? today,
            matching: DateComponents(weekday: 2),
            matchingPolicy: .nextTime
        ) {
            items.append(("下周一", monday))
        }
        return items
    }

    private func shortcut(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(selected ? .semibold : .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(selected ? Theme.focused : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(
                    selected ? Theme.focused.opacity(0.14) : Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func monthStart(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
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

/// Month calendar drawn from plain buttons (a graphical DatePicker would
/// not match the panel and cannot grey out past days). Weeks start on the
/// system's first weekday.
private struct MonthGrid: View {
    var month: Date
    var today: Date
    var selection: Date?
    var calendar: Calendar
    var onPage: (Int) -> Void
    var onPick: (Date) -> Void

    private var days: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let lead = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        let dates = range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: month) }
        return Array(repeating: nil, count: lead) + dates
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var canGoBack: Bool {
        month > ScheduleComposer.monthStart(today, calendar: calendar)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(month, format: .dateTime.year().month(.wide))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Spacer()
                StepButton(systemImage: "chevron.left", help: "上个月") { onPage(-1) }
                    .disabled(!canGoBack)
                StepButton(systemImage: "chevron.right", help: "下个月") { onPage(1) }
            }
            .padding(.bottom, 2)
            let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        cell(day)
                    } else {
                        Color.clear.frame(height: 24)
                    }
                }
            }
        }
        .accessibilityIdentifier("schedule-month")
    }

    private func cell(_ day: Date) -> some View {
        let past = day < today
        let selected = selection.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let isToday = calendar.isDate(day, inSameDayAs: today)
        return Button { onPick(day) } label: {
            Text("\(calendar.component(.day, from: day))")
                .font(.caption.weight(selected || isToday ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(selected ? Color.white : (past ? Color.secondary.opacity(0.45) : (isToday ? Theme.focused : Color.primary)))
                .frame(maxWidth: .infinity, minHeight: 24)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.focused)
                    } else if isToday {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.focused.opacity(0.5), lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(past)
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
