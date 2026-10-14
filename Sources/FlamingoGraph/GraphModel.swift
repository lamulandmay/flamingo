import SwiftUI
import AppKit
import QuartzCore
import FlamingoCore
import FlamingoDesign

/// The canvas's invalidation signal, split from `GraphModel` so only the canvas re-renders on
/// every pan event, not the view that owns the filter field.
@MainActor
final class GraphRedraw: ObservableObject {
    /// Bumped for changes while the timeline is paused (pan, hover, filter when settled).
    @Published var revision = 0
    /// True while something moves on its own: the simulation, a fade, a camera animation.
    @Published var isAnimating = false
}

/// An eased 0...1 value. Motion is 150ms ease-out per DESIGN.md.
struct Fade {
    var from: Double = 0
    var to: Double = 0
    var start: TimeInterval = 0
    var duration: TimeInterval = Theme.Motion.fastSeconds

    func value(at t: TimeInterval) -> Double {
        let p = duration > 0 ? min(max((t - start) / duration, 0), 1) : 1
        return from + (to - from) * (1 - pow(1 - p, 3))
    }
    func isDone(at t: TimeInterval) -> Bool { t >= start + duration }
    mutating func retarget(_ target: Double, at t: TimeInterval) {
        guard target != to else { return }
        from = value(at: t); to = target; start = t
    }
}

/// Owns everything the graph canvas shows: the layout engine, camera, selection, hover, filter
/// and fades. Builds one `GraphFrame` per display frame and hands it to `GraphRenderer`.
/// The input layer drives it through `GraphInteractionTarget`.
@MainActor
final class GraphModel: ObservableObject, GraphInteractionTarget {
    enum Mode {
        /// Force layout, persisted per vault.
        case live
        /// Positions are given (the local graph's radial layout); nothing simulates.
        case fixed
    }

    let redraw = GraphRedraw()
    let renderer = GraphRenderer()
    let mode: Mode

    private(set) var graph: Graph
    private(set) var topology: GraphTopology
    private(set) var positions: [CGPoint]
    private(set) var pinned: Set<Int> = []
    private var engine: LayoutEngine?
    private var lastGeneration = -1
    private(set) var vault: Vault?

    var onSelect: (FileRef) -> Void = { _ in }
    /// Printable keys typed on the canvas. The view appends them to the filter field.
    var onType: (String) -> Void = { _ in }
    /// Esc on the canvas. The view clears the filter.
    var onEscape: () -> Void = {}
    private weak var inputView: NSView?
    /// Canvas area covered by the filter field. Tracking-area hover ignores views stacked on
    /// top, so nodes under the field must not light up.
    var occludedRect: CGRect = .null

    // Camera
    private var storedCamera = GraphCamera()
    private(set) var size: CGSize = .zero
    private var hasFitted = false
    /// Follows the layout as it blooms until the user touches the camera.
    private var autoFit: Bool
    private var cameraAnimation: (from: GraphCamera, to: GraphCamera, start: TimeInterval)?
    private var lastFrameTime: TimeInterval?
    var fitPadding: CGFloat = 48
    var fitMaxZoom: CGFloat = 2.4
    /// Every label shows regardless of zoom (the local graph is small enough).
    var alwaysShowLabels = false

    // Selection, hover, filter
    private(set) var selectedIndex: Int?
    private var hoverTarget: Int?
    private var hoverShown: Int?
    private var hoverFade = Fade()
    private var labelFade = Fade()
    private(set) var filterMask: [Bool]?
    private var filter = GraphFilter("")
    private(set) var dragging: Int?

    // MARK: Lifecycle

    /// Live graph. Positions come from the in-memory cache, then `graph-layout.json`, then seeds.
    init(graph: Graph, vault: Vault?) {
        mode = .live
        self.graph = graph
        self.vault = vault
        topology = Self.topology(for: graph, vault: vault)
        let saved = LayoutStore.cached(Self.layoutKey(vault)) ?? vault.flatMap(LayoutStore.load(from:))
        let initial = LayoutStore.initial(for: topology, saved: saved)
        positions = initial.positions
        pinned = initial.pinned
        // A restored layout is shown as it was; a fresh one blooms into frame.
        autoFit = initial.restored == 0
        makeEngine(alpha: initial.alpha)
    }

    /// Fixed positions (local graph). Call `setFixed` to replace them.
    init(fixedGraph graph: Graph, positions: [CGPoint]) {
        mode = .fixed
        self.graph = graph
        topology = GraphTopology(graph)
        self.positions = positions
        autoFit = false
    }

    deinit {
        engine?.onSettle = nil
        engine?.stop()
    }

    private static func layoutKey(_ vault: Vault?) -> String { vault?.root.path ?? "" }

    private static func topology(for graph: Graph, vault: Vault?) -> GraphTopology {
        var t = GraphTopology(graph)
        if let vault { t.markMissing(in: vault) }
        return t
    }

    private func makeEngine(alpha: Double) {
        guard mode == .live else { return }
        engine?.onSettle = nil
        engine?.stop()
        let e = LayoutEngine(topology: topology, positions: positions, pinned: pinned, alpha: alpha)
        let topo = topology, key = Self.layoutKey(vault), vault = vault
        e.onSettle = { positions, pinned in
            let saved = LayoutStore.layout(for: topo, positions: positions, pinned: pinned)
            LayoutStore.setCached(saved, for: key)
            if let vault { try? LayoutStore.save(saved, to: vault) }
        }
        engine = e
        lastGeneration = -1
        if alpha > 0 { e.start(); startFrames() }
    }

    /// A new graph from the index: keep every known position, bring new nodes in near their
    /// neighbors, relax gently.
    func update(graph newGraph: Graph) {
        guard newGraph != graph else { return }
        let old = topology
        let carried = LayoutStore.layout(for: old, positions: positions, pinned: pinned)
        let selectedID = selectedIndex.map { old.ids[$0] }
        let edgesChanged = newGraph.edges != graph.edges
        graph = newGraph
        topology = Self.topology(for: newGraph, vault: vault)
        dragging = nil
        hoverTarget = nil; hoverShown = nil; hoverFade = Fade()
        switch mode {
        case .live:
            let initial = LayoutStore.initial(for: topology, saved: carried)
            positions = initial.positions
            pinned = initial.pinned
            makeEngine(alpha: max(initial.alpha, edgesChanged ? 0.12 : 0))
        case .fixed:
            positions = Array(positions.prefix(topology.count))
        }
        selectedIndex = selectedID.flatMap { topology.index[$0] }
        filterMask = filter.mask(for: topology)
        refreshHover()
        invalidate()
    }

    /// Replaces the vault (another folder was opened in the same window).
    func reset(graph: Graph, vault: Vault?) {
        guard vault != self.vault, mode == .live else { return update(graph: graph) }
        persist()
        self.vault = vault
        self.graph = graph
        topology = Self.topology(for: graph, vault: vault)
        let saved = LayoutStore.cached(Self.layoutKey(vault)) ?? vault.flatMap(LayoutStore.load(from:))
        let initial = LayoutStore.initial(for: topology, saved: saved)
        positions = initial.positions
        pinned = initial.pinned
        selectedIndex = nil
        hoverTarget = nil; hoverShown = nil; hoverFade = Fade()
        filterMask = filter.mask(for: topology)
        autoFit = initial.restored == 0
        hasFitted = false
        cameraAnimation = nil
        if size.width > 0 { storedCamera = fitCamera(); hasFitted = true }
        makeEngine(alpha: initial.alpha)
        invalidate()
    }

    /// Fixed mode: new positions for a new graph (the local graph re-centered).
    func setFixed(graph: Graph, positions: [CGPoint], selected: Int?) {
        self.graph = graph
        topology = GraphTopology(graph)
        self.positions = positions
        selectedIndex = selected
        hoverTarget = nil; hoverShown = nil; hoverFade = Fade()
        dragging = nil
        filterMask = filter.mask(for: topology)
        if size.width > 0 { storedCamera = fitCamera(); hasFitted = true }
        refreshHover()
        invalidate()
    }

    /// Hover indices point into the old topology; look again under the pointer.
    private func refreshHover() {
        (inputView as? GraphInputNSView)?.refreshHover()
    }

    /// The view appeared again: pick up where the layout left off.
    func resume() {
        guard mode == .live, let engine else { return }
        if engine.snapshot().alpha >= 0.001 { engine.start(); startFrames() }
    }

    /// The view is going away: stop simulating and remember where everything is.
    func suspend() {
        engine?.stop()
        persist()
    }

    /// Writes the current layout to the in-memory cache and, off the main thread, to disk.
    func persist() {
        guard mode == .live else { return }
        if let engine { positions = engine.snapshot().positions }
        let saved = LayoutStore.layout(for: topology, positions: positions, pinned: pinned)
        let key = Self.layoutKey(vault)
        LayoutStore.setCached(saved, for: key)
        if let vault {
            DispatchQueue.global(qos: .utility).async { try? LayoutStore.save(saved, to: vault) }
        }
    }

    // MARK: Inputs from the view

    func select(_ ref: FileRef?) {
        let index = ref.flatMap { topology.index[$0.relativePath] }
        guard index != selectedIndex else { return }
        selectedIndex = index
        invalidate()
    }

    func setFilter(_ query: String) {
        let f = GraphFilter(query)
        guard f != filter else { return }
        filter = f
        filterMask = f.mask(for: topology)
        invalidate()
    }

    /// Return in the filter field: the selection if it matches, else the best-connected match.
    func openBestMatch() {
        if let s = selectedIndex, filterMask?[s] ?? true { return open(s) }
        guard let mask = filterMask else { return }
        var best: Int?
        for i in mask.indices where mask[i] {
            let score = topology.degree(i) + topology.commentCounts[i]
            if best == nil || score > topology.degree(best!) + topology.commentCounts[best!] { best = i }
        }
        if let best { selectedIndex = best; open(best) }
    }

    /// Hands keyboard focus back to the canvas (after Esc in the filter field).
    func focusCanvas() {
        guard let view = inputView else { return }
        view.window?.makeFirstResponder(view)
    }

    private func open(_ i: Int) {
        guard topology.ids.indices.contains(i) else { return }
        invalidate()
        onSelect(FileRef(relativePath: topology.ids[i]))
    }

    // MARK: Drawing

    /// Diagnostics: called after every draw with its duration in seconds. Harness and tests only.
    static var drawObserver: ((TimeInterval) -> Void)?

    /// What a redraw was asked for by: a display frame or an invalidation.
    struct DrawStamp: Equatable { var date: Date; var revision: Int }
    private(set) var lastStamp: DrawStamp?

    func draw(in context: inout GraphicsContext, size canvasSize: CGSize, stamp: DrawStamp) {
        lastStamp = stamp
        let start = CACurrentMediaTime()
        let frame = advance(to: start, canvasSize: canvasSize)
        renderer.draw(frame, in: &context, size: canvasSize)
        Self.drawObserver?(CACurrentMediaTime() - start)
    }

    /// Steps the simulation snapshot, camera and fades to `now`, and returns the frame to draw.
    func advance(to now: TimeInterval, canvasSize: CGSize) -> GraphFrame {
        let dt = lastFrameTime.map { min(max(now - $0, 0), 0.1) } ?? 0
        lastFrameTime = now
        if size.width <= 0, canvasSize.width > 0 { viewResized(to: canvasSize) }

        if let engine {
            let snap = engine.snapshot()
            if snap.generation != lastGeneration, snap.positions.count == topology.count {
                positions = snap.positions
                lastGeneration = snap.generation
            }
        }

        if let anim = cameraAnimation {
            let p = min(max((now - anim.start) / Theme.Motion.normalSeconds, 0), 1)
            storedCamera = anim.from.interpolated(to: anim.to, CGFloat(1 - pow(1 - p, 3)))
            if p >= 1 { cameraAnimation = nil }
        } else if autoFit, size.width > 0 {
            let target = fitCamera()
            if !hasFitted {
                storedCamera = target; hasFitted = true
            } else {
                // Critically damped follow, frame-rate independent.
                storedCamera = storedCamera.interpolated(to: target, CGFloat(1 - exp(-dt / 0.25)))
            }
        }

        let labelsWanted = alwaysShowLabels || storedCamera.zoom > GraphCamera.labelZoom
        labelFade.retarget(labelsWanted ? 1 : 0, at: now)
        let hoverAmount = hoverFade.value(at: now)
        if hoverFade.to == 0, hoverFade.isDone(at: now) { hoverShown = nil }

        let frame = GraphFrame(
            topology: topology,
            positions: positions,
            camera: storedCamera,
            selected: selectedIndex,
            hovered: dragging ?? hoverShown,
            hoverAmount: dragging != nil ? 1 : hoverAmount,
            filterMask: filterMask,
            labelAmount: labelFade.value(at: now),
            pinned: pinned,
            dragging: dragging)

        let animating = needsFrames(at: now)
        if animating != redraw.isAnimating {
            // Can't publish during a view update; settle it on the next turn, re-checking then.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let still = self.needsFrames(at: CACurrentMediaTime())
                if self.redraw.isAnimating != still { self.redraw.isAnimating = still }
            }
        }
        return frame
    }

    private func needsFrames(at now: TimeInterval) -> Bool {
        if let engine, engine.snapshot().isRunning { return true }
        if cameraAnimation != nil || dragging != nil { return true }
        if !hoverFade.isDone(at: now) || !labelFade.isDone(at: now) { return true }
        if autoFit, size.width > 0, !storedCamera.isClose(to: fitCamera()) { return true }
        return false
    }

    private func startFrames() {
        if !redraw.isAnimating { redraw.isAnimating = true }
    }

    private func invalidate() {
        if !redraw.isAnimating { redraw.revision &+= 1 }
    }

    private func fitCamera() -> GraphCamera {
        GraphCamera.fitting(positions, radii: topology.radius, in: size, padding: fitPadding,
                            horizontalPadding: alwaysShowLabels ? fitPadding + edgeLabelHalfWidth() : nil,
                            maxZoom: fitMaxZoom)
    }

    /// Half the widest label among the leftmost and rightmost nodes: room the fit must leave so
    /// labels that are always on don't run off the canvas.
    private func edgeLabelHalfWidth() -> CGFloat {
        guard let left = positions.indices.min(by: { positions[$0].x < positions[$1].x }),
              let right = positions.indices.max(by: { positions[$0].x < positions[$1].x }) else { return 0 }
        let font = Theme.NS.small
        func half(_ i: Int) -> CGFloat {
            let label = LabelLayout.truncated(topology.labels[i], limit: GraphRenderer.Style.labelMaxCharacters)
            return (label as NSString).size(withAttributes: [.font: font]).width / 2
        }
        return max(half(left), half(right))
    }

    private func animateCamera(to target: GraphCamera) {
        cameraAnimation = (storedCamera, target, CACurrentMediaTime())
        startFrames()
        invalidate()
    }

    /// Pans just enough to bring a node inside the view, with a margin.
    private func reveal(_ i: Int) {
        guard size.width > 0, positions.indices.contains(i) else { return }
        let s = storedCamera.toScreen(positions[i], size: size)
        let inset = min(64, size.width / 4, size.height / 4)
        var dx: CGFloat = 0, dy: CGFloat = 0
        if s.x < inset { dx = s.x - inset } else if s.x > size.width - inset { dx = s.x - (size.width - inset) }
        if s.y < inset { dy = s.y - inset } else if s.y > size.height - inset { dy = s.y - (size.height - inset) }
        guard dx != 0 || dy != 0 else { return }
        var target = storedCamera
        target.center.x += dx / target.zoom
        target.center.y += dy / target.zoom
        autoFit = false
        animateCamera(to: target)
    }

    // MARK: GraphInteractionTarget

    var camera: GraphCamera {
        get { storedCamera }
        set {
            guard newValue != storedCamera else { return }
            storedCamera = newValue
            invalidate()
        }
    }

    func inputViewAttached(_ view: NSView) { inputView = view }

    func viewResized(to newSize: CGSize) {
        guard newSize != size, newSize.width > 0, newSize.height > 0 else { return }
        size = newSize
        if !hasFitted || (mode == .fixed && cameraAnimation == nil) {
            storedCamera = fitCamera()
            hasFitted = true
        }
        invalidate()
    }

    func node(atScreen p: CGPoint) -> Int? {
        guard size.width > 0, !occludedRect.contains(p) else { return nil }
        let zoom = storedCamera.zoom
        var best: (index: Int, score: CGFloat)?
        for i in positions.indices {
            let s = storedCamera.toScreen(positions[i], size: size)
            let dx = s.x - p.x, dy = s.y - p.y
            let reach = max(GraphRenderer.screenRadius(worldRadius: topology.radius[i], zoom: zoom) + 4, 7)
            guard abs(dx) <= reach, abs(dy) <= reach else { continue }
            let d = (dx * dx + dy * dy).squareRoot()
            guard d <= reach else { continue }
            // Prefer what the filter left lit over what it dimmed.
            let score = d + ((filterMask?[i] ?? true) ? 0 : 1000)
            if best == nil || score < best!.score { best = (i, score) }
        }
        return best?.index
    }

    func worldPosition(of node: Int) -> CGPoint {
        positions.indices.contains(node) ? positions[node] : .zero
    }

    func isPinned(_ node: Int) -> Bool { pinned.contains(node) }

    func hover(_ node: Int?) {
        guard node != hoverTarget else { return }
        hoverTarget = node
        let now = CACurrentMediaTime()
        if let node {
            hoverShown = node
            hoverFade.retarget(1, at: now)
        } else {
            hoverFade.retarget(0, at: now)
        }
        startFrames()
        invalidate()
    }

    func click(_ node: Int) {
        guard topology.ids.indices.contains(node) else { return }
        selectedIndex = node
        open(node)
    }

    func beginNodeDrag(_ node: Int) {
        guard positions.indices.contains(node) else { return }
        dragging = node
        if mode == .live {
            pinned.insert(node)
            engine?.beginDrag(node)
        }
        startFrames()
        invalidate()
    }

    func dragNode(_ node: Int, toWorld p: CGPoint) {
        guard positions.indices.contains(node) else { return }
        positions[node] = p
        engine?.drag(node, to: p)
        invalidate()
    }

    func endNodeDrag(_ node: Int) {
        engine?.endDrag(node)
        dragging = nil
        invalidate()
    }

    func unpin(_ node: Int) {
        guard pinned.remove(node) != nil else { return }
        engine?.unpin(node)
        startFrames()
        invalidate()
    }

    func fitAll() {
        guard size.width > 0 else { return }
        animateCamera(to: fitCamera())
    }

    func userMovedCamera() {
        autoFit = false
        cameraAnimation = nil
    }

    func moveSelection(_ direction: GraphDirection) {
        let next: Int?
        if let s = selectedIndex, positions.indices.contains(s) {
            next = GraphNavigation.next(from: s, direction, positions: positions, topology: topology, eligible: filterMask)
        } else {
            next = GraphNavigation.nearest(to: storedCamera.center, positions: positions, eligible: filterMask)
        }
        guard let next else { return }
        selectedIndex = next
        reveal(next)
        invalidate()
    }

    func openSelection() {
        if let s = selectedIndex { open(s) }
    }

    func type(_ text: String) { onType(text) }

    func escape() { onEscape() }
}

extension GraphCamera {
    /// Within half a point and a tenth of a percent of zoom.
    func isClose(to other: GraphCamera) -> Bool {
        abs(zoom / other.zoom - 1) < 0.001
            && abs(center.x - other.center.x) * zoom < 0.5
            && abs(center.y - other.center.y) * zoom < 0.5
    }
}
