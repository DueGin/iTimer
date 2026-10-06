import ITimerCore
import SwiftUI

/// A task's collection: colored dot + name.
struct CollectionPill: View {
    var collection: TaskCollection

    var body: some View {
        let color = Theme.collectionColor(index: collection.color)
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(collection.name)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// A free-form tag, lighter than a collection so the two read apart.
struct TagPill: View {
    var tag: String

    var body: some View {
        Text("#" + tag)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Theme.tag(tag))
    }
}

/// Collection, parent and tag submenus for a task's context menu.
/// Menus are safe in the MenuBarExtra panel but cannot take typing, so a
/// new tag goes through `onEditLabels` and a new collection through
/// `onNewCollection` (the composer, which names it inline).
struct LabelMenus: View {
    var task: TaskItem
    var store: TaskStore
    var onEditLabels: (() -> Void)?
    var onAddSubtask: (() -> Void)?
    var onNewCollection: (() -> Void)?

    var body: some View {
        if task.isRoot {
            Menu("集合") {
                if store.collections.isEmpty && onNewCollection == nil {
                    Button("还没有集合") {}
                        .disabled(true)
                }
                ForEach(store.collections) { collection in
                    Toggle(collection.name, isOn: Binding(
                        get: { task.collectionID == collection.id },
                        set: { store.setCollection(id: task.id, $0 ? collection.id : nil) }
                    ))
                }
                if onNewCollection != nil || task.collectionID != nil {
                    if !store.collections.isEmpty { Divider() }
                    if let onNewCollection {
                        Button("新建集合…", action: onNewCollection)
                    }
                    if task.collectionID != nil {
                        Button("移出集合") { store.setCollection(id: task.id, nil) }
                    }
                }
            }
        }
        Menu("子任务") {
            if let parent = store.parent(of: task) {
                Button("属于「\(parent.title)」") {}
                    .disabled(true)
                Button("移出，成为独立任务") { store.setParent(id: task.id, nil) }
            } else {
                if let onAddSubtask {
                    Button("添加子任务…", action: onAddSubtask)
                }
                let parents = store.tasks.filter { $0.isRoot && $0.id != task.id && store.subtasks(of: $0.id).isEmpty }
                if !parents.isEmpty {
                    Menu("归入其他任务") {
                        ForEach(parents.prefix(12)) { parent in
                            Button(parent.title) { store.setParent(id: task.id, parent.id) }
                        }
                    }
                }
            }
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

/// Workflow submenu for a task's context menu: put it on a canvas (a
/// task sits on one at a time), start a new canvas from it, or take it off.
struct WorkflowMenu: View {
    var task: TaskItem
    var store: TaskStore

    var body: some View {
        let current = store.workflow(containing: task.id)
        Menu("工作流") {
            ForEach(store.workflows) { workflow in
                Toggle(workflow.name, isOn: Binding(
                    get: { current?.id == workflow.id },
                    set: { on in
                        if on {
                            store.place(taskID: task.id, in: workflow.id)
                        } else {
                            store.removeNode(taskID: task.id, from: workflow.id)
                        }
                    }
                ))
            }
            if !store.workflows.isEmpty { Divider() }
            Button("放进新工作流") {
                if let workflow = store.addWorkflow(task.title) {
                    store.place(taskID: task.id, in: workflow.id)
                }
            }
            if let current {
                Button("移出「\(current.name)」") { store.removeNode(taskID: task.id, from: current.id) }
            }
        }
    }
}

/// On a list row: the task's workflow says it should wait for upstream steps.
struct WorkflowWaitPill: View {
    var task: TaskItem
    var store: TaskStore

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "hourglass")
            Text("等上游")
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .help(hint)
        .accessibilityLabel(hint)
    }

    private var hint: String {
        let names = store.workflowBlockers(of: task.id).map { "「\($0.title)」" }.joined(separator: "、")
        let workflow = store.workflow(containing: task.id)?.name ?? ""
        return "工作流「\(workflow)」里还在等 \(names) 完成"
    }
}

/// Collection chips for the schedule composer. Tapping the selected one
/// clears it. The trailing chip names a new collection in place and
/// files the task into it, so filing never detours through Settings.
struct CollectionPicker: View {
    @Binding var selection: UUID?
    var collections: [TaskCollection]
    var onCreate: (String) -> TaskCollection?
    @State private var naming = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(collections) { collection in
                let selected = selection == collection.id
                let color = Theme.collectionColor(index: collection.color)
                Button {
                    selection = selected ? nil : collection.id
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(color).frame(width: 6, height: 6)
                        Text(collection.name)
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
            creator
        }
        .accessibilityIdentifier("collection-picker")
    }

    @ViewBuilder
    private var creator: some View {
        if naming {
            TextField("集合名，回车创建", text: $name)
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(width: 104)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.05), in: Capsule())
                .overlay { Capsule().strokeBorder(Theme.focused.opacity(0.5), lineWidth: 1) }
                .focused($nameFocused)
                .onSubmit(create)
                .onExitCommand(perform: cancel)
                .onChange(of: nameFocused) { _, focused in
                    if !focused && name.trimmingCharacters(in: .whitespaces).isEmpty { cancel() }
                }
                .accessibilityIdentifier("collection-new-name")
        } else {
            Button {
                naming = true
                nameFocused = true
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plus").font(.system(size: 8, weight: .bold))
                    Text(collections.isEmpty ? "新建集合" : "新集合")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .overlay { Capsule().strokeBorder(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3, 2])) }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("新建一个集合，并把这个任务归进去")
            .accessibilityIdentifier("collection-new")
        }
    }

    private func create() {
        guard let collection = onCreate(name) else { return }
        selection = collection.id
        cancel()
    }

    private func cancel() {
        name = ""
        naming = false
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
        let tag = TaskCollection.clean(input)
        input = ""
        guard !tag.isEmpty else { return }
        tags = TitleParser.merge(tags, [tag])
    }
}
