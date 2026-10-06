import AppKit
import ITimerCore
import SwiftUI

/// An infinite canvas for one workflow: cards are tasks, lines are
/// "this before that".
struct WorkflowCanvasView: View {
    var store: TaskStore
    var workflowID: UUID

    var body: some View {
        if let workflow = store.workflow(id: workflowID) {
            let tasks = store.tasksByID
            GraphCanvas(
                model: WorkflowCanvasModel(store: store, workflowID: workflowID),
                layout: .workflow,
                wording: .workflow
            ) { node, context in
                if let task = tasks[node.id], let placed = workflow.node(node.id) {
                    WorkflowCard(
                        task: task,
                        node: placed,
                        state: workflow.state(of: node.id, tasks: tasks) ?? .ready,
                        blockers: workflow.blockers(of: node.id, tasks: tasks).count,
                        store: store,
                        workflowID: workflowID,
                        selected: context.selected,
                        linkHighlight: context.linkHighlight,
                        onSelect: context.select,
                        onAddNext: context.addNext
                    )
                }
            } header: {
                header(workflow, tasks: tasks)
            } summary: {
                summary(workflow, tasks: tasks)
            } picker: { pick in
                WorkflowTaskPicker(store: store, workflowID: workflowID, onPick: pick)
            }
        } else {
            ContentUnavailableView("工作流已删除", systemImage: "point.3.connected.trianglepath.dotted")
        }
    }

    /// The workflow's name, since the window title belongs to the list column.
    private func header(_ workflow: Workflow, tasks: [UUID: TaskItem]) -> some View {
        let running = workflow.nodes.contains { tasks[$0.taskID]?.isRunning == true }
        return HStack(spacing: 7) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(Theme.focused)
            Text(workflow.name)
                .font(.headline)
                .lineLimit(1)
            if running {
                PulseDot(color: Theme.focused, active: true, size: 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityIdentifier("workflow-title")
    }

    private func summary(_ workflow: Workflow, tasks: [UUID: TaskItem]) -> some View {
        let states = workflow.nodes.compactMap { workflow.state(of: $0.taskID, tasks: tasks) }
        let progress = workflow.progress(tasks: tasks)
        return HStack(spacing: 12) {
            CanvasLegend(color: .orange, title: "可开始", count: states.filter { $0 == .ready }.count)
            CanvasLegend(color: Theme.focused, title: "进行中", count: states.filter { $0 == .running }.count)
            CanvasLegend(color: .secondary, title: "等待上游", count: states.filter { $0 == .blocked }.count)
            Text("完成 \(progress.done)/\(progress.total)")
                .font(.caption.weight(.semibold).monospacedDigit())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workflow-summary")
    }
}

/// A workflow as seen by the graph canvas: its tasks and their edges.
@MainActor
struct WorkflowCanvasModel: GraphCanvasModel {
    var store: TaskStore
    var workflowID: UUID

    private var workflow: Workflow? { store.workflow(id: workflowID) }

    var nodes: [CanvasNode] {
        let tasks = store.tasksByID
        return (workflow?.nodes ?? [])
            .filter { tasks[$0.taskID] != nil }
            .map { CanvasNode(id: $0.taskID, x: $0.x, y: $0.y) }
    }

    var links: [CanvasLink] {
        let tasks = store.tasksByID
        return (workflow?.edges ?? []).map { CanvasLink(edge: $0, met: tasks[$0.from]?.isCompleted == true) }
    }

    var viewport: WorkflowViewport? { workflow?.viewport }
    var acceptsDrops: Bool { true }

    func canConnect(from: UUID, to: UUID) -> Bool {
        workflow?.canConnect(from: from, to: to) ?? false
    }

    func connect(from: UUID, to: UUID) -> Bool {
        store.connect(from: from, to: to, in: workflowID)
    }

    func disconnect(_ edge: WorkflowEdge) {
        store.disconnect(from: edge.from, to: edge.to, in: workflowID)
    }

    func move(_ id: UUID, x: Double, y: Double) {
        store.moveNode(taskID: id, in: workflowID, x: x, y: y)
    }

    func place(_ id: UUID, x: Double, y: Double) -> Bool {
        store.place(taskID: id, in: workflowID, x: x, y: y)
    }

    func remove(_ id: UUID) {
        store.removeNode(taskID: id, from: workflowID)
    }

    func create(title: String, x: Double, y: Double, after: UUID?) -> UUID? {
        store.addWorkflowStep(title: title, in: workflowID, x: x, y: y, after: after)?.id
    }

    func arrange() {
        store.arrangeWorkflow(id: workflowID)
    }

    func saveViewport(_ viewport: WorkflowViewport) {
        store.setViewport(id: workflowID, viewport)
    }
}

extension CanvasWording {
    static let workflow = CanvasWording(
        id: "workflow",
        newItem: "新步骤",
        newItemHelp: "新建一步；选中卡片时接在它后面（也可以双击画布）",
        newHere: "在这里新建步骤",
        addExisting: "添加已有任务",
        addExistingHelp: "把已有的任务放到画布上",
        firstPrompt: "新步骤 #标签，回车添加",
        nextPrompt: "下一步，回车添加，Esc 结束",
        portHelp: "拖到另一张卡片：连成先后顺序；点击：添加下一步",
        portLabel: "添加下一步",
        arrangeHelp: "按先后顺序排成几列",
        emptyIcon: "point.3.connected.trianglepath.dotted",
        emptyTitle: "空白画布",
        emptyText: "双击任意位置新建一步，或把左侧的任务拖进来。\n从卡片右侧的圆点拖到另一张卡片，就连成了先后顺序。",
        firstItem: "新建第一步"
    )
}

/// A colored dot and a count, for the summary pill in a canvas corner.
struct CanvasLegend: View {
    var color: Color
    var title: String
    var count: Int

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(title) \(count)")
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(count == 0 ? .tertiary : .secondary)
    }
}
