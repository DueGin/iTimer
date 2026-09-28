import ITimerCore
import SwiftUI

/// A task's category: colored dot + name.
struct CategoryPill: View {
    var name: String

    var body: some View {
        let color = Theme.category(name)
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(name)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// A free-form tag, lighter than a category so the two read apart.
struct TagPill: View {
    var tag: String

    var body: some View {
        Text("#" + tag)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Theme.tag(tag))
    }
}

/// Category and tag submenus for a task's context menu. Menus are safe in
/// the MenuBarExtra panel; typing a new tag goes through `onEditLabels`.
struct LabelMenus: View {
    var task: TaskItem
    var store: TaskStore
    var onEditLabels: (() -> Void)?

    var body: some View {
        Menu("分类") {
            ForEach(store.categories) { category in
                Toggle(category.name, isOn: Binding(
                    get: { task.category == category.name },
                    set: { store.setCategory(id: task.id, $0 ? category.name : nil) }
                ))
            }
            Divider()
            Toggle(CategoryStats.uncategorized, isOn: Binding(
                get: { task.category == nil },
                set: { if $0 { store.setCategory(id: task.id, nil) } }
            ))
        }
        Menu("标签") {
            let known = Array(TitleParser.merge(task.tags, store.knownTags).prefix(12))
            ForEach(known, id: \.self) { tag in
                Toggle("#" + tag, isOn: Binding(
                    get: { task.tags.contains(tag) },
                    set: { _ in store.toggleTag(id: task.id, tag) }
                ))
            }
            if let onEditLabels {
                if !known.isEmpty { Divider() }
                Button("新标签…", action: onEditLabels)
            }
        }
    }
}

/// Category chips for the schedule composer. Tapping the selected one
/// clears it. A name typed via `@` that is not in the list yet shows too.
struct CategoryPicker: View {
    @Binding var selection: String?
    var categories: [TaskCategory]

    var body: some View {
        let names = categories.map(\.name) + (selection.map { name in
            categories.contains { $0.name == name } ? [] : [name]
        } ?? [])
        FlowLayout(spacing: 4) {
            ForEach(names, id: \.self) { name in
                let selected = selection == name
                let color = Theme.category(name)
                Button {
                    selection = selected ? nil : name
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(color).frame(width: 6, height: 6)
                        Text(name)
                    }
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? color : Color.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(selected ? color.opacity(0.16) : Color.primary.opacity(0.05), in: Capsule())
                    .overlay { if selected { Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1) } }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityIdentifier("category-picker")
    }
}

/// Selected tags (tap × to drop), a few recent ones to add, and a field
/// for new ones.
struct TagEditor: View {
    @Binding var tags: [String]
    var known: [String]
    @State private var input = ""

    var body: some View {
        let suggestions = known.filter { tag in !tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }.prefix(5)
        FlowLayout(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                Button {
                    tags.removeAll { $0 == tag }
                } label: {
                    HStack(spacing: 2) {
                        Text("#" + tag)
                        Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.tag(tag))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.tag(tag).opacity(0.14), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("去掉 #\(tag)")
            }
            ForEach(Array(suggestions), id: \.self) { tag in
                Button {
                    tags.append(tag)
                } label: {
                    Text("+" + tag)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("加上 #\(tag)")
            }
            TextField("新标签", text: $input)
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(width: 64)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.05), in: Capsule())
                .onSubmit(commit)
                .accessibilityIdentifier("tag-input")
        }
        .accessibilityIdentifier("tag-editor")
    }

    private func commit() {
        let tag = TaskCategory.clean(input)
        input = ""
        guard !tag.isEmpty else { return }
        tags = TitleParser.merge(tags, [tag])
    }
}
