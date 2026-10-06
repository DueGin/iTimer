import ITimerCore
import SwiftUI

/// How the panel's task list is organized.
enum TaskListMode: String {
    /// Collections as folders, tasks filed inside them.
    case folders
    /// Due / running / paused / upcoming / undated / done sections.
    case status
}

/// A collection shown as a folder in the panel: tap to fold, double-click
/// the name to rename, drop tasks on it to file them. `collection == nil`
/// is the 未归集 bucket, which cannot be renamed or removed.
struct FolderHeader: View {
    var collection: TaskCollection?
    var store: TaskStore
    var openCount: Int
    var runningCount: Int
    var doneCount: Int
    var expanded: Bool
    /// A dragged task is over this folder.
    var targeted: Bool
    var onToggle: () -> Void
    var onNewSchedule: () -> Void
    @State private var renaming = false
    @State private var nameDraft = ""
    @State private var hovering = false
    @FocusState private var nameFocused: Bool

    private var color: Color {
        collection.map { Theme.collectionColor(index: $0.color) } ?? .secondary
    }

    private var name: String { collection?.name ?? CollectionStats.uncollected }

    private var identifier: String { collection?.id.uuidString ?? "loose" }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)
            Image(systemName: collection == nil ? "tray" : expanded ? "folder.fill" : "folder")
                .font(.system(size: 12))
                .foregroundStyle(color)
                .frame(width: 16)
            if renaming {
                TextField("集合名", text: $nameDraft)
                    .textFieldStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .focused($nameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { renaming = false }
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { commitRename() }
                    }
                    .accessibilityIdentifier("folder-rename-\(identifier)")
            } else {
                Text(name)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(collection == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .onTapGesture(count: 2, perform: beginRename)
            }
            if openCount > 0 {
                Text("\(openCount)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .help("\(openCount) 个未完成")
            }
            if runningCount > 0 {
                Circle()
                    .fill(Theme.focused)
                    .frame(width: 6, height: 6)
                    .help("\(runningCount) 个进行中")
            }
            if doneCount > 0 && !expanded {
                Text("今日完成 \(doneCount)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            IconButton(title: "在「\(name)」里新建日程", systemImage: "plus", identifier: "folder-add-\(identifier)", action: onNewSchedule)
                .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(targeted ? color.opacity(0.18) : Color.primary.opacity(hovering ? 0.05 : 0))
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(color.opacity(0.6), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !renaming { onToggle() } }
        .onHover { inside in
            guard !MenuTracking.isOpen else { return }
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .contextMenu {
            Button("在这里新建日程…", action: onNewSchedule)
            Button(expanded ? "折叠" : "展开", action: onToggle)
            if let collection {
                Divider()
                Button("重命名", action: beginRename)
                Button("删除集合（任务保留）", role: .destructive) {
                    store.removeCollection(id: collection.id)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("folder-\(identifier)")
    }

    private func beginRename() {
        guard let collection else { return }
        nameDraft = collection.name
        renaming = true
        nameFocused = true
    }

    private func commitRename() {
        guard renaming else { return }
        renaming = false
        guard let collection else { return }
        store.renameCollection(id: collection.id, to: nameDraft)
    }
}
