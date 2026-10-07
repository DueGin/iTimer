import AppKit
import ITimerCore
import SwiftUI

/// A card on a graph canvas: what it stands for and where its center sits,
/// in canvas points.
struct CanvasNode: Identifiable, Equatable {
    var id: UUID
    var x: Double
    var y: Double
}

/// A line between two cards. `met`: the upstream one is done, drawn solid.
struct CanvasLink: Identifiable, Equatable {
    var edge: WorkflowEdge
    var met: Bool
    var id: String { edge.id }
}

/// What a graph canvas shows and where its edits go. Reads are live, so
/// right after an edit the canvas lays out against what is stored now.
@MainActor
protocol GraphCanvasModel {
    var nodes: [CanvasNode] { get }
    var links: [CanvasLink] { get }
    /// Where the canvas was left; nil = fit the cards when opened.
    var viewport: WorkflowViewport? { get }
    /// Whether ids dragged in from the task list can land here.
    var acceptsDrops: Bool { get }
    func canConnect(from: UUID, to: UUID) -> Bool
    func connect(from: UUID, to: UUID) -> Bool
    func disconnect(_ edge: WorkflowEdge)
    func move(_ id: UUID, x: Double, y: Double)
    /// Puts something that already exists on the canvas (picked or dropped).
    func place(_ id: UUID, x: Double, y: Double) -> Bool
    /// Takes a card off the canvas; what it stands for stays.
    func remove(_ id: UUID)
    /// A card typed on the canvas, wired after `after`. Its id, or nil.
    func create(title: String, x: Double, y: Double, after: UUID?) -> UUID?
    func arrange()
    func saveViewport(_ viewport: WorkflowViewport)
}

/// Words and accessibility ids that differ from one canvas to another.
struct CanvasWording {
    /// Prefix for ids: "\(id)-canvas", "\(id)-step-field", "\(id)-new-step"…
    var id: String
    var newItem: String
    var newItemHelp: String
    var newHere: String
    var addExisting: String
    var addExistingHelp: String
    var firstPrompt: String
    var nextPrompt: String
    var portHelp: String
    var portLabel: String
    var arrangeHelp: String
    var emptyIcon: String
    var emptyTitle: String
    var emptyText: String
    var firstItem: String
}

/// Handed to each card: how it is drawn right now and what it can ask for.
struct CanvasCardContext {
    var selected: Bool
    /// Border while a line is dragged over the card: whether it can be wired.
    var linkHighlight: Color?
    var select: () -> Void
    var addNext: () -> Void
}

/// An infinite canvas of cards wired by "this before that". Two-finger
/// scroll pans, pinch or ⌘-scroll zooms, dragging empty space pans too.
/// What the cards are, and where edits go, comes from the model.
struct GraphCanvas<Model: GraphCanvasModel, Card: View, Header: View, Summary: View, Picker: View>: View {
    var model: Model
    var layout: CanvasLayout
    var wording: CanvasWording
    var card: (CanvasNode, CanvasCardContext) -> Card
    var header: () -> Header
    var summary: () -> Summary
    var picker: (_ pick: @escaping (UUID) -> Void) -> Picker
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

    init(
        model: Model,
        layout: CanvasLayout,
        wording: CanvasWording,
        @ViewBuilder card: @escaping (CanvasNode, CanvasCardContext) -> Card,
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder summary: @escaping () -> Summary,
        @ViewBuilder picker: @escaping (_ pick: @escaping (UUID) -> Void) -> Picker
    ) {
        self.model = model
        self.layout = layout
        self.wording = wording
        self.card = card
        self.header = header
        self.summary = summary
        self.picker = picker
    }

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
        /// Wire the new card after this one.
        var after: UUID?
    }

    final class PointerBox {
        var location: CGPoint?
    }

    private var space: String { "\(wording.id)-canvas" }

    var body: some View {
        let nodes = model.nodes
        let edges = edgeGeometry(nodes: nodes, links: model.links)
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
                    .contextMenu { backgroundMenu(edges: edges, count: nodes.count) }
                EdgeLayer(edges: edges + draftEdges(nodes), hovered: hoveredEdge, selected: selectedEdgeID)
                    .allowsHitTesting(false)
                ForEach(nodes) { node in
                    cardView(node)
                }
                if case .edge(let edge) = selection, let geometry = edges.first(where: { $0.edge == edge }) {
                    edgeRemover(edge, at: geometry.midpoint)
                }
                if let composer {
                    composerField(composer)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .coordinateSpace(name: space)
            .onContinuousHover { phase in
                hover(phase, edges: edges, nodes: nodes)
            }
            .background(CanvasEventCatcher(onScroll: scroll, onMagnify: magnify))
            .dropDestination(for: String.self) { items, location in
                drop(items, at: location)
            } isTargeted: { inside in
                dropTargeted = inside && model.acceptsDrops
            }
            .onAppear {
                size = proxy.size
                load()
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
            header()
                .padding(14)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) {
            zoomBar.padding(14)
        }
        .overlay(alignment: .bottomTrailing) {
            if !nodes.isEmpty {
                summary().padding(14)
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
            // A field on the canvas (renaming, a new card) keeps its own Delete.
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
            model.saveViewport(transform.viewport)
        }
        .toolbar { toolbar(count: nodes.count) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(space)
    }

    // MARK: cards

    private func cardView(_ node: CanvasNode) -> some View {
        let linkHighlight: Color? = link.flatMap { link in
            guard link.target == node.id else { return nil }
            return model.canConnect(from: link.from, to: node.id) ? Theme.focused : .red
        }
        let context = CanvasCardContext(
            selected: selection == .node(node.id),
            linkHighlight: linkHighlight,
            select: { select(.node(node.id)) },
            addNext: { openComposer(at: nextSlot(after: node), after: node.id) }
        )
        return card(node, context)
            .gesture(cardDrag(node))
            .overlay(alignment: .trailing) {
                OutputPort(selected: selection == .node(node.id), help: wording.portHelp, label: wording.portLabel) {
                    openComposer(at: nextSlot(after: node), after: node.id)
                }
                .offset(x: 7)
                .highPriorityGesture(linkDrag(from: node))
            }
            .scaleEffect(transform.scale)
            .position(transform.screen(center(of: node)))
            .zIndex(drag?.id == node.id ? 2 : selection == .node(node.id) ? 1 : 0)
    }

    private func center(of node: CanvasNode) -> CGPoint {
        let delta = drag?.id == node.id ? drag?.delta ?? .zero : .zero
        return CGPoint(x: node.x + delta.width, y: node.y + delta.height)
    }

    private func cardRect(_ node: CanvasNode) -> CGRect {
        let center = center(of: node)
        let size = layout.card
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// Topmost card under a screen point.
    private func node(at screenPoint: CGPoint, excluding: UUID? = nil) -> CanvasNode? {
        let point = transform.canvas(screenPoint)
        return model.nodes.last { $0.id != excluding && cardRect($0).contains(point) }
    }

    private func cardDrag(_ node: CanvasNode) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(space))
            .onChanged { value in
                if drag == nil { select(.node(node.id)) }
                drag = CardDrag(
                    id: node.id,
                    delta: CGSize(width: value.translation.width / transform.scale, height: value.translation.height / transform.scale)
                )
            }
            .onEnded { value in
                let x = Self.snapped(node.x + value.translation.width / transform.scale)
                let y = Self.snapped(node.y + value.translation.height / transform.scale)
                model.move(node.id, x: x, y: y)
                drag = nil
            }
    }

    private func linkDrag(from node: CanvasNode) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(space))
            .onChanged { value in
                link = LinkDrag(
                    from: node.id,
                    point: value.location,
                    target: self.node(at: value.location, excluding: node.id)?.id
                )
            }
            .onEnded { value in
                defer { link = nil }
                if let target = self.node(at: value.location, excluding: node.id) {
                    if model.connect(from: node.id, to: target.id) {
                        select(.edge(WorkflowEdge(from: node.id, to: target.id)))
                    } else {
                        NSSound.beep()
                    }
                } else {
                    // Let go on empty canvas: the next card starts right there.
                    let point = transform.canvas(value.location)
                    openComposer(at: CGPoint(x: point.x + layout.card.width / 2, y: point.y), after: node.id)
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

    private func edgeGeometry(nodes: [CanvasNode], links: [CanvasLink]) -> [EdgeGeometry] {
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return links.compactMap { link in
            guard let from = byID[link.edge.from], let to = byID[link.edge.to] else { return nil }
            return EdgeGeometry(
                id: link.id,
                edge: link.edge,
                start: transform.screen(outPort(of: from)),
                end: transform.screen(inPort(of: to)),
                scale: transform.scale,
                style: link.met ? .met : .waiting
            )
        }
    }

    /// The line being dragged out of a port, and the one a pending new
    /// card will hang from.
    private func draftEdges(_ nodes: [CanvasNode]) -> [EdgeGeometry] {
        func node(_ id: UUID) -> CanvasNode? { nodes.first { $0.id == id } }
        var drafts: [EdgeGeometry] = []
        if let link, let from = node(link.from) {
            let end = link.target.flatMap(node).map { transform.screen(inPort(of: $0)) } ?? link.point
            drafts.append(EdgeGeometry(id: "link", start: transform.screen(outPort(of: from)), end: end, scale: transform.scale, style: .draft))
        }
        if let composer, let after = composer.after.flatMap(node) {
            let end = CGPoint(x: composer.at.x - layout.card.width / 2, y: composer.at.y)
            drafts.append(EdgeGeometry(id: "composer", start: transform.screen(outPort(of: after)), end: transform.screen(end), scale: transform.scale, style: .draft))
        }
        return drafts
    }

    private func outPort(of node: CanvasNode) -> CGPoint {
        let center = center(of: node)
        return CGPoint(x: center.x + layout.card.width / 2, y: center.y)
    }

    private func inPort(of node: CanvasNode) -> CGPoint {
        let center = center(of: node)
        return CGPoint(x: center.x - layout.card.width / 2, y: center.y)
    }

    private func edge(near point: CGPoint, in edges: [EdgeGeometry]) -> EdgeGeometry? {
        edges
            .map { ($0, $0.distance(to: point)) }
            .filter { $0.1 <= 6 }
            .min { $0.1 < $1.1 }?.0
    }

    private func edgeRemover(_ edge: WorkflowEdge, at point: CGPoint) -> some View {
        Button {
            model.disconnect(edge)
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

    private func hover(_ phase: HoverPhase, edges: [EdgeGeometry], nodes: [CanvasNode]) {
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
    private func backgroundMenu(edges: [EdgeGeometry], count: Int) -> some View {
        if let location = pointer.location, let hit = edge(near: location, in: edges), let edge = hit.edge {
            Button("删除连线") { model.disconnect(edge) }
            Divider()
        }
        Button(wording.newHere) {
            let location = pointer.location ?? CGPoint(x: size.width / 2, y: size.height / 2)
            openComposer(at: transform.canvas(location), after: nil)
        }
        Button(wording.addExisting + "…") { picking = true }
        Divider()
        Button("自动整理") { arrange() }
            .disabled(count < 2)
        Button("适应窗口") { fit(animated: true) }
    }

    // MARK: new cards

    private func openComposer(at point: CGPoint, after: UUID?) {
        composer = StepComposer(at: point, after: after)
        composerDraft = ""
        selection = nil
        reveal(point)
        // The field exists only after this update; focus it on the next one.
        DispatchQueue.main.async { composerFocused = true }
    }

    private func composerField(_ composer: StepComposer) -> some View {
        HStack(spacing: 7) {
            Image(systemName: composer.after == nil ? "plus.circle.fill" : "arrow.right.circle.fill")
                .foregroundStyle(Theme.focused)
            TextField(composer.after == nil ? wording.firstPrompt : wording.nextPrompt, text: $composerDraft)
                .textFieldStyle(.plain)
                .font(.callout.weight(.medium))
                .focused($composerFocused)
                .onSubmit { commitComposer(composer) }
                .onExitCommand { closeComposer() }
                .accessibilityIdentifier("\(wording.id)-step-field")
        }
        .padding(.horizontal, 12)
        .frame(width: layout.card.width, height: 44)
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

    /// Adds the card and keeps the field open one column to the right,
    /// wired after it, so a chain can be typed out in one go.
    private func commitComposer(_ current: StepComposer) {
        let title = composerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            closeComposer()
            return
        }
        guard let id = model.create(
            title: title,
            x: Self.snapped(current.at.x),
            y: Self.snapped(current.at.y),
            after: current.after
        ), let node = model.nodes.first(where: { $0.id == id }) else {
            NSSound.beep()
            return
        }
        openComposer(at: nextSlot(after: node), after: id)
    }

    private func closeComposer() {
        composer = nil
        composerDraft = ""
        canvasFocused = true
    }

    /// One column right of `node`, moved down past any card already there.
    private func nextSlot(after node: CanvasNode) -> CGPoint {
        freeSlot(near: CGPoint(x: node.x + layout.column, y: node.y))
    }

    private func freeSlot(near point: CGPoint) -> CGPoint {
        let nodes = model.nodes
        var slot = point
        while nodes.contains(where: {
            abs($0.x - slot.x) < layout.card.width && abs($0.y - slot.y) < layout.card.height + 12
        }) {
            slot.y += layout.row
        }
        return slot
    }

    private var viewCenter: CGPoint {
        transform.canvas(CGPoint(x: size.width / 2, y: size.height / 2))
    }

    // MARK: adding existing items

    private func drop(_ items: [String], at location: CGPoint) -> Bool {
        guard model.acceptsDrops else { return false }
        let ids = items.compactMap(UUID.init(uuidString:))
        var point = transform.canvas(location)
        var placed: UUID?
        for id in ids {
            let slot = model.nodes.contains { $0.id == id } ? point : freeSlot(near: point)
            if model.place(id, x: Self.snapped(slot.x), y: Self.snapped(slot.y)) {
                placed = id
                point.y = slot.y + layout.row
            }
        }
        if let placed { select(.node(placed)) }
        return placed != nil
    }

    private func pick(_ id: UUID) {
        let slot = freeSlot(near: viewCenter)
        guard model.place(id, x: Self.snapped(slot.x), y: Self.snapped(slot.y)) else { return }
        select(.node(id))
        reveal(slot)
    }

    // MARK: selection and keys

    private func select(_ target: CanvasSelection) {
        selection = target
        canvasFocused = true
    }

    /// Delete takes a card off the canvas (what it stands for stays) or
    /// cuts a line.
    private func deleteSelection() -> Bool {
        switch selection {
        case .node(let id):
            model.remove(id)
        case .edge(let edge):
            model.disconnect(edge)
        case nil:
            return false
        }
        selection = nil
        return true
    }

    // MARK: viewport

    private func load() {
        guard !loaded else { return }
        if let viewport = model.viewport {
            transform = CanvasTransform(viewport)
        } else {
            autoFit = true
            fit(animated: false)
        }
        loaded = true
    }

    private func fit(animated: Bool) {
        let rects = model.nodes.map(cardRect)
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

    private func arrange() {
        withAnimation(.spring(duration: 0.45)) {
            model.arrange()
        }
        fit(animated: true)
    }

    /// Pans just enough to bring a card-sized area around `point` on screen.
    private func reveal(_ point: CGPoint) {
        let screen = transform.screen(point)
        let marginX = layout.card.width * transform.scale / 2 + 24
        let marginY = layout.card.height * transform.scale / 2 + 24
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

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: wording.emptyIcon)
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(wording.emptyTitle)
                .font(.headline)
            Text(wording.emptyText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(wording.firstItem) {
                openComposer(at: viewCenter, after: nil)
            }
            .buttonStyle(PillButtonStyle(tint: Theme.focused))
            .accessibilityIdentifier("\(wording.id)-first-step")
        }
        .padding(24)
    }

    @ToolbarContentBuilder
    private func toolbar(count: Int) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                let anchor = selection.flatMap { selected -> CanvasNode? in
                    if case .node(let id) = selected { return model.nodes.first { $0.id == id } }
                    return nil
                }
                if let anchor {
                    openComposer(at: nextSlot(after: anchor), after: anchor.id)
                } else {
                    openComposer(at: freeSlot(near: viewCenter), after: nil)
                }
            } label: {
                Label(wording.newItem, systemImage: "plus.rectangle")
            }
            .help(wording.newItemHelp)
            .accessibilityIdentifier("\(wording.id)-new-step")
            Button {
                picking = true
            } label: {
                Label(wording.addExisting, systemImage: "tray.and.arrow.down")
            }
            .help(wording.addExistingHelp)
            .popover(isPresented: $picking, arrowEdge: .bottom) {
                picker { pick($0) }
            }
            .accessibilityIdentifier("\(wording.id)-add-existing")
            Button {
                arrange()
            } label: {
                Label("自动整理", systemImage: "rectangle.3.group")
            }
            .help(wording.arrangeHelp)
            .disabled(count < 2)
            .accessibilityIdentifier("\(wording.id)-arrange")
            Button {
                fit(animated: true)
            } label: {
                Label("适应窗口", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
            }
            .help("显示全部卡片（⌘0）")
            .keyboardShortcut("0", modifiers: .command)
            .accessibilityIdentifier("\(wording.id)-fit")
        }
    }
}
