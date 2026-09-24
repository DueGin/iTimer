import Foundation

public enum BrainSplitRules {
    public static let defaultThreshold = 3
    public static let minimumThreshold = 2
    public static let maximumThreshold = 8
    /// Share of union-active time at or above the threshold.
    public static let reachedRatio = 0.15
    public static let severeRatio = 0.40

    public static func clamp(_ value: Int) -> Int {
        min(maximumThreshold, max(minimumThreshold, value))
    }
}

public enum FocusVerdict: String, Codable, Equatable, Sendable {
    case idle
    case focused
    case mild
    case brainSplit

    public var title: String {
        switch self {
        case .idle: "空闲"
        case .focused: "专注"
        case .mild: "轻度并行"
        case .brainSplit: "脑裂"
        }
    }
}

public enum BrainSplitDegree: String, Codable, Equatable, Sendable {
    case none
    case brief
    case reached
    case severe

    public var title: String {
        switch self {
        case .none: "未脑裂"
        case .brief: "短暂脑裂"
        case .reached: "已达脑裂"
        case .severe: "严重脑裂"
        }
    }
}

public struct TimeSegment: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var endedAt: Date?

    public init(startedAt: Date, endedAt: Date? = nil) {
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public func duration(asOf now: Date) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    public func clipped(to window: DateInterval, asOf now: Date) -> DateInterval? {
        let end = endedAt ?? now
        let start = max(startedAt, window.start)
        let clippedEnd = min(end, window.end)
        guard clippedEnd > start else { return nil }
        return DateInterval(start: start, end: clippedEnd)
    }
}

public struct TaskItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var segments: [TimeSegment]
    public var completedAt: Date?
    public var tags: [String]
    /// Identifier of the matching event in the local calendar, once synced.
    public var calendarEventID: String?

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date,
        segments: [TimeSegment] = [],
        completedAt: Date? = nil,
        tags: [String] = [],
        calendarEventID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.segments = segments
        self.completedAt = completedAt
        self.tags = tags
        self.calendarEventID = calendarEventID
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, segments, completedAt, tags, calendarEventID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        segments = try container.decode([TimeSegment].self, forKey: .segments)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        calendarEventID = try container.decodeIfPresent(String.self, forKey: .calendarEventID)
    }

    public var isCompleted: Bool { completedAt != nil }

    public var isRunning: Bool {
        completedAt == nil && segments.last?.endedAt == nil && !segments.isEmpty
    }

    public var isPaused: Bool {
        completedAt == nil && !isRunning
    }

    public func duration(asOf now: Date) -> TimeInterval {
        segments.reduce(0) { $0 + $1.duration(asOf: now) }
    }

    public func duration(asOf now: Date, within window: DateInterval) -> TimeInterval {
        segments.reduce(0) { partial, segment in
            guard let clipped = segment.clipped(to: window, asOf: now) else { return partial }
            return partial + clipped.duration
        }
    }

    public var currentStart: Date? {
        guard isRunning else { return nil }
        return segments.last?.startedAt
    }
}

public enum AnalysisRange: String, CaseIterable, Identifiable, Sendable {
    case today
    case week
    case month
    case all

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .today: "今天"
        case .week: "7天"
        case .month: "30天"
        case .all: "全部"
        }
    }

    public func window(
        asOf now: Date,
        tasks: [TaskItem],
        calendar: Calendar = .current
    ) -> DateInterval {
        let start: Date
        switch self {
        case .today:
            start = calendar.startOfDay(for: now)
        case .week:
            start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        case .month:
            start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
        case .all:
            start = tasks.flatMap(\.segments).map(\.startedAt).min() ?? now
        }
        let end = now > start ? now : start.addingTimeInterval(1)
        return DateInterval(start: start, end: end)
    }
}

public struct ConcurrencySlice: Equatable, Identifiable, Sendable {
    public var id: Int
    public var start: Date
    public var end: Date
    public var concurrency: Int

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public struct TaskOverlap: Equatable, Identifiable, Sendable {
    public var taskAID: UUID
    public var taskBID: UUID
    public var titleA: String
    public var titleB: String
    public var duration: TimeInterval

    public var id: String { "\(taskAID.uuidString)-\(taskBID.uuidString)" }
}

public struct TaskStat: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var duration: TimeInterval
    public var isRunning: Bool
    public var isPaused: Bool
    public var isCompleted: Bool
}

public struct ParallelismReport: Equatable, Sendable {
    public var window: DateInterval
    public var threshold: Int
    public var maxConcurrency: Int
    public var unionActive: TimeInterval
    public var timeAtOrAboveThreshold: TimeInterval
    public var degree: BrainSplitDegree
    public var verdict: FocusVerdict
    public var switchCount: Int
    public var slices: [ConcurrencySlice]
    public var overlaps: [TaskOverlap]
    public var tasks: [TaskStat]

    public var brainSplitRatio: Double {
        guard unionActive > 0 else { return 0 }
        return timeAtOrAboveThreshold / unionActive
    }

    public static let empty = ParallelismReport(
        window: DateInterval(start: .distantPast, end: .distantPast.addingTimeInterval(1)),
        threshold: BrainSplitRules.defaultThreshold,
        maxConcurrency: 0,
        unionActive: 0,
        timeAtOrAboveThreshold: 0,
        degree: .none,
        verdict: .idle,
        switchCount: 0,
        slices: [],
        overlaps: [],
        tasks: []
    )
}

public enum DurationFormat {
    public static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    public static func prose(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        if total < 60 { return "\(total)秒" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            if minutes == 0 { return "\(hours)小时" }
            return "\(hours)小时\(minutes)分"
        }
        if seconds == 0 { return "\(minutes)分" }
        return "\(minutes)分\(seconds)秒"
    }
}

public enum StatusText {
    public static func label(runningCount: Int, longestElapsed: TimeInterval, threshold: Int) -> String {
        guard runningCount > 0 else { return "" }
        if runningCount >= threshold { return "脑裂 \(runningCount)" }
        let clock = DurationFormat.clock(longestElapsed)
        if runningCount == 1 { return clock }
        return "\(runningCount)·\(clock)"
    }

    public static func accessibility(runningCount: Int, threshold: Int, verdict: FocusVerdict) -> String {
        if runningCount <= 0 { return "iTimer 空闲" }
        return "iTimer 进行中 \(runningCount) \(verdict.title)"
    }
}
