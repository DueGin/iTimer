import Foundation

public struct Insight: Identifiable, Equatable, Sendable {
    public enum Tone: String, Equatable, Sendable {
        case positive
        case neutral
        case warning
    }

    public var id: String
    public var symbol: String
    public var title: String
    public var detail: String
    public var tone: Tone
}

/// Turns a report into a few plain-language observations. Each rule only
/// fires when it has something worth saying; at most `limit` are returned,
/// warnings first.
public enum Insights {
    public static let minimumSoloWorthMentioning: TimeInterval = 10 * 60
    public static let minimumOverlapWorthMentioning: TimeInterval = 5 * 60
    public static let switchesPerHourWarning = 3.0

    public static func generate(
        report: ParallelismReport,
        calendar: Calendar = .current,
        limit: Int = 4
    ) -> [Insight] {
        guard report.unionActive > 0 else { return [] }
        var found: [Insight] = []
        let clock = Date.FormatStyle(date: .omitted, time: .shortened)

        let hours = max(report.unionActive / 3600, 0.25)
        let switchRate = Double(report.switchCount) / hours
        if switchRate >= switchesPerHourWarning {
            found.append(Insight(
                id: "switch-rate",
                symbol: "arrow.triangle.swap",
                title: "每小时切换 \(String(format: "%.1f", switchRate)) 次",
                detail: "频繁开新线程，找回状态的时间会被悄悄吃掉。试着把零碎事攒成一批做。",
                tone: .warning
            ))
        }

        let hourLoads = ChartSeries.hours(of: report.slices, threshold: report.threshold, calendar: calendar)
        if let worst = hourLoads.max(by: { $0.brainSplit < $1.brainSplit }), worst.brainSplit > 0 {
            found.append(Insight(
                id: "split-hour",
                symbol: "clock.badge.exclamationmark",
                title: "\(worst.hour) 点最容易脑裂",
                detail: "这个时段累计脑裂 \(DurationFormat.prose(worst.brainSplit))。把消息和会议挪开，给它留一段整块时间。",
                tone: .warning
            ))
        }

        if let pair = report.overlaps.first, pair.duration >= minimumOverlapWorthMentioning {
            found.append(Insight(
                id: "overlap",
                symbol: "square.on.square",
                title: "「\(pair.titleA)」和「\(pair.titleB)」总在一起",
                detail: "同时进行了 \(DurationFormat.prose(pair.duration))。如果其中一件能等，就让它排队。",
                tone: .neutral
            ))
        }

        if let solo = ChartSeries.longestSolo(of: report.slices), solo.duration >= minimumSoloWorthMentioning {
            found.append(Insight(
                id: "longest-solo",
                symbol: "scope",
                title: "最长单核 \(DurationFormat.prose(solo.duration))",
                detail: "从 \(solo.start.formatted(clock)) 开始，一次只做一件事。这是你的最佳状态。",
                tone: .positive
            ))
        }

        if report.switchCount == 0, report.unionActive >= 30 * 60 {
            found.append(Insight(
                id: "no-switch",
                symbol: "checkmark.seal",
                title: "零切换",
                detail: "整段 \(DurationFormat.prose(report.unionActive)) 都没有并行，干净利落。",
                tone: .positive
            ))
        }

        let order: [Insight.Tone] = [.warning, .neutral, .positive]
        return Array(found
            .enumerated()
            .sorted { lhs, rhs in
                let left = order.firstIndex(of: lhs.element.tone) ?? 0
                let right = order.firstIndex(of: rhs.element.tone) ?? 0
                if left != right { return left < right }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
            .prefix(limit))
    }
}
