import AppKit
import ITimerCore
import SwiftUI

/// Card size and canvas limits, in canvas points. Cards have a fixed size
/// so lines can anchor to their sides without measuring.
enum CanvasMetrics {
    static let card = CGSize(width: 220, height: 84)
    static let grid: CGFloat = 24
    static let scaleRange: ClosedRange<CGFloat> = 0.3...2
    /// Spacing used for new steps and the tidy-up layout.
    static let column: CGFloat = 280
    static let row: CGFloat = 120
}

/// Pan and zoom: screen = canvas × scale + offset.
struct CanvasTransform: Equatable {
    var offset: CGSize = .zero
    var scale: CGFloat = 1

    init(offset: CGSize = .zero, scale: CGFloat = 1) {
        self.offset = offset
        self.scale = scale
    }

    init(_ viewport: WorkflowViewport) {
        offset = CGSize(width: viewport.x, height: viewport.y)
        scale = min(max(viewport.scale, CanvasMetrics.scaleRange.lowerBound), CanvasMetrics.scaleRange.upperBound)
    }

    var viewport: WorkflowViewport {
        WorkflowViewport(x: offset.width, y: offset.height, scale: scale)
    }

    func screen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scale + offset.width, y: point.y * scale + offset.height)
    }

    func canvas(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.width) / scale, y: (point.y - offset.height) / scale)
    }

    /// Zooms keeping the canvas point under `anchor` where it is on screen.
    mutating func zoom(by factor: CGFloat, around anchor: CGPoint) {
        let target = min(max(scale * factor, CanvasMetrics.scaleRange.lowerBound), CanvasMetrics.scaleRange.upperBound)
        let fixed = canvas(anchor)
        scale = target
        offset = CGSize(width: anchor.x - fixed.x * target, height: anchor.y - fixed.y * target)
    }

    /// Centers `rect` in a view of `size`, zoomed out as needed but never in
    /// past 100%, so a lone card does not fill the window.
    static func fitting(_ rect: CGRect, in size: CGSize) -> CanvasTransform {
        guard size.width > 0, size.height > 0 else { return CanvasTransform() }
        let padded = rect.insetBy(dx: -60, dy: -60)
        let fit = min(size.width / padded.width, size.height / padded.height)
        let scale = min(1, max(CanvasMetrics.scaleRange.lowerBound, fit))
        return CanvasTransform(
            offset: CGSize(width: size.width / 2 - padded.midX * scale, height: size.height / 2 - padded.midY * scale),
            scale: scale
        )
    }
}

/// One dependency line in screen space: a cubic leaving the upstream card's
/// right side and arriving at the downstream card's left side.
struct EdgeGeometry: Identifiable {
    enum Style {
        /// Upstream is done: solid.
        case met
        /// Upstream still open: dashed.
        case waiting
        /// Being drawn, or previewing where a new step will hang.
        case draft
    }

    var id: String
    var edge: WorkflowEdge?
    var start: CGPoint
    var end: CGPoint
    var scale: CGFloat
    var style: Style

    private var arrowLength: CGFloat { 9 * scale }
    private var base: CGPoint { CGPoint(x: end.x - arrowLength, y: end.y) }

    private var controls: (CGPoint, CGPoint) {
        let reach = max(40 * scale, abs(base.x - start.x) / 2)
        return (CGPoint(x: start.x + reach, y: start.y), CGPoint(x: base.x - reach, y: base.y))
    }

    var curve: Path {
        let (first, second) = controls
        var path = Path()
        path.move(to: start)
        path.addCurve(to: base, control1: first, control2: second)
        return path
    }

    var arrow: Path {
        let half = arrowLength * 0.55
        var path = Path()
        path.move(to: end)
        path.addLine(to: CGPoint(x: base.x, y: end.y - half))
        path.addLine(to: CGPoint(x: base.x, y: end.y + half))
        path.closeSubpath()
        return path
    }

    func point(at t: CGFloat) -> CGPoint {
        let (first, second) = controls
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(
            x: a * start.x + b * first.x + c * second.x + d * base.x,
            y: a * start.y + b * first.y + c * second.y + d * base.y
        )
    }

    var midpoint: CGPoint { point(at: 0.5) }

    /// Distance from `point` to the curve, measured on a sampled polyline.
    func distance(to point: CGPoint) -> CGFloat {
        var best = CGFloat.infinity
        var previous = start
        for step in 1...24 {
            let next = self.point(at: CGFloat(step) / 24)
            best = min(best, Self.distance(point, from: previous, to: next))
            previous = next
        }
        return min(best, Self.distance(point, from: base, to: end))
    }

    private static func distance(_ point: CGPoint, from a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        let t = length == 0 ? 0 : max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }
}

/// An infinite canvas for one workflow: cards are tasks, lines are
/// "this before that". Two-finger scroll pans, pinch or ⌘-scroll zooms,
/// dragging empty space pans too.
struct WorkflowCanvasView: View {
    var store: TaskStore
    var workflowID: UUID
    @State private var transform = CanvasTransform()
    @State private var size: CGSize = .zero
    @State private var loaded = false
    /// No saved viewport and the user has not panned or zoomed yet: keep
    /// fitting the cards as the window settles into its size.
    @State private var autoFit = false
    /// Offset when a background drag began.
    @State private var panOrigin: CGSize?
    @State private var drag: CardDrag?
    @State private var link: LinkDrag?
    @State private var selection: CanvasSelection?
    @State private var hoveredEdge: String?
    @State private var composer: StepComposer?
    @State private var composerDraft = ""
    @State private var picking = false
    @State private var dropTargeted = false
    /// Pointer position, kept out of the view state so moving the mouse
    /// does not redraw the canvas; read when a menu or tap needs it.
    @State private var pointer = PointerBox()
    @FocusState private var canvasFocused: Bool
    @FocusState private var composerFocused: Bool

    private struct CardDrag: Equatable {
        var id: UUID
        /// In canvas points.
        var delta: CGSize
    }

    private struct LinkDrag: Equatable {
        var from: UUID
        /// In screen points.
        var point: CGPoint
        var target: UUID?
    }

    private enum CanvasSelection: Equatable {
        case node(UUID)
        case edge(WorkflowEdge)
    }

    private struct StepComposer: Equatable {
        /// Center of the card to be, in canvas points.
        var at: CGPoint
        /// Wire the new step after this task.
        var after: UUID?
    }

    final class PointerBox {
        var location: CGPoint?
    }

    var body: some View {
        if let workflow = store.workflow(id: workflowID) {
            canvas(workflow)
        } else {
            ContentUnavailableView("工作流已删除", systemImage: "point.3.connected.trianglepath.dotted")
        }
    }

    private func canvas(_ workflow: Workflow) -> some View {
        let tasks = store.tasksByID
        let nodes = workflow.nodes.filter { tasks[$0.taskID] != nil }
        let edges = edgeGeometry(workflow, tasks: tasks)
        return GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                CanvasGrid(transform: transform)
                    .contentShape(Rectangle())
                    .gesture(panGesture)
                    .onTapGesture(count: 2) { location in
                        openComposer(at: transform.canvas(location), after: nil)
                    }
                    .onTapGesture { location in
                        tapBackground(at: location, edges: edges)
                    }
                    .contextMenu { backgroundMenu(workflow, edges: edges) }
                EdgeLayer(edges: edges + draftEdges(workflow), hovered: hoveredEdge, selected: selectedEdgeID)
                    .allowsHitTesting(false)
                ForEach(nodes) { node in
                    if let task = tasks[node.taskID] {
                        card(task, node: node, workflow: workflow, tasks: tasks)
                    }
                }
                if case .edge(let edge) = selection, let geometry = edges.first(where: { $0.edge == edge }) {
                    edgeRemover(edge, at: geometry.midpoint)
                }
                if let composer {
                    composerField(composer, workflow: workflow)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .coordinateSpace(name: Self.space)
            .onContinuousHover { phase in
                hover(phase, edges: edges, nodes: nodes)
            }
            .background(CanvasEventCatcher(onScroll: scroll, onMagnify: magnify))
            .dropDestination(for: String.self) { items, location in
                drop(items, at: location, in: workflow)
            } isTargeted: { inside in
                dropTargeted = inside
            }
            .onAppear {
                size = proxy.size
                load(workflow)
            }
            .onChange(of: proxy.size) { _, new in
                size = new
                if autoFit { fit(animated: false) }
            }
        }
        .background(Theme.canvas)
        .overlay {
            if nodes.isEmpty && composer == nil {
                emptyHint
            }
        }
        .overlay(alignment: .topLeading) {
            header(workflow, tasks: tasks)
                .padding(14)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) {
            zoomBar.padding(14)
        }
        .overlay(alignment: .bottomTrailing) {
            if !nodes.isEmpty {
                summary(workflow, tasks: tasks).padding(14)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.focused.opacity(0.6), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        // Takes focus on click (not only with full keyboard access), so
        // Delete and Esc reach it.
        .focusable(interactions: .edit)
        .focusEffectDisabled()
        .focused($canvasFocused)
        // The Mac's delete key arrives as U+007F, which is neither `.delete`
        // (U+0008) nor `.deleteForward` (U+F728).
        .onKeyPress(keys: [.delete, .deleteForward, KeyEquivalent("\u{7F}")]) { _ in
            // A field on the canvas (renaming, a new step) keeps its own Delete.
            guard !(NSApp.keyWindow?.firstResponder is NSText) else { return .ignored }
            return deleteSelection() ? .handled : .ignored
        }
        .onKeyPress(.escape) {
            guard selection != nil || link != nil else { return .ignored }
            selection = nil
            link = nil
            return .handled
        }
        .task(id: transform) {
            // Remember where the canvas was left, once it settles. Until the
            // user moves it, reopening should fit the cards again instead.
            guard loaded, !autoFit else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            store.setViewport(id: workflowID, transform.viewport)
        }
        .toolbar { toolbar(workflow) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workflow-canvas")
    }

    private static let space = "workflow-canvas"

    // MARK: cards

    private func card(_ task: TaskItem, node: WorkflowNode, workflow: Workflow, tasks: [UUID: TaskItem]) -> some View {
        let state = workflow.state(of: node.taskID, tasks: tasks) ?? .ready
        let linkHighlight: Color? = link.flatMap { link in
            guard link.target == node.taskID else { return nil }
            return workflow.canConnect(from: link.from, to: node.taskID) ? Theme.focused : .red
        }
        return WorkflowCard(
            task: task,
            node: node,
            state: state,
            blockers: workflow.blockers(of: node.taskID, tasks: tasks).count,
            store: store,
            workflowID: workflowID,
            selected: selection == .node(node.taskID),
            linkHighlight: linkHighlight,
            onSelect: { select(.node(node.taskID)) },
            onAddNext: { openComposer(at: nextSlot(after: node, in: workflow), after: node.taskID) }
        )
        .gesture(cardDrag(node))
        .overlay(alignment: .trailing) {
            OutputPort(selected: selection == .node(node.taskID)) {
                openComposer(at: nextSlot(after: node, in: workflow), after: node.taskID)
            }
            .offset(x: 7)
            .highPriorityGesture(linkDrag(from: node, in: workflow))
        }
        .scaleEffect(transform.scale)
        .position(transform.screen(center(of: node)))
        .zIndex(drag?.id == node.taskID ? 2 : selection == .node(node.taskID) ? 1 : 0)
    }

    private func center(of node: WorkflowNode) -> CGPoint {
        let delta = drag?.id == node.taskID ? drag?.delta ?? .zero : .zero
        return CGPoint(x: node.x + delta.width, y: node.y + delta.height)
    }

    private func cardRect(_ node: WorkflowNode) -> CGRect {
        let center = center(of: node)
        let size = CanvasMetrics.card
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// Topmost card under a screen point.
    private func node(at screenPoint: CGPoint, in workflow: Workflow, excluding: UUID? = nil) -> WorkflowNode? {
        let point = transform.canvas(screenPoint)
        return workflow.nodes.last { $0.taskID != excluding && cardRect($0).contains(point) }
    }

    private func cardDrag(_ node: WorkflowNode) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if drag == nil { select(.node(node.taskID)) }
                drag = CardDrag(
                    id: node.taskID,
                    delta: CGSize(width: value.translation.width / transform.scale, height: value.translation.height / transform.scale)
                )
            }
            .onEnded { value in
                let x = Self.snapped(node.x + value.translation.width / transform.scale)
                let y = Self.snapped(node.y + value.translation.height / transform.scale)
                store.moveNode(taskID: node.taskID, in: workflowID, x: x, y: y)
                drag = nil
            }
    }

    private func linkDrag(from node: WorkflowNode, in workflow: Workflow) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { value in
                link = LinkDrag(
                    from: node.taskID,
                    point: value.location,
                    target: self.node(at: value.location, in: workflow, excluding: node.taskID)?.taskID
                )
            }
            .onEnded { value in
                defer { link = nil }
                if let target = self.node(at: value.location, in: workflow, excluding: node.taskID) {
                    if store.connect(from: node.taskID, to: target.taskID, in: workflowID) {
                        select(.edge(WorkflowEdge(from: node.taskID, to: target.taskID)))
                    } else {
                        NSSound.beep()
                    }
                } else {
                    // Let go on empty canvas: the next step starts right there.
                    let point = transform.canvas(value.location)
                    openComposer(at: CGPoint(x: point.x + CanvasMetrics.card.width / 2, y: point.y), after: node.taskID)
                }
            }
    }

    /// Cards settle on a half-grid so neighbors line up without effort.
    private static func snapped(_ value: CGFloat) -> CGFloat {
        let step = CanvasMetrics.grid / 2
        return (value / step).rounded() * step
    }

    // MARK: edges

    private var selectedEdgeID: String? {
        if case .edge(let edge) = selection { return edge.id }
        return nil
    }

    private func edgeGeometry(_ workflow: Workflow, tasks: [UUID: TaskItem]) -> [EdgeGeometry] {
        workflow.edges.compactMap { edge in
            guard let from = workflow.node(edge.from), let to = workflow.node(edge.to) else { return nil }
            return EdgeGeometry(
                id: edge.id,
                edge: edge,
                start: transform.screen(outPort(of: from)),
                end: transform.screen(inPort(of: to)),
                scale: transform.scale,
                style: tasks[edge.from]?.isCompleted == true ? .met : .waiting
            )
        }
    }

    /// The line being dragged out of a port, and the one a pending new
    /// step will hang from.
    private func draftEdges(_ workflow: Workflow) -> [EdgeGeometry] {
        var drafts: [EdgeGeometry] = []
        if let link, let from = workflow.node(link.from) {
            let end = link.target.flatMap(workflow.node).map { transform.screen(inPort(of: $0)) } ?? link.point
            drafts.append(EdgeGeometry(id: "link", start: transform.screen(outPort(of: from)), end: end, scale: transform.scale, style: .draft))
        }
        if let composer, let after = composer.after.flatMap(workflow.node) {
            let end = CGPoint(x: composer.at.x - CanvasMetrics.card.width / 2, y: composer.at.y)
            drafts.append(EdgeGeometry(id: "composer", start: transform.screen(outPort(of: after)), end: transform.screen(end), scale: transform.scale, style: .draft))
        }
        return drafts
    }

    private func outPort(of node: WorkflowNode) -> CGPoint {
        let center = center(of: node)
        return CGPoint(x: center.x + CanvasMetrics.card.width / 2, y: center.y)
    }

    private func inPort(of node: WorkflowNode) -> CGPoint {
        let center = center(of: node)
        return CGPoint(x: center.x - CanvasMetrics.card.width / 2, y: center.y)
    }

    private func edge(near point: CGPoint, in edges: [EdgeGeometry]) -> EdgeGeometry? {
        edges
            .map { ($0, $0.distance(to: point)) }
            .filter { $0.1 <= 6 }
            .min { $0.1 < $1.1 }?.0
    }

    private func edgeRemover(_ edge: WorkflowEdge, at point: CGPoint) -> some View {
        Button {
            store.disconnect(from: edge.from, to: edge.to, in: workflowID)
            selection = nil
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Theme.surface, in: Circle())
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
        }
        .buttonStyle(HoverButtonStyle(shape: .circle, tint: .red, hover: 0.15, hoverScale: 1.1, restForeground: .accentColor, hoverForeground: .red))
        .help("删除这条连线（Delete）")
        .accessibilityIdentifier("remove-edge")
        .position(point)
    }

    // MARK: background

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let origin = panOrigin ?? transform.offset
                panOrigin = origin
                autoFit = false
                transform.offset = CGSize(width: origin.width + value.translation.width, height: origin.height + value.translation.height)
            }
            .onEnded { _ in
                panOrigin = nil
            }
    }

    private func tapBackground(at location: CGPoint, edges: [EdgeGeometry]) {
        canvasFocused = true
        if let hit = edge(near: location, in: edges), let edge = hit.edge {
            selection = .edge(edge)
        } else {
            selection = nil
            if composerDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                composer = nil
            }
        }
    }

    private func hover(_ phase: HoverPhase, edges: [EdgeGeometry], nodes: [WorkflowNode]) {
        // An open menu covers the canvas; redrawing under it would flash it.
        guard !MenuTracking.isOpen else { return }
        var hovered: String?
        switch phase {
        case .active(let location):
            pointer.location = location
            let point = transform.canvas(location)
            if link == nil, drag == nil, !nodes.contains(where: { cardRect($0).contains(point) }) {
                hovered = edge(near: location, in: edges)?.id
            }
        case .ended:
            pointer.location = nil
        }
        if hovered != hoveredEdge { hoveredEdge = hovered }
    }

    @ViewBuilder
    private func backgroundMenu(_ workflow: Workflow, edges: [EdgeGeometry]) -> some View {
        if let location = pointer.location, let hit = edge(near: location, in: edges), let edge = hit.edge {
            Button("删除连线") { store.disconnect(from: edge.from, to: edge.to, in: workflowID) }
            Divider()
        }
        Button("在这里新建步骤") {
            let location = pointer.location ?? CGPoint(x: size.width / 2, y: size.height / 2)
            openComposer(at: transform.canvas(location), after: nil)
        }
        Button("添加已有任务…") { picking = true }
        Divider()
        Button("自动整理") { arrange(workflow) }
            .disabled(workflow.nodes.count < 2)
        Button("适应窗口") { fit(animated: true) }
    }

    // MARK: new steps

    private func openComposer(at point: CGPoint, after: UUID?) {
        composer = StepComposer(at: point, after: after)
        composerDraft = ""
        selection = nil
        reveal(point)
        // The field exists only after this update; focus it on the next one.
        DispatchQueue.main.async { composerFocused = true }
    }

    private func composerField(_ composer: StepComposer, workflow: Workflow) -> some View {
        HStack(spacing: 7) {
            Image(systemName: composer.after == nil ? "plus.circle.fill" : "arrow.right.circle.fill")
                .foregroundStyle(Theme.focused)
            TextField(composer.after == nil ? "新步骤 #标签，回车添加" : "下一步，回车添加，Esc 结束", text: $composerDraft)
                .textFieldStyle(.plain)
                .font(.callout.weight(.medium))
                .focused($composerFocused)
                .onSubmit { commitComposer(composer) }
                .onExitCommand { closeComposer() }
                .accessibilityIdentifier("workflow-step-field")
        }
        .padding(.horizontal, 12)
        .frame(width: CanvasMetrics.card.width, height: 44)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.focused.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
        }
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .scaleEffect(transform.scale)
        .position(transform.screen(composer.at))
        .zIndex(3)
    }

    /// Adds the step and keeps the field open one column to the right,
    /// wired after it, so a chain can be typed out in one go.
    private func commitComposer(_ current: StepComposer) {
        let title = composerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            closeComposer()
            return
        }
        guard let step = store.addWorkflowStep(
            title: title,
            in: workflowID,
            x: Self.snapped(current.at.x),
            y: Self.snapped(current.at.y),
            after: current.after
        ), let workflow = store.workflow(id: workflowID), let node = workflow.node(step.id) else {
            NSSound.beep()
            return
        }
        openComposer(at: nextSlot(after: node, in: workflow), after: step.id)
    }

    private func closeComposer() {
        composer = nil
        composerDraft = ""
        canvasFocused = true
    }

    /// One column right of `node`, moved down past any card already there.
    private func nextSlot(after node: WorkflowNode, in workflow: Workflow) -> CGPoint {
        freeSlot(near: CGPoint(x: node.x + CanvasMetrics.column, y: node.y), in: workflow)
    }

    private func freeSlot(near point: CGPoint, in workflow: Workflow) -> CGPoint {
        var slot = point
        while workflow.nodes.contains(where: {
            abs($0.x - slot.x) < CanvasMetrics.card.width && abs($0.y - slot.y) < CanvasMetrics.card.height + 12
        }) {
            slot.y += CanvasMetrics.row
        }
        return slot
    }

    private var viewCenter: CGPoint {
        transform.canvas(CGPoint(x: size.width / 2, y: size.height / 2))
    }

    // MARK: adding tasks

    private func drop(_ items: [String], at location: CGPoint, in workflow: Workflow) -> Bool {
        let ids = items.compactMap(UUID.init(uuidString:))
        var point = transform.canvas(location)
        var placed: UUID?
        for id in ids {
            let slot = workflow.contains(id) ? point : freeSlot(near: point, in: store.workflow(id: workflowID) ?? workflow)
            if store.place(taskID: id, in: workflowID, x: Self.snapped(slot.x), y: Self.snapped(slot.y)) {
                placed = id
                point.y = slot.y + CanvasMetrics.row
            }
        }
        if let placed { select(.node(placed)) }
        return placed != nil
    }

    private func pick(_ taskID: UUID) {
        guard let workflow = store.workflow(id: workflowID) else { return }
        let slot = freeSlot(near: viewCenter, in: workflow)
        guard store.place(taskID: taskID, in: workflowID, x: Self.snapped(slot.x), y: Self.snapped(slot.y)) else { return }
        select(.node(taskID))
        reveal(slot)
    }

    // MARK: selection and keys

    private func select(_ target: CanvasSelection) {
        selection = target
        canvasFocused = true
    }

    /// Delete takes a card off the canvas (the task stays) or cuts a line.
    private func deleteSelection() -> Bool {
        switch selection {
        case .node(let id):
            store.removeNode(taskID: id, from: workflowID)
        case .edge(let edge):
            store.disconnect(from: edge.from, to: edge.to, in: workflowID)
        case nil:
            return false
        }
        selection = nil
        return true
    }

    // MARK: viewport

    private func load(_ workflow: Workflow) {
        guard !loaded else { return }
        if let viewport = workflow.viewport {
            transform = CanvasTransform(viewport)
        } else {
            autoFit = true
            fit(animated: false)
        }
        loaded = true
    }

    private func fit(animated: Bool) {
        guard let workflow = store.workflow(id: workflowID) else { return }
        let rects = workflow.nodes.map(cardRect)
        let target: CanvasTransform
        if let first = rects.first {
            target = .fitting(rects.dropFirst().reduce(first) { $0.union($1) }, in: size)
        } else {
            // An empty canvas puts the origin in the middle.
            target = CanvasTransform(offset: CGSize(width: size.width / 2, height: size.height / 2))
        }
        if animated {
            withAnimation(.easeInOut(duration: 0.3)) { transform = target }
        } else {
            transform = target
        }
    }

    private func arrange(_ workflow: Workflow) {
        withAnimation(.spring(duration: 0.45)) {
            store.arrangeWorkflow(id: workflow.id)
        }
        fit(animated: true)
    }

    /// Pans just enough to bring a card-sized area around `point` on screen.
    private func reveal(_ point: CGPoint) {
        let screen = transform.screen(point)
        let marginX = CanvasMetrics.card.width * transform.scale / 2 + 24
        let marginY = CanvasMetrics.card.height * transform.scale / 2 + 24
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        if screen.x + marginX > size.width { dx = size.width - marginX - screen.x }
        if screen.x - marginX < 0 { dx = marginX - screen.x }
        if screen.y + marginY > size.height { dy = size.height - marginY - screen.y }
        if screen.y - marginY < 0 { dy = marginY - screen.y }
        guard dx != 0 || dy != 0 else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            transform.offset.width += dx
            transform.offset.height += dy
        }
    }

    private func zoom(by factor: CGFloat) {
        autoFit = false
        withAnimation(.easeOut(duration: 0.18)) {
            transform.zoom(by: factor, around: CGPoint(x: size.width / 2, y: size.height / 2))
        }
    }

    private func scroll(_ event: CanvasScroll) {
        autoFit = false
        if event.zooms {
            transform.zoom(by: exp(event.delta.height * (event.precise ? 0.01 : 0.1)), around: event.location)
        } else {
            let gain: CGFloat = event.precise ? 1 : 10
            transform.offset.width += event.delta.width * gain
            transform.offset.height += event.delta.height * gain
        }
    }

    private func magnify(_ amount: CGFloat, at location: CGPoint) {
        autoFit = false
        transform.zoom(by: 1 + amount, around: location)
    }

    // MARK: chrome

    private var zoomBar: some View {
        HStack(spacing: 2) {
            IconButton(title: "缩小（⌘-）", systemImage: "minus", identifier: "canvas-zoom-out") { zoom(by: 1 / 1.25) }
                .keyboardShortcut("-", modifiers: .command)
            Button {
                autoFit = false
                withAnimation(.easeOut(duration: 0.18)) {
                    transform.zoom(by: 1 / transform.scale, around: CGPoint(x: size.width / 2, y: size.height / 2))
                }
            } label: {
                Text("\(Int((transform.scale * 100).rounded()))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(width: 44, height: 22)
            }
            .buttonStyle(HoverButtonStyle(shape: .capsule, hover: 0.1))
            .help("恢复到 100%")
            .accessibilityIdentifier("canvas-zoom-reset")
            IconButton(title: "放大（⌘=）", systemImage: "plus", identifier: "canvas-zoom-in") { zoom(by: 1.25) }
                .keyboardShortcut("=", modifiers: .command)
        }
        .padding(3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
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
            legend(.orange, "可开始", states.filter { $0 == .ready }.count)
            legend(Theme.focused, "进行中", states.filter { $0 == .running }.count)
            legend(.secondary, "等待上游", states.filter { $0 == .blocked }.count)
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

    private func legend(_ color: Color, _ title: String, _ count: Int) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(title) \(count)")
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(count == 0 ? .tertiary : .secondary)
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("空白画布")
                .font(.headline)
            Text("双击任意位置新建一步，或把左侧的任务拖进来。\n从卡片右侧的圆点拖到另一张卡片，就连成了先后顺序。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("新建第一步") {
                openComposer(at: viewCenter, after: nil)
            }
            .buttonStyle(PillButtonStyle(tint: Theme.focused))
            .accessibilityIdentifier("workflow-first-step")
        }
        .padding(24)
    }

    @ToolbarContentBuilder
    private func toolbar(_ workflow: Workflow) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                let anchor = selection.flatMap { selected -> WorkflowNode? in
                    if case .node(let id) = selected { return workflow.node(id) }
                    return nil
                }
                if let anchor {
                    openComposer(at: nextSlot(after: anchor, in: workflow), after: anchor.taskID)
                } else {
                    openComposer(at: freeSlot(near: viewCenter, in: workflow), after: nil)
                }
            } label: {
                Label("新步骤", systemImage: "plus.rectangle")
            }
            .help("新建一步；选中卡片时接在它后面（也可以双击画布）")
            .accessibilityIdentifier("workflow-new-step")
            Button {
                picking = true
            } label: {
                Label("添加已有任务", systemImage: "tray.and.arrow.down")
            }
            .help("把已有的任务放到画布上")
            .popover(isPresented: $picking, arrowEdge: .bottom) {
                WorkflowTaskPicker(store: store, workflowID: workflowID, onPick: pick)
            }
            .accessibilityIdentifier("workflow-add-existing")
            Button {
                arrange(workflow)
            } label: {
                Label("自动整理", systemImage: "rectangle.3.group")
            }
            .help("按先后顺序排成几列")
            .disabled(workflow.nodes.count < 2)
            .accessibilityIdentifier("workflow-arrange")
            Button {
                fit(animated: true)
            } label: {
                Label("适应窗口", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
            }
            .help("显示全部卡片（⌘0）")
            .keyboardShortcut("0", modifiers: .command)
            .accessibilityIdentifier("workflow-fit")
        }
    }
}

/// Dot grid that pans and zooms with the canvas. Dots thin out when zoomed
/// far out so the background never turns to noise.
private struct CanvasGrid: View {
    var transform: CanvasTransform

    var body: some View {
        Canvas { context, size in
            var step = CanvasMetrics.grid * transform.scale
            while step < 14 { step *= 2 }
            let radius = max(0.7, min(1.2, transform.scale))
            let startX = (transform.offset.width.truncatingRemainder(dividingBy: step) + step).truncatingRemainder(dividingBy: step)
            let startY = (transform.offset.height.truncatingRemainder(dividingBy: step) + step).truncatingRemainder(dividingBy: step)
            var dots = Path()
            var x = startX
            while x < size.width {
                var y = startY
                while y < size.height {
                    dots.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    y += step
                }
                x += step
            }
            context.fill(dots, with: .color(.primary.opacity(0.14)))
        }
        .accessibilityHidden(true)
    }
}

/// Every dependency line, drawn in one pass. Hit testing happens in the
/// canvas view, against the same geometry.
private struct EdgeLayer: View {
    var edges: [EdgeGeometry]
    var hovered: String?
    var selected: String?

    var body: some View {
        Canvas { context, _ in
            for edge in edges {
                let lit = edge.id == hovered || edge.id == selected
                let color: Color = switch edge.style {
                case _ where edge.id == selected: .accentColor
                case .met: Theme.focused.opacity(lit ? 1 : 0.75)
                case .waiting: Color.primary.opacity(lit ? 0.6 : 0.3)
                case .draft: Theme.focused
                }
                let width = (lit ? 2.6 : 1.7) * max(0.7, edge.scale)
                let dash: [CGFloat] = edge.style == .met ? [] : [5 * edge.scale, 4 * edge.scale]
                context.stroke(edge.curve, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
                context.fill(edge.arrow, with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The handle on a card's right side: drag it onto another card to wire
/// "this before that", or click it to type the next step.
private struct OutputPort: View {
    var selected: Bool
    var onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Circle()
                .fill(hovering ? Theme.focused : Theme.surface)
            Circle()
                .strokeBorder(Theme.focused.opacity(hovering || selected ? 1 : 0.5), lineWidth: 1.5)
            Image(systemName: "plus")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(hovering ? Color.white : Theme.focused)
                .opacity(hovering || selected ? 1 : 0)
        }
        .frame(width: 16, height: 16)
        .scaleEffect(hovering ? 1.2 : 1)
        .contentShape(Circle().inset(by: -4))
        .onHover { inside in
            guard !MenuTracking.isOpen else { return }
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .onTapGesture(perform: onTap)
        .help("拖到另一张卡片：连成先后顺序；点击：添加下一步")
        .accessibilityLabel("添加下一步")
        .accessibilityAddTraits(.isButton)
    }
}

struct CanvasScroll {
    var delta: CGSize
    var location: CGPoint
    /// Trackpad (continuous) rather than a notched wheel.
    var precise: Bool
    /// ⌘ held: zoom instead of pan.
    var zooms: Bool
}

/// SwiftUI on macOS 14 has no scroll-wheel or pinch events for a plain view,
/// so watch them app-wide and claim the ones over the canvas.
struct CanvasEventCatcher: NSViewRepresentable {
    var onScroll: (CanvasScroll) -> Void
    var onMagnify: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.handlers = self
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.handlers = self
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.stop()
    }

    final class CatcherView: NSView {
        var handlers: CanvasEventCatcher?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        /// Clicks go to the SwiftUI views above.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                // Local monitors run on the main thread.
                nonisolated(unsafe) let event = event
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let handlers, let window, !isHiddenOrHasHiddenAncestor else { return false }
            let windowPoint: NSPoint
            if let target = event.window {
                guard target === window else { return false }
                windowPoint = event.locationInWindow
            } else {
                // Events posted by other tools may come without a window;
                // their location is then on screen.
                guard NSWindow.windowNumber(at: event.locationInWindow, belowWindowWithWindowNumber: 0) == window.windowNumber else { return false }
                windowPoint = window.convertPoint(fromScreen: event.locationInWindow)
            }
            let point = convert(windowPoint, from: nil)
            guard bounds.contains(point) else { return false }
            switch event.type {
            case .scrollWheel:
                handlers.onScroll(CanvasScroll(
                    delta: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
                    location: point,
                    precise: event.hasPreciseScrollingDeltas,
                    zooms: event.modifierFlags.contains(.command)
                ))
            case .magnify:
                handlers.onMagnify(event.magnification, point)
            default:
                return false
            }
            return true
        }
    }
}
