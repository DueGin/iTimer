import ITimerCore
import SwiftUI

/// A free-form tag.
struct TagPill: View {
    var tag: String

    var body: some View {
        Text("#" + tag)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Theme.tag(tag))
    }
}

/// Parent and tag submenus for a task's context menu. Menus are safe in
/// the MenuBarExtra panel but cannot take typing, so a new tag goes
/// through `onEditLabels`.
struct LabelMenus: View {
    var task: TaskItem
    var store: TaskStore
    var onEditLabels: (() -> Void)?
    var onAddSubtask: (() -> Void)?

    var body: some View {
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
        let tag = TitleParser.cleanTag(input)
        input = ""
        guard !tag.isEmpty else { return }
        tags = TitleParser.merge(tags, [tag])
    }
}
