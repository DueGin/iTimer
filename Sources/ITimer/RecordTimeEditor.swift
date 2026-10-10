import ITimerCore
import SwiftUI

/// A local draft, committed only by Save. Used inline in the menu panel
/// and in a sheet in analysis; field pickers keep the menu panel open.
struct RecordTimeEditor: View {
    var taskID: UUID
    var title: String
    var store: TaskStore
    var now: Date
    var onClose: () -> Void
    private let originalSegments: [TimeSegment]
    @State private var segments: [TimeSegment]
    @State private var saveError: String?

    init(task: TaskItem, store: TaskStore, now: Date, onClose: @escaping () -> Void) {
        taskID = task.id
        title = task.title
        self.store = store
        self.now = now
        self.onClose = onClose
        originalSegments = task.segments
        _segments = State(initialValue: task.segments)
    }

    private var validationError: String? {
        RecordTimeValidation.error(for: segments, asOf: currentTime)
    }

    private var currentTime: Date { max(now, store.now) }

    private var recordChanged: Bool {
        guard let task = store.tasks.first(where: { $0.id == taskID }) else { return true }
        return !task.isCompleted || task.segments != originalSegments
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("修改计时时间")
                    .font(.headline)
                Spacer()
                Button("取消", action: onClose)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("record-time-cancel")
            }
            Text(title)
                .font(.callout)
                .lineLimit(2)
            Text("按每段实际计时修改，暂停间隔不计入时长。完成日期随最后一段的结束时间更新。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(segments.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 8) {
                    if segments.count > 1 {
                        Text("第 \(index + 1) 段")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    timeField("开始", index: index, isEnd: false)
                    timeField("结束", index: index, isEnd: true)
                }
                .padding(10)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            }

            if recordChanged {
                errorMessage("记录已被修改、继续计时或删除，请取消后重新打开。")
            } else if let error = validationError ?? saveError {
                errorMessage(error)
            }

            HStack {
                Text("合计 \(DurationFormat.prose(segments.reduce(0) { $0 + $1.duration(asOf: currentTime) }))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("record-time-total")
                Spacer()
                Button("保存", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(validationError != nil || recordChanged)
                    .accessibilityIdentifier("record-time-save")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("record-time-editor")
        .onChange(of: segments) { _, _ in saveError = nil }
    }

    private func timeField(_ label: String, index: Int, isEnd: Bool) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            DatePicker(label, selection: Binding(
                get: { isEnd ? (segments[index].endedAt ?? now) : segments[index].startedAt },
                set: {
                    if isEnd { segments[index].endedAt = $0 }
                    else { segments[index].startedAt = $0 }
                }
            ), displayedComponents: [.date, .hourAndMinute])
            .datePickerStyle(.field)
            .labelsHidden()
            .accessibilityLabel("第 \(index + 1) 段\(label)时间")
            .accessibilityIdentifier("record-time-\(isEnd ? "end" : "start")-\(index)")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func errorMessage(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("record-time-error")
    }

    private func save() {
        guard store.updateCompletedSegments(
            id: taskID,
            segments: segments,
            expectedSegments: originalSegments,
            at: currentTime
        ) else {
            saveError = store.lastError.map { "保存失败：\($0)" } ?? "无法保存，请检查时间或重新打开记录。"
            return
        }
        onClose()
    }
}
