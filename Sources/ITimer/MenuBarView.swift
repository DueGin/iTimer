import AppKit
import ITimerCore
import SwiftUI

struct MenuBarView: View {
    var store: TaskStore
    var embedded = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var draft = ""
    @State private var editingID: UUID?
    @State private var renameDraft = ""
    @State private var latchedHeight: CGFloat?
    @State private var composer: ScheduleDraft?
    /// Brain buddy's speech; replaces the verdict line for a few seconds.
    @State private var quip: String?
    @State private var quipCount = 0
    @FocusState private var draftFocused: Bool

    var body: some View {
        // While the panel is open the status label is frozen and the store
        // clock stops (label changes dismiss the panel). Tick locally so the
        // panel's own timers stay live without touching the label.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: max(context.date, store.now))
        }
        .padding(embedded ? 18 : 16)
        // Height is latched while the panel is open: MenuBarExtra windows
        // resize unreliably mid-interaction (observed as broken layout after
        // completing a task). Recomputed next time the panel opens.
        .frame(width: embedded ? nil : 380, height: embedded ? nil : (latchedHeight ?? popupHeight))
        // The panel's material lets bright wallpapers wash out secondary
        // text; a partly opaque backing keeps times and labels legible.
        .background { if !embedded { Theme.canvas.opacity(0.72) } }
        .onAppear {
            guard !embedded else { return }
            latchedHeight = popupHeight
            // Start right away; the app clock loop keeps it in sync after.
            BuddyClock.panel.run(true)
            // Freeze immediately; the clock loop releases it within a second
            // of close (onDisappear is unreliable for MenuBarExtra).
            store.setStatusFrozen(true)
        }
        .onDisappear {
            if !embedded { latchedHeight = nil }
        }
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
            revealMain()
        }
        .onReceive(NotificationCenter.default.publisher(for: .iTimerFocusNewTask)) { _ in
            draftFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .iTimerNewSchedule)) { note in
            // Popup and sidebar both listen; only the addressed one opens,
            // or focusing the other window's field dismisses the panel.
            guard (note.object as? Bool ?? false) == embedded else { return }
            openComposer()
        }
        .onReceive(NotificationCenter.default.publisher(for: .iTimerPanelClosed)) { _ in
            // Reopening the panel should show the list, not a stale form.
            guard !embedded else { return }
            composer = nil
            // onDisappear rarely fires here, so release the latch now or the
            // next open keeps a stale height (e.g. after adding schedules).
            latchedHeight = nil
        }
    }

    private func content(now: Date) -> some View {
        let today = ReportCache.shared.report(store: store, range: .today)
        return VStack(alignment: .leading, spacing: 14) {
            header(today: today)
            if let lastError = store.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if composer != nil {
                // Takes the hero + list + input space so the latched popup
                // height never has to grow while the panel is open.
                ScrollView {
                    ScheduleComposer(
                        draft: composerBinding,
                        now: now,
                        onSave: saveComposer,
                        onStartNow: startComposerNow,
                        onCancel: { composer = nil }
                    )
                    .padding(1)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                hero(now: now, today: today)
                taskList(now: now)
                VStack(alignment: .leading, spacing: 8) {
                    newTaskRow
                    suggestionRow
                }
            }
            footer
        }
    }

    // MARK: sizing

    /// MenuBarExtra windows do not grow past their ideal height, and a
    /// compressed ScrollView swallows all but the last task. Size explicitly;
    /// the list takes whatever is left inside the latched frame.
    private var popupHeight: CGFloat {
        let groups = [store.dueSchedules, store.runningTasks, store.pausedTasks, store.upcomingSchedules]
        let open = groups.reduce(0) { $0 + $1.count }
        let done = store.completedToday().count
        let sections = groups.filter { !$0.isEmpty }.count + (done == 0 ? 0 : 1)
        let rows = CGFloat(open) * 58 + CGFloat(done) * 34 + CGFloat(sections) * 30
        let listHeight: CGFloat = open + done == 0 ? 58 : min(rows, 380)
        let suggestions: CGFloat = store.suggestions(limit: 1).isEmpty ? 0 : 32
        let note: CGFloat = heroNote(now: store.now) == nil ? 0 : 18
        // The floor leaves room for the schedule composer, which replaces
        // hero + list without resizing the panel.
        return max(366 + listHeight + suggestions + note, 500)
    }

    // MARK: header

    private func header(today: ParallelismReport) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(store.now, format: .dateTime.weekday(.wide).month().day())
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary.opacity(0.8))
            Spacer()
            let streak = StreakCache.shared.streak(store: store)
            if streak >= 2 {
                Label("\(streak) 天", systemImage: "flame.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .help("连续 \(streak) 天单核专注满 \(Int(Streaks.dailySoloMinimum / 60)) 分钟")
                    .accessibilityLabel("连续专注 \(streak) 天")
            }
            soloGoal(today: today)
        }
    }

    /// Today's single-task minutes toward the streak minimum.
    private func soloGoal(today: ParallelismReport) -> some View {
        let solo = BandTotals.of(today.slices, threshold: today.threshold).focused
        let goal = Streaks.dailySoloMinimum
        let progress = min(1, solo / goal)
        return HStack(spacing: 5) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Theme.focused, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 11, height: 11)
            Text(progress >= 1 ? "今日单核达标" : "单核 \(Int(solo / 60))/\(Int(goal / 60)) 分")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help("今天一次只做一件事的时间。每天满 \(Int(goal / 60)) 分钟，连续天数 +1。")
        .accessibilityIdentifier("solo-goal")
    }

    // MARK: hero

    private func hero(now: Date, today: ParallelismReport) -> some View {
        let running = store.runningTasks
        let lead = running.max { $0.duration(asOf: now) < $1.duration(asOf: now) }
        let color = Theme.load(running.count, threshold: store.brainSplitThreshold)
        let active = today.unionActive

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                PulseDot(color: running.isEmpty ? .secondary : color, active: !running.isEmpty)
                Text(quip ?? playfulVerdict(running: running.count))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(running.isEmpty && quip == nil ? .secondary : color)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .accessibilityIdentifier("hero-verdict")
                Spacer()
                ThreadMeter(running: running.count, threshold: store.brainSplitThreshold)
            }
            HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(DurationFormat.clock(lead?.duration(asOf: now) ?? active))
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(running.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                Text(lead.map { "「\($0.title)」" + (running.count > 1 ? " 等 \(running.count) 件" : "") } ?? "今日活跃合计")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.75))
                    .lineLimit(1)
                if let note = heroNote(now: now) {
                    Label(note.text, systemImage: note.warn ? "exclamationmark.circle.fill" : "calendar")
                        .font(.caption.weight(note.warn ? .semibold : .regular))
                        .foregroundStyle(note.warn ? Color.orange : Color.secondary)
                        .lineLimit(1)
                        .padding(.top, 2)
                        .accessibilityIdentifier("hero-note")
                }
            }
            Spacer(minLength: 0)
            brainBuddy(running: running, lead: lead, color: color)
            }
            if let window = ribbonWindow(today: today, now: now) {
                VStack(spacing: 4) {
                    LoadRibbon(slices: today.slices, window: window, threshold: today.threshold)
                    HStack {
                        Text(window.start, format: .dateTime.hour().minute())
                        Spacer()
                        Text("今日活跃 \(DurationFormat.prose(active))")
                        Text("·")
                        Text("专注度 \(FocusScore.score(report: today).map(String.init) ?? "–")")
                            .foregroundStyle(FocusScore.score(report: today).map { Theme.tier(FocusScore.tier(for: $0)) } ?? .secondary)
                    }
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.primary.opacity(0.7))
                    .accessibilityIdentifier("today-total")
                }
            }
        }
        .padding(14)
        .background {
            Theme.card.fill(
                LinearGradient(
                    colors: [color.opacity(running.isEmpty ? 0.04 : 0.16), color.opacity(0.03)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        .overlay {
            Theme.card.strokeBorder(color.opacity(running.isEmpty ? 0.08 : 0.25), lineWidth: 0.5)
        }
        .animation(.easeInOut(duration: 0.3), value: running.count)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("hero-timer")
    }

    private func brainBuddy(running: [TaskItem], lead: TaskItem?, color: Color) -> some View {
        VStack(spacing: 4) {
            BrainBuddy(
                running: running.count,
                threshold: store.brainSplitThreshold,
                tint: running.isEmpty ? Color(nsColor: .systemGray) : color,
                clock: embedded ? .window : .panel,
                onPoke: { say(Self.quip(running: running.count, threshold: store.brainSplitThreshold, index: quipCount)) }
            )
            if running.count >= 2, let lead {
                Button {
                    store.focus(id: lead.id)
                    say("合体成功，专心搞「\(lead.title)」")
                } label: {
                    Label("只留一个", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(PillButtonStyle(tint: color))
                .help("只留「\(lead.title)」计时，其余先暂停")
                .accessibilityIdentifier("brain-merge")
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private func say(_ text: String) {
        quipCount += 1
        let token = quipCount
        withAnimation(.easeOut(duration: 0.2)) { quip = text }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard quipCount == token else { return }
            withAnimation(.easeIn(duration: 0.3)) { quip = nil }
        }
    }

    static func quip(running: Int, threshold: Int, index: Int) -> String {
        let lines: [String]
        switch ParallelismAnalyzer.liveVerdict(runningCount: running, threshold: threshold) {
        case .idle:
            lines = ["zZ… 充电中，勿扰", "空空如也，其实挺好", "戳我也没用，先开个任务"]
        case .focused:
            lines = ["单核满速，稳如老狗", "心无旁骛，继续保持", "别戳了，专心呢", "一次只做一件事，赢麻了"]
        case .mild:
            lines = ["左脑：我先！右脑：不，我先！", "两个念头在打架", "再开一个我就裂给你看", "勉强撑得住…吧"]
        case .brainSplit:
            lines = [
                "我现在是 \(running) 个我",
                "\(running) 块脑子，各想各的",
                "谁来把我粘回去…",
                "多线程？不，是多裂缝",
                "每块都觉得自己最重要",
                "点「只留一个」救救我",
            ]
        }
        return lines[index % lines.count]
    }

    /// Plan context under the big clock: overtime first (timing keeps going
    /// past the estimate), then what's left, then what's due or next.
    private func heroNote(now: Date) -> (text: String, warn: Bool)? {
        let running = store.runningTasks
        if let over = running.filter({ $0.isOvertime(asOf: now) }).max(by: { $0.overtime(asOf: now) < $1.overtime(asOf: now) }) {
            return ("「\(over.title)」超出预计 \(DurationFormat.prose(over.overtime(asOf: now)))，计时继续", true)
        }
        let due = store.tasks.filter { $0.isDue(asOf: now) }
        if !due.isEmpty {
            return (due.count == 1 ? "「\(due[0].title)」到点了，点开始才计时" : "\(due.count) 个日程到点待开始", true)
        }
        if running.count == 1, let remaining = running[0].remaining(asOf: now) {
            return ("预计还剩 \(DurationFormat.prose(remaining))", false)
        }
        if let next = store.upcomingSchedules.first, let start = next.scheduledStart {
            return ("下一个日程 \(TaskRow.timeLabel(start, now: now)) \(next.title)", false)
        }
        return nil
    }

    /// From the first active hour today to now (at least one hour wide).
    private func ribbonWindow(today: ParallelismReport, now: Date) -> DateInterval? {
        guard let first = today.slices.first(where: { $0.concurrency > 0 })?.start else { return nil }
        let calendar = Calendar.current
        let hour = calendar.dateInterval(of: .hour, for: first)?.start ?? first
        let start = min(hour, now.addingTimeInterval(-3600))
        return DateInterval(start: start, end: max(now, store.now))
    }

    private func playfulVerdict(running: Int) -> String {
        let threshold = store.brainSplitThreshold
        switch ParallelismAnalyzer.liveVerdict(runningCount: running, threshold: threshold) {
        case .idle: return "空闲 · 歇着也是恢复"
        case .focused: return "单核运转中"
        case .mild:
            let room = threshold - running
            return room == 1 ? "左右脑互搏 · 再开一个就脑裂" : "左右脑互搏"
        case .brainSplit: return "脑子裂成 \(running) 瓣"
        }
    }

    // MARK: tasks

    @ViewBuilder
    private func taskList(now: Date) -> some View {
        let done = store.completedToday()
        let pending = store.tasks.filter(\.isPending)
        let due = pending.filter { $0.isDue(asOf: now) }.sorted { ($0.scheduledStart ?? $0.createdAt) < ($1.scheduledStart ?? $1.createdAt) }
        let upcoming = pending.filter { !$0.isDue(asOf: now) && !$0.isUndated }.sorted { ($0.scheduledStart ?? $0.createdAt) < ($1.scheduledStart ?? $1.createdAt) }
        let undated = store.undatedSchedules
        if store.runningTasks.isEmpty && store.pausedTasks.isEmpty && pending.isEmpty && done.isEmpty {
            Text("没有人生的计时是白费的——输入任务回车立即计时，或点「日程」安排未来的事。加个 @分类 或 #标签，统计会帮你归类。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8)
                .frame(maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    // Due first — they are waiting on the user — then what
                    // is timing, what is parked, and what is still ahead.
                    if !due.isEmpty {
                        sectionTitle("到点待开始", count: due.count, tint: .orange)
                        ForEach(due) { task in row(task, now: now) }
                    }
                    if !store.runningTasks.isEmpty {
                        sectionTitle("进行中", count: store.runningTasks.count)
                        ForEach(store.runningTasks) { task in row(task, now: now) }
                    }
                    if !store.pausedTasks.isEmpty {
                        sectionTitle("已暂停", count: store.pausedTasks.count)
                        ForEach(store.pausedTasks) { task in row(task, now: now) }
                    }
                    if !upcoming.isEmpty {
                        sectionTitle("接下来", count: upcoming.count)
                        ForEach(upcoming) { task in row(task, now: now) }
                    }
                    if !undated.isEmpty {
                        sectionTitle("时间待定", count: undated.count)
                        ForEach(undated) { task in row(task, now: now) }
                    }
                    if !done.isEmpty {
                        sectionTitle("今日完成", count: done.count)
                        ForEach(done) { task in
                            DoneRow(task: task, store: store)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .contentMargins(.bottom, 12, for: .scrollContent)
            .mask(EdgeFade(edge: .bottom))
            // Fills whatever the latched panel height leaves; scrolls beyond.
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func row(_ task: TaskItem, now: Date) -> some View {
        TaskRow(
            task: task,
            store: store,
            now: now,
            editingID: $editingID,
            renameDraft: $renameDraft,
            onEdit: { composer = .editing(task, asOf: now) }
        )
    }

    private func sectionTitle(_ title: String, count: Int, tint: Color? = nil) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            Text("\(count)")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(tint ?? .secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background((tint ?? .primary).opacity(0.1), in: Capsule())
        }
        .font(.caption.weight(.semibold))
        .padding(.top, 8)
        .padding(.bottom, 2)
        .padding(.horizontal, 4)
    }

    // MARK: new task

    private var newTaskRow: some View {
        let running = store.runningCount
        let warn = running + 1 >= store.brainSplitThreshold && running > 0
        return HStack(spacing: 8) {
            Image(systemName: warn ? "exclamationmark.triangle.fill" : "plus.circle.fill")
                .foregroundStyle(warn ? Theme.brainSplit : .secondary)
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .focused($draftFocused)
                .onSubmit(startDraft)
                .accessibilityIdentifier("new-task-field")
            if !draft.isEmpty {
                Text("↩︎")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            Button(action: openComposer) {
                Label("日程", systemImage: "calendar.badge.plus")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(PillButtonStyle(tint: Theme.focused))
            .fixedSize()
            .help("排个日程：设定时间、预计时长和提醒；已输入的文字会作为名称")
            .accessibilityIdentifier("new-schedule")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    warn && draftFocused ? Theme.brainSplit.opacity(0.5) : Color.primary.opacity(draftFocused ? 0.25 : 0.07),
                    lineWidth: 1
                )
        }
    }

    /// The placeholder doubles as a gentle guard rail against opening yet
    /// another thread.
    private var placeholder: String {
        let running = store.runningCount
        let threshold = store.brainSplitThreshold
        if running == 0 { return "现在专注做什么？可加 @分类 #标签" }
        if running >= threshold { return "已经脑裂了，真的还要再开一个？" }
        if running + 1 == threshold { return "再开一个就到脑裂线了…" }
        return "再开一个线程？"
    }

    /// While the last word is `@…` or `#…`, the row offers matching
    /// categories or tags instead of recent tasks.
    private var completions: (prefix: String, options: [String])? {
        guard let last = draft.split(separator: " ", omittingEmptySubsequences: false).last,
              let marker = last.first, marker == "@" || marker == "#" else { return nil }
        let typed = last.dropFirst().lowercased()
        let pool = marker == "@" ? store.categories.map(\.name) : store.knownTags
        let options = pool.filter { typed.isEmpty || ($0.lowercased().hasPrefix(typed) && $0.lowercased() != typed) }
        return (String(marker), Array(options.prefix(8)))
    }

    private func complete(_ marker: String, _ option: String) {
        var words = draft.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        words.removeLast()
        draft = (words + [marker + option]).joined(separator: " ") + " "
        draftFocused = true
    }

    @ViewBuilder
    private var suggestionRow: some View {
        if let completions, !completions.options.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: completions.prefix == "@" ? "folder" : "number")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(completions.options, id: \.self) { option in
                            let color = completions.prefix == "@" ? Theme.category(option) : Theme.tag(option)
                            Button { complete(completions.prefix, option) } label: {
                                Text(completions.prefix + option)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                            }
                            .buttonStyle(HoverButtonStyle(
                                shape: .capsule,
                                tint: color,
                                rest: 0.1,
                                hover: 0.22,
                                restForeground: color,
                                hoverForeground: color,
                                padding: EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8)
                            ))
                        }
                    }
                }
                .scrollIndicators(.never)
                .mask(EdgeFade(edge: .trailing))
            }
            .frame(height: 22)
            .accessibilityIdentifier("label-completions")
        } else if !store.suggestions(limit: 1).isEmpty {
            let matches = store.suggestions(matching: draft, limit: 6)
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .help("最近做过的事，点一下直接开始")
                if matches.isEmpty {
                    Text(draft.isEmpty ? "" : "回车开始「\(draft)」")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(matches, id: \.self) { suggestion in
                                Button {
                                    if store.addTask(title: suggestion) != nil { draft = "" }
                                } label: {
                                    Label(suggestion, systemImage: "play.fill")
                                        .labelStyle(ChipLabelStyle())
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                                .buttonStyle(HoverButtonStyle(
                                    shape: .capsule,
                                    tint: Theme.focused,
                                    rest: 0.07,
                                    hover: 0.18,
                                    restForeground: .primary,
                                    hoverForeground: Theme.focused,
                                    padding: EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8)
                                ))
                                .help("开始「\(suggestion)」")
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .mask(EdgeFade(edge: .trailing))
                }
            }
            .frame(height: 22)
            .accessibilityIdentifier("suggestions")
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 4) {
            if !embedded {
                footerButton("打开 iTimer", systemImage: "chart.bar.xaxis", id: "open-analysis") { revealMain() }
            }
            footerButton("设置", systemImage: "gearshape", id: "open-settings") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            Spacer()
            if !embedded {
                footerButton("退出", systemImage: "power", id: "quit-app") { NSApp.terminate(nil) }
            }
        }
        .padding(.horizontal, -8)
    }

    private func footerButton(_ title: String, systemImage: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
        }
        .buttonStyle(HoverButtonStyle(
            shape: .capsule,
            hover: 0.08,
            restForeground: .secondary,
            hoverForeground: .primary,
            padding: EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        ))
        .accessibilityIdentifier(id)
    }

    private func startDraft() {
        guard store.addTask(title: draft) != nil else { return }
        draft = ""
        editingID = nil
    }

    /// Whatever is typed in the quick field becomes the schedule's name.
    private func openComposer() {
        composer = .new(title: draft, asOf: store.now)
        draft = ""
        editingID = nil
    }

    private var composerBinding: Binding<ScheduleDraft> {
        Binding(
            get: { composer ?? .new(asOf: store.now) },
            set: { composer = $0 }
        )
    }

    private func saveComposer() {
        guard let value = composer, value.titleValid else { return }
        let labels = value.resolved
        if let id = value.editingID {
            if store.tasks.first(where: { $0.id == id })?.title != labels.title {
                store.rename(id: id, title: labels.title)
            }
            store.setTags(id: id, labels.tags)
            store.setCategory(id: id, labels.category)
            store.updateSchedule(id: id, start: value.scheduledStart, plannedDuration: value.duration, reminderLead: value.reminderLead)
        } else {
            guard store.addSchedule(
                title: value.title,
                tags: value.tags,
                category: value.category,
                start: value.scheduledStart,
                plannedDuration: value.duration,
                reminderLead: value.reminderLead
            ) != nil else { return }
        }
        composer = nil
    }

    /// Same as adding, but timing starts right away instead of at a set time.
    private func startComposerNow() {
        guard let value = composer,
              let task = store.addSchedule(
                  title: value.title,
                  tags: value.tags,
                  category: value.category,
                  start: store.now,
                  plannedDuration: value.duration,
                  reminderLead: value.reminderLead
              ) else { return }
        store.resume(id: task.id)
        composer = nil
    }

    private func revealMain() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct TaskRow: View {
    var task: TaskItem
    var store: TaskStore
    var now: Date
    @Binding var editingID: UUID?
    @Binding var renameDraft: String
    /// Opens the schedule composer for this item (time, estimate, reminder).
    var onEdit: () -> Void = {}
    @State private var hovering = false
    @State private var deleteArmed = false

    private var editing: Bool { editingID == task.id }
    private var isDue: Bool { task.isDue(asOf: now) }
    private var isOvertime: Bool { task.isOvertime(asOf: now) }

    /// Single-core mode makes sense when something else is also running.
    private var canFocus: Bool {
        !task.isPending && store.runningTasks.contains { $0.id != task.id }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            primaryButton
            VStack(alignment: .leading, spacing: 3) {
                if editing {
                    TextField("任务名 @分类 #标签", text: $renameDraft)
                        .textFieldStyle(.plain)
                        .onSubmit(commitRename)
                        .onExitCommand { editingID = nil }
                        .accessibilityIdentifier("rename-field-\(task.id.uuidString)")
                } else {
                    Text(task.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .onTapGesture(count: 2, perform: beginRename)
                }
                HStack(spacing: 5) {
                    if let category = task.category {
                        CategoryPill(name: category)
                    }
                    ForEach(task.tags, id: \.self) { tag in
                        TagPill(tag: tag)
                    }
                    Text(subtitle)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(subtitleWarns ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                if let planned = task.plannedDuration, !task.isPending {
                    PlanBar(progress: task.duration(asOf: now) / planned, overtime: isOvertime, running: task.isRunning)
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                trailingLabel
                actions
                    .opacity(hovering || editing || deleteArmed ? 1 : 0.6)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isDue ? Color.orange.opacity(hovering ? 0.12 : 0.07) : Color.primary.opacity(hovering ? 0.05 : 0))
        )
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) {
                hovering = inside
            }
        }
        .contextMenu { menuItems }
        .task(id: deleteArmed) {
            guard deleteArmed else { return }
            try? await Task.sleep(for: .seconds(3))
            deleteArmed = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-row-\(task.id.uuidString)")
    }

    @ViewBuilder
    private var trailingLabel: some View {
        if task.isUndated {
            Text("待定")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
        } else if task.isPending {
            Text(Self.timeLabel(task.scheduledStart ?? task.createdAt, now: now))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isDue ? Color.orange : Color.secondary)
        } else {
            Text(DurationFormat.clock(task.duration(asOf: now)))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isOvertime ? Color.orange : (task.isRunning ? Color.primary : Color.secondary))
        }
    }

    private var subtitleWarns: Bool { isDue || isOvertime }

    private var subtitle: String {
        if task.isPending { return pendingSummary }
        let clock = Date.FormatStyle(date: .omitted, time: .shortened)
        var parts: [String] = []
        if task.isRunning, let start = task.currentStart {
            parts.append("\(start.formatted(clock)) 起")
        } else if let paused = task.segments.last?.endedAt {
            parts.append("暂停于 \(paused.formatted(clock))")
        } else {
            parts.append("已暂停")
        }
        if let planned = task.plannedDuration {
            parts.append(isOvertime
                ? "超时 +\(DurationFormat.prose(task.overtime(asOf: now)))"
                : "预计 \(DurationFormat.prose(planned))")
        }
        return parts.joined(separator: " · ")
    }

    private var pendingSummary: String {
        var parts: [String] = []
        if task.isUndated {
            parts.append("时间待定")
            if let planned = task.plannedDuration { parts.append("预计 \(DurationFormat.prose(planned))") }
            return parts.joined(separator: " · ")
        }
        if isDue, let start = task.scheduledStart {
            let late = now.timeIntervalSince(start)
            parts.append(late >= 60 ? "已到点 \(DurationFormat.prose(late))" : "到点了")
        }
        if let planned = task.plannedDuration {
            let end = (task.scheduledStart ?? now).addingTimeInterval(planned)
            parts.append("预计 \(DurationFormat.prose(planned))" + (isDue ? "" : "，至 \(Self.timeLabel(end, now: now, forceTime: true))"))
        }
        if !isDue, let lead = task.reminderLead {
            parts.append(lead <= 0 ? "准时提醒" : "提前\(DurationFormat.prose(lead))提醒")
        }
        return parts.isEmpty ? "日程" : parts.joined(separator: " · ")
    }

    /// "14:00" today, "明天 14:00", otherwise "9月30日 14:00".
    static func timeLabel(_ date: Date, now: Date, forceTime: Bool = false, calendar: Calendar = .current) -> String {
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if forceTime || calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "明天 \(time)"
        }
        return date.formatted(.dateTime.month(.defaultDigits).day()) + " " + time
    }

    private var primaryButton: some View {
        let tint: Color = task.isPending ? (isDue ? .orange : Theme.focused) : (task.isRunning ? Theme.focused : Color.secondary)
        let title = task.isPending ? "开始计时" : (task.isRunning ? "暂停" : "继续")
        let identifier = task.isPending
            ? "start-\(task.id.uuidString)"
            : (task.isRunning ? "pause-\(task.id.uuidString)" : "resume-\(task.id.uuidString)")
        return Button {
            if task.isRunning { store.pause(id: task.id) } else { store.resume(id: task.id) }
        } label: {
            Image(systemName: task.isRunning ? "pause.fill" : "play.fill")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 26, height: 26)
                .overlay {
                    if task.isRunning || isDue {
                        Circle().strokeBorder(tint.opacity(0.35), lineWidth: 0.5)
                    }
                }
        }
        .buttonStyle(HoverButtonStyle(
            shape: .circle,
            tint: task.isRunning || task.isPending ? tint : Theme.focused,
            rest: task.isRunning || isDue ? 0.16 : 0.1,
            hover: 0.28,
            hoverScale: 1.1,
            restForeground: tint,
            hoverForeground: task.isRunning || task.isPending ? tint : Theme.focused
        ))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    private var actions: some View {
        HStack(spacing: 0) {
            if canFocus {
                IconButton(title: "只做这个（暂停其他）", systemImage: "scope", tint: Theme.focused, identifier: "focus-\(task.id.uuidString)") {
                    store.focus(id: task.id)
                }
            }
            if task.isPending {
                if isDue {
                    IconButton(title: "推迟 10 分钟", systemImage: "clock.arrow.circlepath", tint: .orange, identifier: "postpone-\(task.id.uuidString)") {
                        store.postpone(id: task.id, by: 10 * 60)
                    }
                }
            } else {
                IconButton(title: "完成", systemImage: "checkmark", identifier: "complete-\(task.id.uuidString)") {
                    store.complete(id: task.id)
                }
            }
            if editing {
                IconButton(title: "保存", systemImage: "checkmark.circle", identifier: "rename-\(task.id.uuidString)") {
                    commitRename()
                }
            } else {
                IconButton(
                    title: task.isUndated ? "编辑：定个时间、预计时长、分类" : task.isPending ? "编辑：名称、时间、预计时长、提醒、分类" : "编辑：名称、预计时长、提醒、分类",
                    systemImage: "slider.horizontal.3",
                    identifier: "edit-schedule-\(task.id.uuidString)",
                    action: onEdit
                )
            }
            IconButton(
                title: deleteArmed ? "再点一次删除" : "删除",
                systemImage: deleteArmed ? "trash.fill" : "trash",
                tint: deleteArmed ? .red : .primary,
                identifier: "delete-\(task.id.uuidString)"
            ) {
                if deleteArmed {
                    store.delete(id: task.id)
                } else {
                    deleteArmed = true
                }
            }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if task.isPending {
            Button("开始计时") { store.resume(id: task.id) }
            if !task.isUndated {
                Button("推迟 10 分钟") { store.postpone(id: task.id, by: 10 * 60) }
            }
        } else {
            if canFocus {
                Button("只做这个（暂停其他）") { store.focus(id: task.id) }
            }
            if task.isRunning {
                Button("暂停") { store.pause(id: task.id) }
            } else {
                Button("继续") { store.resume(id: task.id) }
            }
            Button("完成") { store.complete(id: task.id) }
        }
        Divider()
        LabelMenus(task: task, store: store, onEditLabels: beginLabelEdit)
        Divider()
        Button(task.isPending ? "编辑日程…" : "编辑预计与提醒…", action: onEdit)
        Button("改名", action: beginRename)
        Button("删除", role: .destructive) { store.delete(id: task.id) }
    }

    /// The inline field edits title, category and tags together, in the
    /// same "写周报 @工作 #汇报" form as the quick field.
    private func beginRename() {
        editingID = task.id
        renameDraft = TaskStore.input(for: task)
    }

    /// Same field, cursor ready for a new tag.
    private func beginLabelEdit() {
        editingID = task.id
        renameDraft = TaskStore.input(for: task) + " #"
    }

    private func commitRename() {
        if store.retitle(id: task.id, input: renameDraft) {
            editingID = nil
        }
    }
}

/// Thin progress line against the estimate; past 100% it turns orange and
/// shows how far over, since timing keeps running beyond the plan.
private struct PlanBar: View {
    var progress: Double
    var overtime: Bool
    var running: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if overtime {
                    // Planned share in the focus color, the overrun in orange.
                    let planned = width / max(progress, 1)
                    Capsule().fill(Color.orange.opacity(running ? 0.9 : 0.55))
                    Capsule().fill(Theme.focused.opacity(running ? 0.9 : 0.5)).frame(width: planned)
                } else {
                    Capsule().fill(Theme.focused.opacity(running ? 0.9 : 0.5)).frame(width: width * max(0, progress))
                }
            }
        }
        .frame(height: 3)
        .frame(maxWidth: 180)
        .accessibilityHidden(true)
    }
}

/// Compact row for a task finished today.
struct DoneRow: View {
    var task: TaskItem
    var store: TaskStore
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Theme.focused.opacity(0.8))
                .frame(width: 26)
            Text(task.title)
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.7))
                .lineLimit(1)
            if let category = task.category {
                Circle()
                    .fill(Theme.category(category))
                    .frame(width: 6, height: 6)
                    .help(category)
            }
            Spacer(minLength: 6)
            Text(DurationFormat.prose(task.duration(asOf: store.now)))
                .font(.callout.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
            IconButton(title: "再来一段", systemImage: "arrow.counterclockwise", identifier: "again-\(task.id.uuidString)") {
                store.resume(id: task.id)
            }
            .opacity(hovering ? 1 : 0.6)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.05 : 0))
        )
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
        .contextMenu {
            Button("再来一段") { store.resume(id: task.id) }
            Divider()
            LabelMenus(task: task, store: store, onEditLabels: nil)
            Divider()
            Button("删除", role: .destructive) { store.delete(id: task.id) }
        }
        .accessibilityIdentifier("done-row-\(task.id.uuidString)")
    }
}

/// Soft fade on one edge so scrolled-off content reads as "more", not "cut".
struct EdgeFade: View {
    var edge: Edge
    var length: CGFloat = 16

    var body: some View {
        let vertical = edge == .bottom || edge == .top
        let stops: [Gradient.Stop] = [.init(color: .black, location: 0), .init(color: .clear, location: 1)]
        ZStack {
            if vertical {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom).frame(height: length)
                }
            } else {
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing).frame(width: length)
                }
            }
        }
    }
}

/// Chip label whose leading icon only appears on hover ("tap to start").
struct ChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChipLabel(configuration: configuration)
    }

    private struct ChipLabel: View {
        var configuration: LabelStyleConfiguration
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 4) {
                if hovering {
                    configuration.icon
                        .font(.system(size: 7, weight: .bold))
                        .transition(.scale.combined(with: .opacity))
                }
                configuration.title
            }
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
            }
        }
    }
}
