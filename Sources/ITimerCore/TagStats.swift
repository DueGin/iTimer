import Foundation

/// A task input split into its parts.
public struct ParsedTitle: Equatable, Sendable {
    public var title: String
    public var tags: [String]

    public init(title: String, tags: [String]) {
        self.title = title
        self.tags = tags
    }
}

public enum TitleParser {
    /// "写周报 #汇报 #周报" → title "写周报", tags ["汇报", "周报"].
    /// A `#tag` anywhere in the input is pulled out of the title.
    public static func parse(_ input: String) -> ParsedTitle {
        var tags: [String] = []
        var seen: Set<String> = []
        var words: [String] = []
        for part in input.split(whereSeparator: \.isWhitespace) {
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
        return ParsedTitle(title: title, tags: tags)
    }

    /// The inverse of `parse`: "写周报 #汇报".
    public static func input(title: String, tags: [String]) -> String {
        ([title] + tags.map { "#\($0)" }).joined(separator: " ")
    }

    /// Tags merged case-insensitively, first spelling wins.
    public static func merge(_ lhs: [String], _ rhs: [String]) -> [String] {
        var seen: Set<String> = []
        return (lhs + rhs).filter { seen.insert($0.lowercased()).inserted }
    }
}

/// A user-created group of tasks. Unlike the old category, a collection is
/// something the user makes on purpose; tasks are filed into it by id.
public struct TaskCollection: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Index into the app's collection palette.
    public var color: Int
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, color: Int, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.color = color
        self.createdAt = createdAt
    }

    /// Single-line names, capped so a chip stays readable.
    public static func clean(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let word = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        let collapsed = word.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(20))
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

public enum CollectionStats {
    public static let uncollected = "未归集"
    /// Sentinel used by filters to mean "tasks in no collection".
    public static let uncollectedID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// Display name of the collection a task files under.
    public static func key(_ task: TaskItem, collections: [TaskCollection]) -> String {
        guard let id = task.collectionID, let collection = collections.first(where: { $0.id == id }) else {
            return uncollected
        }
        return collection.name
    }

    public static func slices(tasks: [TaskItem], collections: [TaskCollection], window: DateInterval, now: Date) -> [TagSlice] {
        TagStats.totals(tasks: tasks, window: window, now: now) { [key($0, collections: collections)] }
    }
}
