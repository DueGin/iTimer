import ITimerCore
import SwiftUI

/// Note and comments for one task. Replaces the task list the way the
/// schedule composer does, so the latched popup height never has to grow.
struct JournalView: View {
    var task: TaskItem
    var store: TaskStore
    var now: Date
    var onClose: () -> Void
    @State private var note: String
    @State private var draft = ""
    @FocusState private var commentFocused: Bool

    init(task: TaskItem, store: TaskStore, now: Date, onClose: @escaping () -> Void) {
        self.task = task
        self.store = store
        self.now = now
        self.onClose = onClose
        _note = State(initialValue: task.note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成", action: close)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("journal-close")
            }

            noteField

            Text("进展")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            commentList
            commentField
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("journal")
        // Every save rewrites the data file and the calendar event, so wait
        // for a pause in typing. Closing the panel mid-pause still saves.
        .task(id: note) {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            commitNote()
        }
        .onDisappear(perform: commitNote)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let collection = store.collection(id: task.collectionID) { parts.append(collection.name) }
        if !task.tags.isEmpty { parts.append(task.tags.map { "#\($0)" }.joined(separator: " ")) }
        parts.append(task.isRunning ? "计时中" : task.isPending ? "未开始" : task.isCompleted ? "已完成" : "已暂停")
        return parts.joined(separator: " · ")
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("备注")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $note)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 64, maxHeight: 110)
                .padding(6)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if note.isEmpty {
                        Text("结论、约束、下次接着做什么")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("journal-note")
        }
    }

    private var commentList: some View {
        Group {
            if task.comments.isEmpty {
                Text("还没有进展。做完一步就记一句，比事后回忆准。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(task.comments.reversed()) { comment in
                        commentRow(comment)
                    }
                }
            }
        }
    }

    private func commentRow(_ comment: TaskComment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Theme.focused)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(comment.text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(comment.createdAt.formatted(.dateTime.month().day().hour().minute()))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Button {
                store.deleteComment(id: task.id, commentID: comment.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("删除这条进展")
            .accessibilityIdentifier("comment-delete-\(comment.id.uuidString)")
        }
    }

    private var commentField: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("记一条进展，回车保存", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(1...4)
                .focused($commentFocused)
                .onSubmit(commitComment)
                .accessibilityIdentifier("journal-comment")
            Button(action: commitComment) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.focused))
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("记下这条进展")
            .accessibilityIdentifier("journal-comment-add")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func commitNote() {
        store.setNote(id: task.id, note)
    }

    private func commitComment() {
        guard store.addComment(id: task.id, text: draft, at: now) != nil else { return }
        draft = ""
        commentFocused = true
    }

    private func close() {
        commitNote()
        onClose()
    }
}
