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

    /// One tag as typed: a leading `#` dropped, single-line, capped so a
    /// chip stays readable.
    public static func cleanTag(_ name: String) -> String {
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
