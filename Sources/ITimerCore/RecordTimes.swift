import Foundation

/// Shared validation for the editor and the store. Segments stay in their
/// original order so pauses are preserved and a task never overlaps itself.
public enum RecordTimeValidation {
    public static func error(for segments: [TimeSegment], asOf now: Date) -> String? {
        guard !segments.isEmpty else { return "这条记录没有计时段。" }
        var previousEnd: Date?
        for (index, segment) in segments.enumerated() {
            let label = "第 \(index + 1) 段"
            guard let end = segment.endedAt else { return "\(label)缺少结束时间。" }
            guard segment.startedAt.timeIntervalSince1970.isFinite,
                  end.timeIntervalSince1970.isFinite else { return "\(label)的时间无效。" }
            // Immediate pause/complete can legitimately produce a zero-length segment.
            guard end >= segment.startedAt else { return "\(label)的结束时间不能早于开始时间。" }
            guard end <= now else { return "\(label)的时间不能晚于现在。" }
            if let previousEnd, segment.startedAt < previousEnd {
                return "\(label)与上一段重叠，请按时间先后填写。"
            }
            previousEnd = end
        }
        return nil
    }
}
