import Foundation

public enum TitleParser {
    /// "写周报 #工作 #汇报" → title "写周报", tags ["工作", "汇报"].
    /// A `#tag` anywhere in the input is pulled out of the title.
    public static func parse(_ input: String) -> (title: String, tags: [String]) {
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
        return (title, tags)
    }
}

public struct TagSlice: Identifiable, Equatable, Sendable {
    public var tag: String
    public var duration: TimeInterval
    public var id: String { tag }
}

public enum TagStats {
    public static let untagged = "未分类"

    public static func slices(tasks: [TaskItem], window: DateInterval, now: Date) -> [TagSlice] {
        var totals: [String: TimeInterval] = [:]
        for task in tasks {
            let duration = task.duration(asOf: now, within: window)
            guard duration > 0 else { continue }
            if task.tags.isEmpty {
                totals[untagged, default: 0] += duration
            } else {
                for tag in task.tags {
                    totals[tag, default: 0] += duration
                }
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
