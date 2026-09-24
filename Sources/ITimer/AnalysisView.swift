import AppKit
import Charts
import ITimerCore
import SwiftUI
import UniformTypeIdentifiers

struct AnalysisView: View {
    var store: TaskStore
    @State private var range: AnalysisRange = .today

    var body: some View {
        let report = ReportCache.shared.report(store: store, range: range)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headline(report)
                    if report.unionActive <= 0 {
                        emptyState
                    } else {
                        chips(report)
                        concurrencyChart(report)
                        HStack(alignment: .top, spacing: 20) {
                            levelChart(report)
                            tagChart(report)
                        }
                        dayChart(report)
                        taskChart(report)
                        overlaps(report)
                        taskTable(report)
                    }
                    rules
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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

    // MARK: headline & chips

    private func headline(_ report: ParallelismReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(report.degree == .none ? report.verdict.title : report.degree.title)
                .font(.system(.title, design: .rounded).weight(.bold))
                .foregroundStyle(Theme.verdict(report.verdict))
            Text(headlineDetail(report))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func headlineDetail(_ report: ParallelismReport) -> String {
        if report.unionActive <= 0 { return "这个范围还没有计时" }
        let ratio = Int((report.brainSplitRatio * 100).rounded())
        return "峰值 \(report.maxConcurrency) · 脑裂 \(DurationFormat.prose(report.timeAtOrAboveThreshold)) / 活跃 \(DurationFormat.prose(report.unionActive)) · \(ratio)% · 切入 \(report.switchCount) 次"
    }

    private func chips(_ report: ParallelismReport) -> some View {
        let focus = report.slices.filter { $0.concurrency == 1 }.map(\.duration).max() ?? 0
        let split = report.slices.filter { $0.concurrency >= report.threshold }.map(\.duration).max() ?? 0
        let streak = StreakCache.shared.streak(store: store)
        return HStack(spacing: 10) {
            if focus > 0 { chip("最长专注", DurationFormat.prose(focus), tint: Theme.focused) }
            if split > 0 { chip("最长脑裂", DurationFormat.prose(split), tint: Theme.brainSplit) }
            if streak >= 2 { chip("连续专注", "\(streak) 天", tint: .orange) }
        }
    }

    private func chip(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .overlay {
            Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("还没有可绘制的统计")
                .font(.headline)
            Text("开始一个任务，这里会长出并行度、标签和每天的构成。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .cardSurface()
    }

    // MARK: charts

    private func concurrencyChart(_ report: ParallelismReport) -> some View {
        let active = report.slices.filter { $0.concurrency > 0 }
        return chartSection("并行度", caption: "横轴是时间，纵轴是同时在计时的任务数。") {
            Chart {
                ForEach(active) { slice in
                    BarMark(
                        xStart: .value("开始", slice.start),
                        xEnd: .value("结束", slice.end),
                        y: .value("并行度", slice.concurrency)
                    )
                    .foregroundStyle(by: .value("状态", band(slice.concurrency, threshold: report.threshold)))
                    .cornerRadius(2)
                }
                RuleMark(y: .value("脑裂线", report.threshold))
                    .foregroundStyle(Theme.brainSplit)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("脑裂线 \(report.threshold)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.brainSplit)
                    }
            }
            .chartForegroundStyleScale(Theme.bandScale)
            .chartYAxisLabel("并行度")
            .chartYScale(domain: 0...max(report.threshold + 1, report.maxConcurrency + 1))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
                        .foregroundStyle(Color.primary.opacity(0.12))
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.caption2)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
                        .foregroundStyle(Color.primary.opacity(0.12))
                    AxisValueLabel()
                        .font(.caption2)
                }
            }
            .frame(height: 190)
            .accessibilityLabel("并行度随时间变化，峰值 \(report.maxConcurrency)")
            .accessibilityIdentifier("concurrency-chart")
        }
    }

    private func levelChart(_ report: ParallelismReport) -> some View {
        let shares = ChartSeries.shares(of: report.slices)
        return chartSection("各级时长", caption: "每个并行度占用了多久。") {
            Chart(shares) { share in
                BarMark(
                    x: .value("并行度", "\(share.level)"),
                    y: .value("分钟", share.duration / 60)
                )
                .foregroundStyle(by: .value("状态", band(share.level, threshold: report.threshold)))
                .cornerRadius(4)
                .annotation(position: .top) {
                    Text(DurationFormat.prose(share.duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .chartForegroundStyleScale(Theme.bandScale)
            .chartLegend(.hidden)
            .chartYAxisLabel("分钟")
            .chartXAxisLabel("同时任务数")
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
                        .foregroundStyle(Color.primary.opacity(0.12))
                    AxisValueLabel()
                        .font(.caption2)
                }
            }
            .frame(height: 170)
            .accessibilityLabel("各级并行时长")
            .accessibilityIdentifier("share-chart")
        }
    }

    @ViewBuilder
    private func tagChart(_ report: ParallelismReport) -> some View {
        let slices = TagStats.slices(tasks: store.tasks, window: report.window, now: store.now)
        if slices.contains(where: { $0.tag != TagStats.untagged }) {
            chartSection("按标签", caption: "计时花在哪些类别上。") {
                HStack(spacing: 16) {
                    Chart(slices.prefix(8)) { slice in
                        SectorMark(
                            angle: .value("分钟", slice.duration),
                            innerRadius: .ratio(0.62),
                            angularInset: 1.5
                        )
                        .foregroundStyle(Theme.tag(slice.tag))
                        .cornerRadius(3)
                    }
                    .chartLegend(.hidden)
                    .frame(width: 150, height: 150)
                    .accessibilityIdentifier("tag-chart")
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(slices.prefix(5)) { slice in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Theme.tag(slice.tag))
                                    .frame(width: 7, height: 7)
                                Text(slice.tag)
                                    .lineLimit(1)
                                Spacer()
                                Text(DurationFormat.prose(slice.duration))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dayChart(_ report: ParallelismReport) -> some View {
        let days = ChartSeries.days(of: report.slices, window: report.window, threshold: report.threshold)
        if days.count > 1 {
            let rows = days.flatMap { day in
                [
                    DayBand(day: day.day, band: "专注", minutes: day.focused / 60),
                    DayBand(day: day.day, band: "并行", minutes: day.mild / 60),
                    DayBand(day: day.day, band: "脑裂", minutes: day.brainSplit / 60),
                ]
            }
            chartSection("按天构成", caption: "每天的活跃时间拆成专注、并行和脑裂。") {
                Chart(rows) { row in
                    BarMark(
                        x: .value("日期", row.day, unit: .day),
                        y: .value("分钟", row.minutes)
                    )
                    .foregroundStyle(by: .value("状态", row.band))
                    .cornerRadius(2)
                }
                .chartForegroundStyleScale(Theme.bandScale)
                .chartYAxisLabel("分钟")
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
                            .foregroundStyle(Color.primary.opacity(0.12))
                        AxisValueLabel()
                            .font(.caption2)
                    }
                }
                .frame(height: 170)
                .accessibilityLabel("按天的专注、并行和脑裂时长")
                .accessibilityIdentifier("day-chart")
            }
        }
    }

    private func taskChart(_ report: ParallelismReport) -> some View {
        let tasks = Array(report.tasks.prefix(8))
        return chartSection("任务耗时", caption: "这个范围内各任务计入的时间。") {
            Chart(tasks) { task in
                BarMark(
                    x: .value("分钟", task.duration / 60),
                    y: .value("任务", task.title)
                )
                .foregroundStyle(task.isRunning ? Color.accentColor : Color.primary.opacity(0.35))
                .cornerRadius(3)
                .annotation(position: .trailing) {
                    Text(DurationFormat.prose(task.duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .chartXAxisLabel("分钟")
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
                        .foregroundStyle(Color.primary.opacity(0.12))
                    AxisValueLabel()
                        .font(.caption2)
                }
            }
            .frame(height: CGFloat(max(tasks.count, 1)) * 28 + 24)
            .accessibilityLabel("任务耗时排行")
            .accessibilityIdentifier("task-chart")
        }
    }

    private func chartSection<Content: View>(_ title: String, caption: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
        .cardSurface()
    }

    // MARK: lists

    @ViewBuilder
    private func overlaps(_ report: ParallelismReport) -> some View {
        if !report.overlaps.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("同时进行")
                    .font(.headline)
                ForEach(report.overlaps.prefix(6)) { overlap in
                    HStack {
                        Text("\(overlap.titleA) × \(overlap.titleB)")
                            .lineLimit(1)
                        Spacer()
                        Text(DurationFormat.prose(overlap.duration))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            .cardSurface()
        }
    }

    private func taskTable(_ report: ParallelismReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("记录")
                .font(.headline)
            ForEach(report.tasks) { task in
                HStack(spacing: 8) {
                    Text(task.title)
                        .lineLimit(1)
                    statusBadge(task)
                    Spacer()
                    Text(DurationFormat.prose(task.duration))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if task.isRunning {
                        Button("完成") { store.complete(id: task.id) }
                            .controlSize(.small)
                    } else if task.isPaused {
                        Button("继续") { store.resume(id: task.id) }
                            .controlSize(.small)
                    }
                    Button("删除") { store.delete(id: task.id) }
                        .controlSize(.small)
                }
                .font(.callout)
            }
        }
        .cardSurface()
    }

    private func statusBadge(_ task: TaskStat) -> some View {
        let (title, color): (String, Color) = task.isRunning ? ("进行中", Theme.focused) : (task.isPaused ? ("暂停", .orange) : ("完成", .secondary))
        return Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
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
        return "并行度是同一时刻正在计时的任务数。暂停前的时段仍计入历史，当前已暂停的任务不再增加实时并行度。脑裂线当前 \(line)。活跃时间里达到脑裂线的占比 <15% 为短暂，≥15% 为达到，≥40% 或峰值 ≥\(line + 2) 为严重。"
    }

    private func band(_ concurrency: Int, threshold: Int) -> String {
        if concurrency >= threshold { return "脑裂" }
        if concurrency >= 2 { return "并行" }
        return "专注"
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

struct ThresholdControl: View {
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "brain")
                .foregroundStyle(Theme.brainSplit)
            Text("\(value)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .frame(minWidth: 14)
            stepperButton("minus") { value = max(BrainSplitRules.minimumThreshold, value - 1) }
            stepperButton("plus") { value = min(BrainSplitRules.maximumThreshold, value + 1) }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .overlay {
            Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .help("脑裂线：同时计时达到这个数量算脑裂")
    }

    private func stepperButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .frame(width: 16, height: 16)
                .contentShape(Circle())
                .background(Color.primary.opacity(0.07), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct DayBand: Identifiable {
    var day: Date
    var band: String
    var minutes: Double
    var id: String { "\(day.timeIntervalSinceReferenceDate)-\(band)" }
}
