import Charts
import ITimerCore
import SwiftUI

// MARK: - Shared chart chrome

/// Titled white card that every analysis section sits in.
struct ChartCard<Content: View>: View {
    var title: String
    var caption: String
    var trailing: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

/// Floating hover card for charts.
struct ChartTooltip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .fixedSize()
    }
}

/// "● 专注 1小时2分" line inside a tooltip.
struct TooltipRow: View {
    var color: Color
    var label: String
    var value: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .monospacedDigit()
        }
    }
}

extension View {
    /// Tracks the x-axis value under the pointer; nil once it leaves.
    func chartHoverX<Value: Plottable>(_ value: Binding<Value?>) -> some View {
        chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plot = proxy.plotFrame else { return }
                            let x = location.x - geometry[plot].origin.x
                            value.wrappedValue = proxy.value(atX: x, as: Value.self)
                        case .ended:
                            value.wrappedValue = nil
                        }
                    }
            }
        }
    }
}

private let clockStyle = Date.FormatStyle(date: .omitted, time: .shortened)

private var hoverAnnotation: AnnotationOverflowResolution { AnnotationOverflowResolution(x: .fit(to: .chart), y: .fit(to: .chart)) }

private var dashedGrid: some AxisContent {
    AxisMarks { _ in
        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
            .foregroundStyle(Color.primary.opacity(0.12))
        AxisValueLabel()
            .font(.caption2)
    }
}

private func timeAxis(format: Date.FormatStyle) -> some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
            .foregroundStyle(Color.primary.opacity(0.12))
        AxisValueLabel(format: format)
            .font(.caption2)
    }
}

/// One label per day for short ranges, thinned out for long ones.
private func dayAxis(count: Int) -> some AxisContent {
    let step = count <= 10 ? 1 : (count <= 35 ? 5 : 15)
    return AxisMarks(values: .stride(by: .day, count: step)) { _ in
        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
            .foregroundStyle(Color.primary.opacity(0.12))
        AxisValueLabel(format: .dateTime.month().day(), centered: true)
            .font(.caption2)
    }
}

private func activeLanes(_ lanes: [LaneSpan], at time: Date) -> [LaneSpan] {
    lanes.filter { $0.start <= time && $0.end > time }
}

/// Task list inside a tooltip, one colored dot per task.
private struct ActiveTaskList: View {
    var spans: [LaneSpan]

    var body: some View {
        ForEach(spans.prefix(5)) { span in
            HStack(spacing: 6) {
                Circle().fill(Theme.lane(span)).frame(width: 6, height: 6)
                Text(span.title).lineLimit(1)
            }
        }
        if spans.count > 5 {
            Text("还有 \(spans.count - 5) 个…").foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Lanes

/// Gantt-style: one lane per task, brain-split stretches shaded behind.
/// Hovering draws a time cursor and lists what was running then.
struct LaneChartCard: View {
    var lanes: [LaneSpan]
    var splits: [DateInterval]
    var threshold: Int
    @State private var hover: Date?

    /// `hover` seeds the cursor, for snapshot tests.
    init(lanes: [LaneSpan], splits: [DateInterval], threshold: Int, hover: Date? = nil) {
        self.lanes = lanes
        self.splits = splits
        self.threshold = threshold
        _hover = State(initialValue: hover)
    }

    var body: some View {
        let titles = Set(lanes.map(\.title)).count
        let active = hover.map { activeLanes(lanes, at: $0) } ?? []
        ChartCard(title: "线程泳道", caption: "每条泳道是一个任务，粉色底色是达到脑裂线的时段。悬停查看某一刻在做什么。") {
            Chart {
                ForEach(Array(splits.enumerated()), id: \.offset) { _, interval in
                    RectangleMark(
                        xStart: .value("开始", interval.start),
                        xEnd: .value("结束", interval.end)
                    )
                    .foregroundStyle(Theme.brainSplit.opacity(0.1))
                }
                ForEach(lanes) { span in
                    BarMark(
                        xStart: .value("开始", span.start),
                        xEnd: .value("结束", span.end),
                        y: .value("任务", span.title),
                        height: .fixed(14)
                    )
                    .foregroundStyle(Theme.lane(span).opacity(opacity(span, active: active)))
                    .cornerRadius(4)
                }
                if let hover {
                    RuleMark(x: .value("时间", hover))
                        .foregroundStyle(Color.primary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .trailing, alignment: .top, spacing: 8, overflowResolution: hoverAnnotation) {
                            ChartTooltip {
                                HStack(spacing: 6) {
                                    Text(hover, format: clockStyle).font(.caption.weight(.semibold))
                                    Text(active.isEmpty ? "空闲" : "\(active.count) 个线程")
                                        .foregroundStyle(active.isEmpty ? .secondary : Theme.bandColor(active.count, threshold: threshold))
                                }
                                ActiveTaskList(spans: active)
                            }
                        }
                }
            }
            .chartXAxis { timeAxis(format: .dateTime.hour().minute()) }
            .chartYAxis {
                AxisMarks(preset: .extended, position: .leading) { _ in
                    AxisValueLabel(centered: true)
                        .font(.caption)
                }
            }
            .chartHoverX($hover)
            .frame(height: CGFloat(max(titles, 1)) * 28 + 30)
            .accessibilityLabel("任务泳道图")
            .accessibilityIdentifier("lane-chart")
        }
    }

    private func opacity(_ span: LaneSpan, active: [LaneSpan]) -> Double {
        if hover != nil {
            return active.contains { $0.id == span.id } ? 1 : 0.25
        }
        return span.isRunning ? 1 : 0.8
    }
}

// MARK: - Load

struct LoadChartCard: View {
    var slices: [ConcurrencySlice]
    var lanes: [LaneSpan]
    var threshold: Int
    var maxConcurrency: Int
    @State private var hover: Date?

    var body: some View {
        let active = slices.filter { $0.concurrency > 0 }
        let level = hover.flatMap { time in slices.first { $0.start <= time && $0.end > time }?.concurrency } ?? 0
        ChartCard(title: "负载曲线", caption: "同一时刻在计时的任务数。越过虚线就是脑裂。") {
            Chart {
                ForEach(active) { slice in
                    loadMark(slice)
                }
                RuleMark(y: .value("脑裂线", threshold))
                    .foregroundStyle(Theme.brainSplit)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .trailing) {
                        Text("脑裂线 \(threshold)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.brainSplit)
                    }
                if let hover {
                    RuleMark(x: .value("时间", hover))
                        .foregroundStyle(Color.primary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .trailing, alignment: .top, spacing: 8, overflowResolution: hoverAnnotation) {
                            ChartTooltip {
                                HStack(spacing: 6) {
                                    Text(hover, format: clockStyle).font(.caption.weight(.semibold))
                                    Text(level == 0 ? "空闲" : "\(Theme.band(level, threshold: threshold)) · \(level)")
                                        .foregroundStyle(level == 0 ? .secondary : Theme.bandColor(level, threshold: threshold))
                                }
                                ActiveTaskList(spans: activeLanes(lanes, at: hover))
                            }
                        }
                }
            }
            .chartForegroundStyleScale(Theme.bandScale)
            .chartYScale(domain: 0...max(threshold + 1, maxConcurrency + 1))
            .chartXAxis { timeAxis(format: .dateTime.hour().minute()) }
            .chartYAxis { dashedGrid }
            .chartHoverX($hover)
            .frame(height: 170)
            .accessibilityLabel("并行度随时间变化，峰值 \(maxConcurrency)")
            .accessibilityIdentifier("concurrency-chart")
        }
    }

    private func loadMark(_ slice: ConcurrencySlice) -> some ChartContent {
        let floor: Int = 0
        let level: Int = slice.concurrency
        let band: String = Theme.band(level, threshold: threshold)
        let dimmed: Bool = hover != nil && !(slice.start <= hover! && slice.end > hover!)
        return RectangleMark(
            xStart: .value("开始", slice.start),
            xEnd: .value("结束", slice.end),
            yStart: .value("起", floor),
            yEnd: .value("并行度", level)
        )
        .foregroundStyle(by: .value("状态", band))
        .opacity(dimmed ? 0.45 : 1)
    }
}

// MARK: - Trend

/// Focus score per day, for multi-day ranges.
struct TrendChartCard: View {
    var days: [DayScore]
    @State private var hover: Date?

    /// `hover` seeds the cursor, for snapshot tests.
    init(days: [DayScore], hover: Date? = nil) {
        self.days = days
        _hover = State(initialValue: hover)
    }

    var body: some View {
        let scored = days.filter { $0.score != nil }
        let average = scored.isEmpty ? nil : scored.compactMap(\.score).reduce(0, +) / scored.count
        let selected = hover.flatMap(nearest(to:))
        ChartCard(
            title: "专注度趋势",
            caption: "每天一个分数，断开的地方是那天没有计时。",
            trailing: average.map { "平均 \($0)" }
        ) {
            Chart {
                if let average {
                    RuleMark(y: .value("平均", average))
                        .foregroundStyle(Color.primary.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                ForEach(runs()) { point in
                    AreaMark(
                        x: .value("日期", point.day.day, unit: .day),
                        y: .value("专注度", point.day.score ?? 0),
                        series: .value("段", point.run)
                    )
                    .foregroundStyle(LinearGradient(
                        colors: [Theme.focused.opacity(0.22), Theme.focused.opacity(0.01)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .interpolationMethod(.monotone)
                    LineMark(
                        x: .value("日期", point.day.day, unit: .day),
                        y: .value("专注度", point.day.score ?? 0),
                        series: .value("段", point.run)
                    )
                    .foregroundStyle(Theme.focused)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
                    PointMark(
                        x: .value("日期", point.day.day, unit: .day),
                        y: .value("专注度", point.day.score ?? 0)
                    )
                    .symbolSize(selected?.day == point.day.day ? 90 : 28)
                    .foregroundStyle(Theme.tier(FocusScore.tier(for: point.day.score ?? 0)))
                }
                if let selected, let score = selected.score {
                    RuleMark(x: .value("日期", selected.day, unit: .day))
                        .foregroundStyle(Color.primary.opacity(0.25))
                        .annotation(position: .trailing, alignment: .top, spacing: 8, overflowResolution: hoverAnnotation) {
                            ChartTooltip {
                                Text(selected.day, format: .dateTime.month().day().weekday())
                                    .font(.caption.weight(.semibold))
                                TooltipRow(color: Theme.tier(FocusScore.tier(for: score)), label: "专注度", value: "\(score) · \(FocusScore.tier(for: score).title)")
                                TooltipRow(color: .secondary, label: "活跃", value: DurationFormat.prose(selected.active))
                            }
                        }
                }
            }
            .chartYScale(domain: 0...100)
            .chartXScale(domain: xDomain)
            .chartXAxis { dayAxis(count: days.count) }
            .chartYAxis { dashedGrid }
            .chartHoverX($hover)
            .frame(height: 180)
            .accessibilityLabel("每日专注度趋势")
            .accessibilityIdentifier("trend-chart")
        }
    }

    private struct TrendPoint: Identifiable {
        var run: Int
        var day: DayScore
        var id: Date { day.day }
    }

    /// Scored days tagged with the index of their unbroken run, so the line
    /// breaks over days without any timing instead of bridging them.
    private func runs() -> [TrendPoint] {
        var result: [TrendPoint] = []
        var run = 0
        var previousScored = false
        for day in days {
            guard day.score != nil else {
                if previousScored { run += 1 }
                previousScored = false
                continue
            }
            result.append(TrendPoint(run: run, day: day))
            previousScored = true
        }
        return result
    }

    private var xDomain: ClosedRange<Date> {
        let calendar = Calendar.current
        let first = days.first?.day ?? Date()
        let last = days.last?.day ?? first
        let end = calendar.date(byAdding: .day, value: 1, to: last) ?? last
        return first...end
    }

    private func nearest(to date: Date) -> DayScore? {
        days.filter { $0.score != nil }.min { abs($0.day.timeIntervalSince(date)) < abs($1.day.timeIntervalSince(date)) }
    }
}

// MARK: - Days

struct DayChartCard: View {
    var days: [DayLoad]
    @State private var hover: Date?

    var body: some View {
        let calendar = Calendar.current
        let selectedDay = hover.map { calendar.startOfDay(for: $0) }
        let selected = selectedDay.flatMap { day in days.first { $0.day == day } }
        let rows = days.flatMap { day in
            [
                DayBand(day: day.day, band: "专注", minutes: day.focused / 60),
                DayBand(day: day.day, band: "并行", minutes: day.mild / 60),
                DayBand(day: day.day, band: "脑裂", minutes: day.brainSplit / 60),
            ]
        }
        ChartCard(title: "按天构成", caption: "每天的活跃时间拆成专注、并行和脑裂。") {
            Chart {
                ForEach(rows) { row in
                    BarMark(
                        x: .value("日期", row.day, unit: .day),
                        y: .value("分钟", row.minutes)
                    )
                    .foregroundStyle(by: .value("状态", row.band))
                    .opacity(selectedDay == nil || selectedDay == row.day ? 1 : 0.35)
                    .cornerRadius(2)
                }
                if let selected {
                    RuleMark(x: .value("日期", selected.day, unit: .day))
                        .foregroundStyle(.clear)
                        .annotation(position: .trailing, alignment: .top, spacing: 4, overflowResolution: hoverAnnotation) {
                            ChartTooltip {
                                Text(selected.day, format: .dateTime.month().day().weekday())
                                    .font(.caption.weight(.semibold))
                                TooltipRow(color: Theme.focused, label: "专注", value: DurationFormat.prose(selected.focused))
                                TooltipRow(color: Theme.mild, label: "并行", value: DurationFormat.prose(selected.mild))
                                TooltipRow(color: Theme.brainSplit, label: "脑裂", value: DurationFormat.prose(selected.brainSplit))
                            }
                        }
                }
            }
            .chartForegroundStyleScale(Theme.bandScale)
            .chartYAxisLabel("分钟")
            .chartXAxis { dayAxis(count: days.count) }
            .chartYAxis { dashedGrid }
            .chartHoverX($hover)
            .frame(height: 170)
            .accessibilityLabel("按天的专注、并行和脑裂时长")
            .accessibilityIdentifier("day-chart")
        }
    }
}

// MARK: - Hours

/// When in the day attention goes — folded onto 24 hours.
struct HourChartCard: View {
    var hours: [HourLoad]
    @State private var hover: String?

    var body: some View {
        let active = hours.filter { $0.total > 0 }.map(\.hour)
        let lower = max(0, (active.min() ?? 9) - 1)
        let upper = min(23, (active.max() ?? 18) + 1)
        let visible = hours.filter { $0.hour >= lower && $0.hour <= upper }
        let selected = hover.flatMap { key in visible.first { "\($0.hour)" == key } }
        let rows = visible.flatMap { load in
            [
                HourBand(hour: load.hour, band: "专注", minutes: load.focused / 60),
                HourBand(hour: load.hour, band: "并行", minutes: load.mild / 60),
                HourBand(hour: load.hour, band: "脑裂", minutes: load.brainSplit / 60),
            ]
        }
        ChartCard(title: "时段分布", caption: "一天里哪些钟点在专注，哪些在脑裂。") {
            Chart {
                ForEach(rows) { row in
                    BarMark(
                        x: .value("时", "\(row.hour)"),
                        y: .value("分钟", row.minutes),
                        width: .ratio(0.7)
                    )
                    .foregroundStyle(by: .value("状态", row.band))
                    .opacity(selected == nil || selected?.hour == row.hour ? 1 : 0.35)
                    .cornerRadius(2)
                }
                if let selected, selected.total > 0 {
                    RuleMark(x: .value("时", "\(selected.hour)"))
                        .foregroundStyle(.clear)
                        .annotation(position: .trailing, alignment: .top, spacing: 4, overflowResolution: hoverAnnotation) {
                            ChartTooltip {
                                Text("\(selected.hour):00 – \(selected.hour + 1):00")
                                    .font(.caption.weight(.semibold))
                                TooltipRow(color: Theme.focused, label: "专注", value: DurationFormat.prose(selected.focused))
                                TooltipRow(color: Theme.mild, label: "并行", value: DurationFormat.prose(selected.mild))
                                TooltipRow(color: Theme.brainSplit, label: "脑裂", value: DurationFormat.prose(selected.brainSplit))
                            }
                        }
                }
            }
            .chartForegroundStyleScale(Theme.bandScale)
            .chartLegend(.hidden)
            .chartXAxisLabel("点钟")
            .chartYAxis { dashedGrid }
            .chartHoverX($hover)
            .frame(height: 170)
            .accessibilityLabel("按钟点的专注、并行和脑裂时长")
            .accessibilityIdentifier("hour-chart")
        }
    }
}

// MARK: - Levels

struct LevelChartCard: View {
    var shares: [ConcurrencyShare]
    var threshold: Int
    @State private var hover: String?

    var body: some View {
        ChartCard(title: "各级时长", caption: "同时开 N 个线程，各持续了多久。") {
            Chart(shares) { share in
                BarMark(
                    x: .value("并行度", "\(share.level)"),
                    y: .value("分钟", share.duration / 60)
                )
                .foregroundStyle(by: .value("状态", Theme.band(share.level, threshold: threshold)))
                .opacity(hover == nil || hover == "\(share.level)" ? 1 : 0.35)
                .cornerRadius(4)
                .annotation(position: .top) {
                    Text(DurationFormat.prose(share.duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(hover == "\(share.level)" ? .primary : .secondary)
                }
            }
            .chartForegroundStyleScale(Theme.bandScale)
            .chartLegend(.hidden)
            .chartXAxisLabel("同时任务数")
            .chartYAxis { dashedGrid }
            .chartHoverX($hover)
            .frame(height: 170)
            .accessibilityLabel("各级并行时长")
            .accessibilityIdentifier("share-chart")
        }
    }
}

// MARK: - Tags

/// Donut of time per category or per tag.
struct TagChartCard: View {
    enum Kind {
        case category
        case tag

        var title: String { self == .category ? "按分类" : "按标签" }
        var placeholder: String { self == .category ? CategoryStats.uncategorized : TagStats.untagged }
    }

    var slices: [TagSlice]
    var kind: Kind = .tag
    @State private var hover: String?

    private func color(_ key: String) -> Color {
        kind == .category ? Theme.category(key == CategoryStats.uncategorized ? nil : key) : Theme.tag(key)
    }

    var body: some View {
        if slices.contains(where: { $0.tag != kind.placeholder }) {
            let total = slices.reduce(0) { $0 + $1.duration }
            ChartCard(
                title: kind.title,
                caption: kind == .category ? "每个任务只算进一个分类。悬停图例高亮对应扇区。" : "一个任务有多个标签时，每个标签都计全额。"
            ) {
                HStack(spacing: 16) {
                    ZStack {
                        Chart(slices.prefix(8)) { slice in
                            SectorMark(
                                angle: .value("分钟", slice.duration),
                                innerRadius: .ratio(hover == slice.tag ? 0.56 : 0.62),
                                angularInset: 1.5
                            )
                            .foregroundStyle(color(slice.tag))
                            .opacity(hover == nil || hover == slice.tag ? 1 : 0.3)
                            .cornerRadius(3)
                        }
                        .chartLegend(.hidden)
                        .animation(.easeOut(duration: 0.2), value: hover)
                        if let hovered = slices.first(where: { $0.tag == hover }), total > 0 {
                            VStack(spacing: 0) {
                                Text("\(Int((hovered.duration / total * 100).rounded()))%")
                                    .font(.system(.title3, design: .rounded).weight(.bold))
                                Text(hovered.tag)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 70)
                        }
                    }
                    .frame(width: 130, height: 130)
                    .accessibilityIdentifier(kind == .category ? "category-chart" : "tag-chart")
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(slices.prefix(6)) { slice in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(color(slice.tag))
                                    .frame(width: 7, height: 7)
                                Text(slice.tag)
                                    .lineLimit(1)
                                Spacer()
                                Text(DurationFormat.prose(slice.duration))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(color(slice.tag).opacity(hover == slice.tag ? 0.12 : 0))
                            )
                            .contentShape(Rectangle())
                            .onHover { inside in
                                withAnimation(.easeOut(duration: 0.15)) {
                                    hover = inside ? slice.tag : (hover == slice.tag ? nil : hover)
                                }
                            }
                        }
                    }
                }
            }
        } else {
            ChartCard(
                title: kind.title,
                caption: kind == .category ? "给任务选个分类，就能看到时间花在哪类事上。" : "给任务加上 #标签，按更细的维度看时间。"
            ) {
                HStack(spacing: 8) {
                    Image(systemName: kind == .category ? "folder" : "number")
                        .foregroundStyle(.tertiary)
                    Text(kind == .category ? "例如「写周报 @工作」「跑步 @健康」" : "例如「写周报 #汇报」「跑步 #晨练」")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            }
        }
    }
}

// MARK: - Overlaps

struct OverlapCard: View {
    var overlaps: [TaskOverlap]
    @State private var hover: String?

    var body: some View {
        ChartCard(title: "常一起做的事", caption: "两两同时计时的累计时长。") {
            if overlaps.isEmpty {
                Text("没有并行过，一次一件。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            } else {
                let longest = overlaps.first?.duration ?? 1
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(overlaps.prefix(5)) { overlap in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(overlap.titleA) × \(overlap.titleB)")
                                    .lineLimit(1)
                                Spacer()
                                Text(DurationFormat.prose(overlap.duration))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(Theme.mild.opacity(hover == overlap.id ? 1 : 0.6))
                                    .frame(width: max(4, proxy.size.width * overlap.duration / longest))
                            }
                            .frame(height: 3)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(hover == overlap.id ? 0.05 : 0))
                        )
                        .contentShape(Rectangle())
                        .onHover { inside in
                            withAnimation(.easeOut(duration: 0.15)) {
                                hover = inside ? overlap.id : (hover == overlap.id ? nil : hover)
                            }
                        }
                    }
                }
                .padding(.horizontal, -6)
            }
        }
    }
}

private struct DayBand: Identifiable {
    var day: Date
    var band: String
    var minutes: Double
    var id: String { "\(day.timeIntervalSinceReferenceDate)-\(band)" }
}

private struct HourBand: Identifiable {
    var hour: Int
    var band: String
    var minutes: Double
    var id: String { "\(hour)-\(band)" }
}
