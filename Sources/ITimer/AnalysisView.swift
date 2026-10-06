import AppKit
import ITimerCore
import SwiftUI
import UniformTypeIdentifiers

struct AnalysisView: View {
    var store: TaskStore
    @State private var range: AnalysisRange

    init(store: TaskStore, range: AnalysisRange = .today) {
        self.store = store
        _range = State(initialValue: range)
    }

    var body: some View {
        let digest = DigestCache.shared.digest(store: store, range: range)
        let report = digest.report
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SummaryCard(digest: digest)
                if report.unionActive <= 0 {
                    emptyState
                } else {
                    insights(digest.insights)
                    if range == .today {
                        LaneChartCard(lanes: digest.lanes, splits: digest.splitIntervals, threshold: report.threshold)
                        LoadChartCard(
                            slices: report.slices,
                            lanes: digest.lanes,
                            threshold: report.threshold,
                            maxConcurrency: report.maxConcurrency
                        )
                    } else {
                        TrendChartCard(days: digest.dayScores)
                        if digest.days.count > 1 {
                            DayChartCard(days: digest.days)
                        }
                    }
                    HStack(alignment: .top, spacing: 16) {
                        HourChartCard(hours: digest.hours)
                        LevelChartCard(shares: ChartSeries.shares(of: report.slices), threshold: report.threshold)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        TagChartCard(slices: digest.tags)
                        OverlapCard(overlaps: report.overlaps)
                    }
                    RecordsCard(tasks: report.tasks, store: store)
                }
                rules
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
        .animation(.easeInOut(duration: 0.25), value: range)
        .accessibilityIdentifier("analysis-window")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("范围", selection: $range) {
                    ForEach(AnalysisRange.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                .accessibilityIdentifier("range-picker")
            }
            ToolbarItem(placement: .primaryAction) {
                ThresholdControl(value: thresholdBinding)
                    .accessibilityIdentifier("threshold-stepper")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { exportCSV() } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("导出当前范围为 CSV")
                .accessibilityIdentifier("export-csv")
            }
        }
    }

    private var thresholdBinding: Binding<Int> {
        Binding(get: { store.brainSplitThreshold }, set: { store.setThreshold($0) })
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("还没有可绘制的统计")
                .font(.headline)
            Text("开始一个任务，这里会长出线程泳道、专注度和每天的构成。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .cardSurface()
    }

    @ViewBuilder
    private func insights(_ items: [Insight]) -> some View {
        if !items.isEmpty {
            // 4 cards read better as 2×2 than 3 + 1.
            let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: items.count == 4 ? 2 : min(items.count, 3))
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(items) { item in
                    InsightCard(insight: item)
                }
            }
            .accessibilityIdentifier("insights")
        }
    }

    private var rules: some View {
        Text(ruleText)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .accessibilityIdentifier("brain-split-rules")
    }

    private var ruleText: String {
        let line = store.brainSplitThreshold
        return "并行度是同一时刻正在计时的任务数，每开一个新线程时已有任务在跑，就记一次上下文切换。脑裂线当前 \(line)；活跃时间里达到脑裂线的占比 <15% 为短暂，≥15% 为达到，≥40% 或峰值 ≥\(line + 2) 为严重。专注度 = 单核时间全额 + 并行时间 55% + 脑裂时间 15%，再按每小时切换次数扣分（最多 15 分）。对比基准：今天对昨天同一时段，7 天对前 7 天，30 天对前 30 天。"
    }

    // MARK: export

    private func exportCSV() {
        let window = range.window(asOf: store.now, tasks: store.tasks)
        let iso = ISO8601DateFormatter()
        var lines = ["任务,标签,开始,结束,秒"]
        for task in store.tasks {
            for segment in task.segments {
                guard let clipped = segment.clipped(to: window, asOf: store.now) else { continue }
                let title = "\"" + task.title.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                let tags = "\"" + task.tags.joined(separator: " ") + "\""
                lines.append("\(title),\(tags),\(iso.string(from: clipped.start)),\(iso.string(from: clipped.end)),\(Int(clipped.duration))")
            }
        }
        guard lines.count > 1 else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "itimer.csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Summary

struct SummaryCard: View {
    var digest: AnalysisDigest

    var body: some View {
        let report = digest.report
        let range = digest.range
        HStack(alignment: .center, spacing: 24) {
            VStack(spacing: 8) {
                ScoreRing(score: digest.score)
                if let score = digest.score, let previous = digest.previousScore {
                    DeltaBadge(
                        text: "较\(range.previousTitle) \(signed(score - previous))",
                        delta: Double(score - previous),
                        goodWhenUp: true
                    )
                    .help("\(range.previousTitle)专注度 \(previous)")
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(report.degree == .none ? report.verdict.title : report.degree.title)
                            .font(.system(.title, design: .rounded).weight(.bold))
                            .foregroundStyle(Theme.verdict(report.verdict))
                        Text(windowCaption(report.window))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Text(digest.score.map { FocusScore.tier(for: $0).tagline } ?? "这个范围还没有计时")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if report.unionActive > 0 {
                    tiles
                }
            }
            Spacer(minLength: 0)
        }
        .cardSurface(padding: 20)
        .accessibilityIdentifier("analysis-summary")
    }

    private var tiles: some View {
        let report = digest.report
        let previous = digest.previous
        let bands = digest.bands
        return HStack(spacing: 10) {
            StatTile(
                label: "活跃",
                value: DurationFormat.prose(report.unionActive),
                tint: .primary,
                delta: previous.map { report.unionActive - $0.unionActive },
                deltaText: { signedDuration($0) },
                goodWhenUp: nil,
                help: "至少有一个任务在计时的墙钟时间。并行的时间只算一次。"
            )
            StatTile(
                label: "单核",
                value: DurationFormat.prose(bands.focused),
                tint: Theme.focused,
                delta: digest.previousBands.map { bands.focused - $0.focused },
                deltaText: { signedDuration($0) },
                goodWhenUp: true,
                help: "只有一个任务在计时的时间，一次只做一件事。"
            )
            StatTile(
                label: "脑裂",
                value: "\(Int((report.brainSplitRatio * 100).rounded()))%",
                tint: report.timeAtOrAboveThreshold > 0 ? Theme.brainSplit : .secondary,
                delta: previous.map { (report.brainSplitRatio - $0.brainSplitRatio) * 100 },
                deltaText: { "\(signed(Int($0.rounded()))) 个点" },
                goodWhenUp: false,
                help: "活跃时间里，同时计时数达到脑裂线（\(report.threshold)）的占比。脑裂共 \(DurationFormat.prose(report.timeAtOrAboveThreshold))。"
            )
            StatTile(
                label: "上下文切换",
                value: "\(report.switchCount) 次",
                tint: .primary,
                delta: previous.map { Double(report.switchCount - $0.switchCount) },
                deltaText: { "\(signed(Int($0))) 次" },
                goodWhenUp: false,
                help: "已有任务在计时的时候，又开了一个新线程的次数。"
            )
            StatTile(
                label: "峰值线程",
                value: "\(report.maxConcurrency)",
                tint: Theme.bandColor(report.maxConcurrency, threshold: report.threshold),
                delta: previous.map { Double(report.maxConcurrency - $0.maxConcurrency) },
                deltaText: { signed(Int($0)) },
                goodWhenUp: false,
                help: "同一时刻最多有几个任务在计时。"
            )
        }
    }

    private func windowCaption(_ window: DateInterval) -> String {
        let calendar = Calendar.current
        let end = window.end
        switch digest.range {
        case .today:
            return "今天 \(window.start.formatted(.dateTime.hour().minute())) – \(end.formatted(.dateTime.hour().minute()))"
        default:
            let sameYear = calendar.component(.year, from: window.start) == calendar.component(.year, from: end)
            let format: Date.FormatStyle = sameYear ? .dateTime.month().day() : .dateTime.year().month().day()
            return "\(window.start.formatted(format)) – \(end.formatted(format))"
        }
    }
}

private func signed(_ value: Int) -> String {
    value > 0 ? "+\(value)" : "\(value)"
}

private func signedDuration(_ value: TimeInterval) -> String {
    (value >= 0 ? "+" : "−") + DurationFormat.prose(abs(value))
}

/// Metric tile with an optional change vs the previous period. Hover
/// reveals the definition.
struct StatTile: View {
    var label: String
    var value: String
    var tint: Color
    var delta: Double?
    var deltaText: (Double) -> String
    /// nil = neither direction is better (e.g. total active time).
    var goodWhenUp: Bool?
    var help: String
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Text(label)
                Image(systemName: "info.circle")
                    .opacity(hovering ? 1 : 0)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
            if let delta {
                DeltaText(text: abs(delta) < 0.5 ? "持平" : deltaText(delta), delta: delta, goodWhenUp: goodWhenUp)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 88, alignment: .leading)
        .background(
            Color.primary.opacity(hovering ? 0.07 : 0.04),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(hovering ? 0.1 : 0), lineWidth: 0.5)
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
        .help(help)
    }
}

private func deltaColor(_ delta: Double, goodWhenUp: Bool?) -> Color {
    guard let goodWhenUp, abs(delta) >= 0.5 else { return .secondary }
    return (delta > 0) == goodWhenUp ? Theme.focused : Theme.brainSplit
}

struct DeltaText: View {
    var text: String
    var delta: Double
    var goodWhenUp: Bool?

    var body: some View {
        HStack(spacing: 2) {
            if abs(delta) >= 0.5 {
                Image(systemName: delta > 0 ? "arrow.up" : "arrow.down")
                    .font(.system(size: 7, weight: .heavy))
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(deltaColor(delta, goodWhenUp: goodWhenUp))
    }
}

struct DeltaBadge: View {
    var text: String
    var delta: Double
    var goodWhenUp: Bool?

    var body: some View {
        let color = deltaColor(delta, goodWhenUp: goodWhenUp)
        DeltaText(text: text, delta: delta, goodWhenUp: goodWhenUp)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - Records

struct RecordsCard: View {
    var tasks: [TaskStat]
    var store: TaskStore
    @State private var showAll = false
    private let collapsedCount = 8

    var body: some View {
        let longest = tasks.first?.duration ?? 1
        let visible = showAll ? tasks : Array(tasks.prefix(collapsedCount))
        ChartCard(title: "记录", caption: "这个范围内每个任务计入的时间。右键可删除。", trailing: "\(tasks.count) 条") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(visible) { task in
                    RecordRow(task: task, longest: longest, store: store)
                    if task.id != visible.last?.id {
                        Divider().opacity(0.4)
                    }
                }
                if tasks.count > collapsedCount {
                    HStack {
                        Spacer()
                        Button(showAll ? "收起" : "显示全部 \(tasks.count) 条") {
                            withAnimation(.easeInOut(duration: 0.25)) { showAll.toggle() }
                        }
                        .buttonStyle(PillButtonStyle(tint: .secondary))
                        .accessibilityIdentifier("records-toggle")
                        Spacer()
                    }
                    .padding(.top, 10)
                }
            }
        }
        .accessibilityIdentifier("task-table")
    }
}

private struct RecordRow: View {
    var task: TaskStat
    var longest: TimeInterval
    var store: TaskStore
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            statusBadge
            HStack(spacing: 6) {
                Text(task.title)
                    .lineLimit(1)
                if let item = store.tasks.first(where: { $0.id == task.id }) {
                    if item.hasJournal {
                        Image(systemName: "text.bubble.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.focused)
                            .help(journalHint(item))
                    }
                }
            }
            .frame(minWidth: 120, alignment: .leading)
            GeometryReader { proxy in
                Capsule()
                    .fill(task.isRunning ? Theme.focused : Color.primary.opacity(hovering ? 0.3 : 0.18))
                    .frame(width: max(4, proxy.size.width * task.duration / longest), height: 6)
                    .frame(maxHeight: .infinity)
            }
            .frame(height: 18)
            Text(DurationFormat.prose(task.duration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .trailing)
            action
                .frame(width: 52)
        }
        .font(.callout)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.05 : 0))
        )
        .padding(.horizontal, -8)
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .contextMenu {
            Button("删除", role: .destructive) { store.delete(id: task.id) }
        }
    }

    private func journalHint(_ item: TaskItem) -> String {
        var parts: [String] = []
        if !item.note.isEmpty { parts.append(item.note) }
        if let latest = item.comments.last { parts.append(latest.text) }
        return parts.joined(separator: "\n")
    }

    @ViewBuilder
    private var action: some View {
        if task.isRunning {
            Button("完成") { store.complete(id: task.id) }
                .buttonStyle(PillButtonStyle(tint: Theme.focused))
        } else if task.isPaused {
            Button("继续") { store.resume(id: task.id) }
                .buttonStyle(PillButtonStyle(tint: Theme.mild))
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private var statusBadge: some View {
        let (title, color): (String, Color) = task.isRunning ? ("进行中", Theme.focused) : (task.isPaused ? ("暂停", .orange) : ("完成", .secondary))
        return Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .frame(width: 40)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - Insight

struct InsightCard: View {
    var insight: Insight

    var body: some View {
        let tint: Color = switch insight.tone {
        case .positive: Theme.focused
        case .neutral: .blue
        case .warning: Theme.mild
        }
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: insight.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(insight.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(insight.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
        .cardSurface(padding: 14)
        .overlay(alignment: .leading) {
            // Tone stripe.
            Capsule()
                .fill(tint)
                .frame(width: 3)
                .padding(.vertical, 14)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("insight-\(insight.id)")
    }
}

// MARK: - Threshold

struct ThresholdControl: View {
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "brain")
                .foregroundStyle(Theme.brainSplit)
            Text("\(value)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
                .frame(minWidth: 14)
            stepperButton("minus", enabled: value > BrainSplitRules.minimumThreshold) {
                value = max(BrainSplitRules.minimumThreshold, value - 1)
            }
            stepperButton("plus", enabled: value < BrainSplitRules.maximumThreshold) {
                value = min(BrainSplitRules.maximumThreshold, value + 1)
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .overlay {
            Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .animation(.snappy, value: value)
        .help("脑裂线：同时计时达到这个数量算脑裂")
    }

    private func stepperButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(HoverButtonStyle(
            shape: .circle,
            tint: Theme.brainSplit,
            rest: 0.07,
            hover: 0.2,
            hoverScale: 1.12,
            restForeground: .primary,
            hoverForeground: Theme.brainSplit
        ))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}
