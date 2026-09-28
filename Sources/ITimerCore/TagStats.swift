import Foundation

/// A task input split into its parts.
public struct ParsedTitle: Equatable, Sendable {
    public var title: String
    public var tags: [String]
    /// Last `@分类` in the input, if any.
    public var category: String?

    public init(title: String, tags: [String], category: String?) {
        self.title = title
        self.tags = tags
        self.category = category
    }
}

public enum TitleParser {
    /// "写周报 #工作 #汇报 @工作" → title "写周报", tags ["工作", "汇报"],
    /// category "工作". A `#tag` or `@category` anywhere in the input is
    /// pulled out of the title.
    public static func parse(_ input: String) -> ParsedTitle {
        var tags: [String] = []
        var seen: Set<String> = []
        var category: String?
        var words: [String] = []
        for part in input.split(whereSeparator: \.isWhitespace) {
            if part.hasPrefix("@"), part.count > 1 {
                category = String(part.dropFirst())
                continue
            }
            guard part.hasPrefix("#"), part.count > 1 else {
                words.append(String(part))
                continue
            }
            let tag = String(part.dropFirst())
            if seen.insert(tag.lowercased()).inserted {
                tags.append(tag)
            }
        }
        let title = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedTitle(title: title, tags: tags, category: category)
    }

    /// The inverse of `parse`: "写周报 @工作 #汇报".
    public static func input(title: String, tags: [String], category: String?) -> String {
        ([title] + (category.map { ["@\($0)"] } ?? []) + tags.map { "#\($0)" }).joined(separator: " ")
    }

    /// Tags merged case-insensitively, first spelling wins.
    public static func merge(_ lhs: [String], _ rhs: [String]) -> [String] {
        var seen: Set<String> = []
        return (lhs + rhs).filter { seen.insert($0.lowercased()).inserted }
    }
}

/// A user-managed category. Each task belongs to at most one.
public struct TaskCategory: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var name: String
    /// Index into the app's category palette.
    public var color: Int

    public var id: String { name }

    public init(name: String, color: Int) {
        self.name = name
        self.color = color
    }

    public static let defaults: [TaskCategory] = [
        TaskCategory(name: "工作", color: 0),
        TaskCategory(name: "学习", color: 1),
        TaskCategory(name: "生活", color: 2),
        TaskCategory(name: "健康", color: 3),
    ]

    /// Names are single words so they survive the `@分类` round trip.
    public static func clean(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let word = trimmed.hasPrefix("@") || trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        return String(word.split(whereSeparator: \.isWhitespace).joined().prefix(12))
    }
}

public struct TagSlice: Identifiable, Equatable, Sendable {
    public var tag: String
    public var duration: TimeInterval
    public var id: String { tag }
}

public enum TagStats {
    public static let untagged = "无标签"

    public static func slices(tasks: [TaskItem], window: DateInterval, now: Date) -> [TagSlice] {
        totals(tasks: tasks, window: window, now: now) { task in
            task.tags.isEmpty ? [untagged] : task.tags
        }
    }

    static func totals(tasks: [TaskItem], window: DateInterval, now: Date, keys: (TaskItem) -> [String]) -> [TagSlice] {
        var totals: [String: TimeInterval] = [:]
        for task in tasks {
            let duration = task.duration(asOf: now, within: window)
            guard duration > 0 else { continue }
            for key in keys(task) {
                totals[key, default: 0] += duration
            }
        }
        return totals
            .map { TagSlice(tag: $0.key, duration: $0.value) }
            .sorted { lhs, rhs in
                if lhs.duration != rhs.duration { return lhs.duration > rhs.duration }
                return lhs.tag < rhs.tag
            }
    }
}

public enum CategoryStats {
    public static let uncategorized = "未分类"

    /// Key a task files under in charts and filters.
    public static func key(_ task: TaskItem) -> String {
        task.category ?? uncategorized
    }

    public static func slices(tasks: [TaskItem], window: DateInterval, now: Date) -> [TagSlice] {
        TagStats.totals(tasks: tasks, window: window, now: now) { [key($0)] }
    }
}
