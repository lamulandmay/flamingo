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

/// An eased 0...1 value, on the same spring as `Theme.Motion.fast`.
struct Fade {
    var from: Double = 0
    var to: Double = 0
    var start: TimeInterval = 0
    var duration: TimeInterval = Theme.Motion.fastSeconds

    func value(at t: TimeInterval) -> Double {
        let p = duration > 0 ? min(max((t - start) / duration, 0), 1) : 1
        return from + (to - from) * Theme.Motion.settle(p)
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
        /// Persisted layout: force layout for small scopes, stable hierarchy for large maps.
        case live
        /// Positions are given (the local graph's radial layout); nothing simulates.
        case fixed
    }

    let redraw = GraphRedraw()
    let renderer = GraphRenderer()
    let mode: Mode
    weak var actionHistory: ActionHistory?
    private var dragStartLayout: SavedLayout?

    private(set) var graph: Graph
    private(set) var topology: GraphTopology
    private(set) var positions: [CGPoint]
    private(set) var pinned: Set<Int> = []
    private var engine: LayoutEngine?
    private var lastGeneration = -1
    private(set) var vault: Vault?
    /// The full graph from the index. `graph` is what's shown: the whole thing, or `scope`'s folder.
    private var source = Graph()
    /// Relative folder path the view is scoped to; nil shows the whole graph.
    private(set) var scope: String?
    /// Folder budget for a scoped graph so `~` doesn't become ten thousand dots.
    var scopeBudget = 400
    private var neighborBudget = 120
    /// See `GraphArrangement`. Anything but organic is worked out from the folders and never
    /// saved, which leaves the saved force layout as it was for when organic comes back.
    @Published private(set) var arrangement: GraphArrangement
    var onArrangementChange: (GraphArrangement) -> Void = { _ in }
    private var arrangementGeneration = 0
    /// Where the arrangement puts each node; nil while organic.
    private(set) var slots: [CGPoint]?
    /// Nodes on their way somewhere: the whole canvas after a change of arrangement or a new
    /// graph in one.
    private var glide: Glide?
    /// In an arrangement, the node just let go, springing back to its place.
    private var drop: (node: Int, from: CGPoint, start: TimeInterval)?

    var onSelect: (FileRef) -> Void = { _ in }
    var onSelectionChange: (FileRef?) -> Void = { _ in }
    var onScopeChange: (String?) -> Void = { _ in }
    var onConnectionsChanged: () -> Void = {}
    enum ConnectionMode: String { case browse, add, remove }
    @Published private(set) var connectionMode = ConnectionMode.browse
    @Published private(set) var chosenIDs = Set<String>()
    @Published private(set) var selectionPath: String?
    @Published private(set) var connectionError: String?
    @Published private(set) var connectionBusy = false
    @Published private(set) var scopeIsTruncated = false
    @Published private(set) var isPreparing = false
    @Published private(set) var manualConnections: [ManualConnection] = []
    private var scopeGeneration = 0
    private var vaultGeneration = 0
    private var connectionsGeneration = 0
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
    private var cameraAnimation: (from: GraphCamera, to: GraphCamera, start: TimeInterval, duration: TimeInterval)?
    private var cameraChangeStart: GraphCamera?
    private var cameraChangeRecord: GraphCameraChange?
    private var cameraChangeTask: Task<Void, Never>?
    private var lastFrameTime: TimeInterval?
    var fitPadding: CGFloat = 48
    var fitMaxZoom: CGFloat = 2.4
    /// Every label shows regardless of zoom (the local graph is small enough).
    var alwaysShowLabels = false
    /// See `GraphFrame.calm`. Off for the local graph, which is all neighborhood.
    var calm = true
    /// See `GraphFrame.labelLimit`; names go in node order when set (the local graph's
    /// strongest neighbors come first).
    var labelLimit: Int?

    // Selection, hover, filter
    private(set) var selectedIndex: Int?
    /// The file the shell asked us to select, kept so it survives graph loads and vault resets.
    private var requestedSelection: FileRef?
    private var hoverTarget: Int?
    private var hoverShown: Int?
    private var hoverFade = Fade()
    private var labelFade = Fade()
    private(set) var filterMask: [Bool]? { didSet { filterVersion &+= 1 } }
    private var filterVersion = 0
    private var filter = GraphFilter("")
    private(set) var dragging: Int?
    private var pulse: (node: Int, start: TimeInterval)?
    static let pulseSeconds: TimeInterval = 0.5
    /// A connection being shown off: see `celebrate(from:to:level:zoom:)`.
    private var celebration: Celebration?
    /// The ends of a celebration never reached the canvas (out of scope, or no rebuild came).
    var onCelebrationMissed: (FileRef, [FileRef], Int) -> Void = { _, _, _ in }
    /// A celebration finished drawing.
    var onCelebrationEnded: () -> Void = {}
    /// Zoom a click settles at when the graph is further out than this.
    var clickZoom: CGFloat = 1.8

    // MARK: Lifecycle

    /// Live graph. Positions come from the in-memory cache, then `graph-layout.json`, then seeds.
    init(graph: Graph, vault: Vault?, arrangement: GraphArrangement = .organic) {
        mode = .live
        self.arrangement = arrangement
        self.source = graph
        // Whole-Mac catalogs, including layout, are prepared off the UI actor; so is every
        // arrangement, which needs the folders the scoped graph adds.
        let deferred = graph.nodes.count > GraphOverviewLayout.threshold || arrangement != .organic
        let displayed = deferred ? Graph() : graph
        self.graph = displayed
        graphFingerprint = Self.fingerprint(displayed)
        isPreparing = deferred
        self.vault = vault
        topology = GraphTopology(displayed)
        let saved = deferred ? nil : (LayoutStore.cached(Self.layoutKey(vault)) ?? vault.flatMap(LayoutStore.load(from:)))
        if let saved { LayoutStore.setCached(saved, for: Self.layoutKey(vault)) }
        let initial = LayoutStore.initial(for: topology, saved: saved)
        positions = initial.positions
        pinned = initial.pinned
        // A restored layout is shown as it was; a fresh one blooms into frame.
        autoFit = initial.restored == 0
        makeEngine(alpha: initial.alpha)
        if deferred {
            Task { [weak self] in
                guard let self, self.scopeGeneration == 0 else { return }
                self.refreshScope()
            }
        }
    }

    /// Fixed positions (local graph). Call `setFixed` to replace them.
    init(fixedGraph graph: Graph, positions: [CGPoint]) {
        mode = .fixed
        arrangement = .organic
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

    nonisolated private static func topology(for graph: Graph, vault: Vault?) -> GraphTopology {
        var t = GraphTopology(graph)
        if let vault { t.markMissing(in: vault) }
        return t
    }

    private func makeEngine(alpha: Double) {
        guard mode == .live else { return }
        engine?.onSettle = nil
        engine?.stop()
        engine = nil
        // Hidden folder detail must not become a hundred-thousand-body simulation.
        // Large maps use a stable folder layout; small scopes retain force layout.
        guard arrangement == .organic, topology.count <= GraphOverviewLayout.threshold else { return }
        let e = LayoutEngine(topology: topology, positions: positions, pinned: pinned, alpha: alpha)
        let topo = topology, key = Self.layoutKey(vault), vault = vault
        e.onSettle = { positions, pinned in
            let saved = LayoutStore.layout(for: topo, positions: positions, pinned: pinned)
            LayoutStore.remember(saved, key: key, vault: vault)
        }
        engine = e
        lastGeneration = -1
        if alpha > 0 { e.start(); startFrames() }
    }

    /// A new graph from the index: keep every known position, bring new nodes in near their
    /// neighbors, relax gently.
    func update(graph newGraph: Graph) {
        source = newGraph
        if mode == .fixed { show(newGraph); return }
        refreshScope()
    }

    /// Scope the graph to a folder (relative path, "" for the vault root) or nil for everything.
    func setScope(_ folder: String?) {
        guard folder != scope else { return }
        scope = folder
        refreshScope()
    }

    /// Filesystem enumeration and missing-file checks run outside the UI actor. The token
    /// prevents an older folder or vault result from replacing a more recent selection.
    func refreshScope() {
        isPreparing = true
        scopeGeneration += 1
        let generation = scopeGeneration, source = source, scope = scope, vault = vault
        let budget = scopeBudget, selected = requestedSelection, neighborBudget = neighborBudget
        let oldTopology = topology, oldPositions = engine?.snapshot().positions ?? restingPositions, oldPins = pinned
        let key = Self.layoutKey(vault), cached = LayoutStore.cached(Self.layoutKey(vault))
        let arrangement = arrangement
        Task { [weak self] in
            let prepared = await Task.detached(priority: .userInitiated) {
                let result = Self.scopedResult(source, to: scope, in: vault, budget: budget,
                                               including: selected.map { [$0.relativePath] } ?? [], neighborBudget: neighborBudget)
                let topology = Self.topology(for: result.graph, vault: vault)
                let fingerprint = Self.fingerprint(result.graph)
                // An arrangement's places are not the force layout's, so they are never carried.
                let snapshot = arrangement == .organic
                    ? LayoutStore.layout(for: oldTopology, positions: oldPositions, pinned: oldPins)
                    : SavedLayout(nodes: [:], pinned: [])
                let carried = LayoutStore.merging(snapshot, into: cached ?? vault.flatMap(LayoutStore.load(from:)))
                let initial = Self.initialLayout(for: topology, arrangement: arrangement, saved: carried)
                return (result.graph, topology, result.truncated, initial, carried, fingerprint)
            }.value
            guard let self, generation == self.scopeGeneration else { return }
            // Laid out for an arrangement that has since changed: lay it out again.
            guard arrangement == self.arrangement else { return self.refreshScope() }
            self.isPreparing = false
            self.scopeIsTruncated = prepared.2
            LayoutStore.setCached(prepared.4, for: key)
            self.show(prepared.0, preparedTopology: prepared.1, preparedLayout: prepared.3, fingerprint: prepared.5)
        }
    }

    /// Hashes of the displayed graph (everything, and edges alone), so a new graph from the
    /// index is compared in O(1) on the main actor rather than element by element.
    private var graphFingerprint: (all: Int, edges: Int)?

    nonisolated static func fingerprint(_ g: Graph) -> (all: Int, edges: Int) {
        var e = Hasher()
        for x in g.edges { e.combine(x.source); e.combine(x.target); e.combine(x.kind); e.combine(x.weight) }
        let edges = e.finalize()
        var a = Hasher()
        for n in g.nodes { a.combine(n.id); a.combine(n.commentCount); a.combine(n.ext) }
        a.combine(edges)
        return (a.finalize(), edges)
    }

    private func show(_ newGraph: Graph, preparedTopology: GraphTopology? = nil,
                      preparedLayout: LayoutStore.Initial? = nil, fingerprint: (all: Int, edges: Int)? = nil) {
        let fp = fingerprint ?? Self.fingerprint(newGraph)
        if let current = graphFingerprint, current.all == fp.all {
            if let preparedTopology { topology = preparedTopology; invalidate() }
            return
        }
        if let engine { positions = engine.snapshot().positions }
        // Organic was gliding back to its saved places: those are the ones to keep. An
        // arrangement carries on from wherever its nodes have got to.
        if arrangement == .organic { positions = restingPositions }
        glide = nil; drop = nil
        let old = topology, oldPositions = positions
        var carried: SavedLayout?
        if preparedLayout == nil, arrangement == .organic {
            let snapshot = LayoutStore.layout(for: old, positions: positions, pinned: pinned)
            carried = mode == .live ? LayoutStore.remember(snapshot, key: Self.layoutKey(vault), vault: vault) : snapshot
        }
        let selectedID = selectedIndex.map { old.ids[$0] }
        let edgesChanged = fp.edges != graphFingerprint?.edges
        graphFingerprint = fp
        graph = newGraph
        topology = preparedTopology ?? GraphTopology(newGraph)
        dragging = nil
        hoverTarget = nil; hoverShown = nil; hoverFade = Fade()
        switch mode {
        case .live where arrangement != .organic:
            let initial = preparedLayout ?? Self.initialLayout(for: topology, arrangement: arrangement, saved: nil)
            pinned = []
            arrange(initial.positions, after: old, at: oldPositions)
        case .live:
            let initial = preparedLayout ?? Self.initialLayout(for: topology, arrangement: arrangement, saved: carried)
            positions = initial.positions
            pinned = initial.pinned
            slots = nil
            // New edges among files already placed don't stir the layout: the graph stays put
            // under you while the index works. Only newcomers need room made for them.
            let nodesAdded = topology.ids.contains { old.index[$0] == nil }
            makeEngine(alpha: max(initial.alpha, edgesChanged && nodesAdded ? 0.12 : 0))
            if topology.count > GraphOverviewLayout.threshold {
                if old.count == 0, size.width > 0 { storedCamera = fitCamera(); hasFitted = true }
                autoFit = false
            }
        case .fixed:
            positions = Array(positions.prefix(topology.count))
        }
        selectedIndex = selectedID.flatMap { topology.index[$0] }
            ?? requestedSelection.flatMap { topology.index[$0.relativePath] }
        selectionPath = selectedIndex.map { topology.ids[$0] }
        filterMask = filter.mask(for: topology)
        refreshHover()
        invalidate()
    }

    /// Replaces the vault (another folder was opened in the same window).
    func reset(graph: Graph, vault: Vault?) {
        guard vault != self.vault, mode == .live else { return update(graph: graph) }
        finishCameraChange()
        persist()
        scopeGeneration += 1; vaultGeneration += 1
        self.vault = vault
        self.source = graph
        chosenIDs = []; connectionMode = .browse; manualConnections = []; connectionError = nil
        glide = nil; drop = nil; slots = nil
        let deferred = graph.nodes.count > GraphOverviewLayout.threshold || arrangement != .organic
        let displayed = deferred ? Graph() : graph
        self.graph = displayed
        graphFingerprint = Self.fingerprint(displayed)
        topology = GraphTopology(displayed)
        let saved = deferred ? nil : (LayoutStore.cached(Self.layoutKey(vault)) ?? vault.flatMap(LayoutStore.load(from:)))
        if let saved { LayoutStore.setCached(saved, for: Self.layoutKey(vault)) }
        let initial = LayoutStore.initial(for: topology, saved: saved)
        positions = initial.positions
        pinned = initial.pinned
        selectedIndex = requestedSelection.flatMap { topology.index[$0.relativePath] }
        hoverTarget = nil; hoverShown = nil; hoverFade = Fade()
        filterMask = filter.mask(for: topology)
        autoFit = initial.restored == 0
        hasFitted = false
        cameraAnimation = nil
        if size.width > 0 { storedCamera = fitCamera(); hasFitted = true }
        makeEngine(alpha: initial.alpha)
        refreshScope(); loadConnections()
        invalidate()
    }

    /// Fixed mode: new positions for a new graph (the local graph re-centered).
    func setFixed(graph: Graph, positions: [CGPoint], selected: Int?) {
        self.graph = graph
        graphFingerprint = Self.fingerprint(graph)
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
        finishCameraChange()
        engine?.stop()
        persist()
    }

    /// Writes the current layout to the in-memory cache and, off the main thread, to disk.
    func persist() {
        guard mode == .live, arrangement == .organic else { return }
        if let engine { positions = engine.snapshot().positions }
        let saved = LayoutStore.layout(for: topology, positions: restingPositions, pinned: pinned)
        let key = Self.layoutKey(vault)
        LayoutStore.remember(saved, key: key, vault: vault)
    }

    // MARK: Inputs from the view

    func select(_ ref: FileRef?) {
        // The shell clears its file after a folder click; retain that folder's highlight.
        if ref == nil, let selectedIndex, topology.isFolder[selectedIndex] {
            requestedSelection = nil
            return
        }
        requestedSelection = ref
        selectionPath = ref?.relativePath
        let index = ref.flatMap { topology.index[$0.relativePath] }
        if ref != nil, index == nil, mode == .live { refreshScope() }
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
        guard topology.ids.indices.contains(i), connectionMode == .browse else { return }
        invalidate()
        if topology.isFolder[i] {
            let id = topology.ids[i]
            let folder = id == "/" ? "" : String(id.dropLast())
            setScope(folder)
            onScopeChange(folder)
            return
        }
        onSelect(FileRef(relativePath: topology.ids[i]))
    }

    /// The folder's subtree as a graph: a hollow node per folder, a dot per file, `folder` edges
    /// for containment, plus every link or trail edge touching the subtree with its far end
    /// brought in. Breadth-first so a huge folder shows its top levels and stops at `budget`.
    nonisolated static func scoped(_ g: Graph, to scope: String?, in vault: Vault?, budget: Int,
                                  including required: Set<String> = []) -> Graph {
        scopedResult(g, to: scope, in: vault, budget: budget, including: required).graph
    }

    nonisolated static func scopedResult(_ g: Graph, to scope: String?, in vault: Vault?, budget: Int,
                                        including required: Set<String> = [], neighborBudget: Int = 120) -> (graph: Graph, truncated: Bool) {
        let byID = Dictionary(g.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func fileNode(_ p: String) -> Graph.Node {
            byID[p] ?? Graph.Node(id: p, name: (p as NSString).lastPathComponent,
                                  ext: (p as NSString).pathExtension.lowercased())
        }
        guard let scope, let vault else {
            var all = g
            for p in required.sorted() where byID[p] == nil { all.nodes.append(fileNode(p)) }
            if vault != nil {
                all = GraphFolders.addingAncestors(to: all)
                if let root = all.nodes.firstIndex(where: { $0.id == "/" }), let vault {
                    all.nodes[root].name = vault.root.lastPathComponent
                }
            }
            return (all, false)
        }
        let ignore = VaultScanner.ignoreRules(in: vault)
        func folderID(_ p: String) -> String { p.isEmpty ? "/" : p + "/" }
        func folderNode(_ p: String) -> Graph.Node {
            Graph.Node(id: folderID(p), name: p.isEmpty ? vault.root.lastPathComponent : (p as NSString).lastPathComponent, ext: "")
        }
        var nodes: [Graph.Node] = [folderNode(scope)], edges: [Graph.Edge] = []
        var seen: Set<String> = [folderID(scope)]
        var queue = [scope], head = 0, truncated = false
        let limit = max(1, budget)
        while head < queue.count {
            let f = queue[head]; head += 1
            for child in VaultScanner.children(of: f, in: vault, ignore: ignore) {
                let id = child.isFolder ? folderID(child.id) : child.id
                guard !seen.contains(id) else { continue }
                guard nodes.count < limit else { truncated = true; break }
                seen.insert(id)
                if child.isFolder { nodes.append(folderNode(child.id)); queue.append(child.id) }
                else { nodes.append(byID[id] ?? Graph.Node(id: id, name: child.name, ext: child.ref?.ext ?? "")) }
                edges.append(Graph.Edge(source: folderID(f), target: id, kind: .folder))
            }
            if truncated { break }
        }
        for p in required.sorted() where !seen.contains(p) {
            nodes.append(fileNode(p)); seen.insert(p)
            let parent = (p as NSString).deletingLastPathComponent
            if seen.contains(folderID(parent)) { edges.append(.init(source: folderID(parent), target: p, kind: .folder)) }
        }
        // Eligibility is the original subtree, never the outside nodes added in this loop.
        // Sorting also makes the 120-neighbor budget deterministic regardless of index order.
        let inside = seen
        var outside = 0
        let relevant = g.edges.filter { $0.kind != .folder && (inside.contains($0.source) || inside.contains($0.target)) }
            .sorted { ($0.source, $0.target, $0.kind.rawValue) < ($1.source, $1.target, $1.kind.rawValue) }
        for e in relevant {
            for far in [e.source, e.target] where !seen.contains(far) {
                guard let n = byID[far] else { continue }
                guard outside < neighborBudget else { truncated = true; continue }
                nodes.append(n); seen.insert(far); outside += 1
            }
            if seen.contains(e.source), seen.contains(e.target) { edges.append(e) }
        }
        // The file budget limits dots, not the folder map. Keep indexed descendants even
        // when breadth-first enumeration stops, so zoom can reveal every known folder.
        let prefix = scope.isEmpty ? "" : scope + "/"
        let folders = g.nodes.filter { $0.id.hasSuffix("/") && (scope.isEmpty || $0.id.hasPrefix(prefix)) }
        let expanded = GraphFolders.addingAncestors(to: Graph(nodes: nodes, edges: edges), from: folders)
        let retained = Set(nodes.map(\.id)).union(expanded.nodes.filter {
            $0.id.hasSuffix("/") && (scope.isEmpty || $0.id.hasPrefix(prefix))
        }.map(\.id))
        return (Graph(nodes: expanded.nodes.filter { retained.contains($0.id) },
                      edges: expanded.edges.filter { retained.contains($0.source) && retained.contains($0.target) }), truncated)
    }

    func showMore() { scopeBudget *= 2; neighborBudget *= 2; refreshScope() }

    func setConnectionMode(_ mode: ConnectionMode) {
        connectionMode = mode; connectionError = nil
        if chosenIDs.isEmpty, let selected = requestedSelection { chosenIDs.insert(selected.relativePath) }
        invalidate()
    }

    func clearConnectionsSelection() {
        let wasChoosing = connectionMode != .browse || !chosenIDs.isEmpty
        connectionMode = .browse; chosenIDs = []
        if wasChoosing, let selectedIndex { publishSelection(selectedIndex) }
        invalidate()
    }

    func loadConnections() {
        guard let vault else { return }
        connectionsGeneration += 1
        let request = connectionsGeneration
        let generation = vaultGeneration
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Result { try ConnectionStore(vault: vault).all() } }.value
            guard let self, generation == self.vaultGeneration, request == self.connectionsGeneration else { return }
            switch result {
            case .success(let records): self.manualConnections = records
            case .failure(let error): self.connectionError = "Could not load connections: " + error.localizedDescription
            }
        }
    }

    func applyConnections(label: String? = nil) {
        guard let vault, chosenIDs.count >= 2, connectionMode != .browse, !connectionBusy else { return }
        finishCameraChange()
        let refs = chosenIDs.sorted().map { FileRef(relativePath: $0) }
        let connected = connectionMode == .add, generation = vaultGeneration
        let historyContext = actionHistory?.contextID
        connectionsGeneration += 1
        connectionBusy = true; connectionError = nil
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try ConnectionStore(vault: vault).setConnectionsUndoably(between: refs, connected: connected, label: label)
                }
            }.value
            guard let self else { return }
            self.connectionBusy = false
            guard generation == self.vaultGeneration, historyContext == self.actionHistory?.contextID else { return }
            switch result {
            case .success(let (before, after)):
                self.connectionsDidChange(after)
                if before != after {
                    self.actionHistory?.register(name: connected ? "Connect files" : "Remove connections", undo: {
                        guard generation == self.vaultGeneration else { throw GraphUndoError.vaultChanged }
                        try ConnectionStore(vault: vault).replaceConnections(before, expecting: after)
                        self.connectionsDidChange(before)
                    }, redo: {
                        guard generation == self.vaultGeneration else { throw GraphUndoError.vaultChanged }
                        try ConnectionStore(vault: vault).replaceConnections(after, expecting: before)
                        self.connectionsDidChange(after)
                    })
                }
            case .failure(let error): self.connectionError = "Could not save connections: " + error.localizedDescription
            }
        }
    }

    private func connectionsDidChange(_ records: [ManualConnection]) {
        connectionsGeneration += 1
        manualConnections = records
        source.edges.removeAll { $0.kind == .manual }
        source.edges.append(contentsOf: records.map(\.edge))
        refreshScope(); onConnectionsChanged()
    }

    func resetVisibleLayout() {
        guard arrangement == .organic else { return }
        finishCameraChange()
        let before = layoutSnapshot()
        pinned = []
        let overview = topology.count > GraphOverviewLayout.threshold
        positions = overview ? GraphOverviewLayout.initial(for: topology, saved: nil).positions
            : topology.ids.map { LayoutStore.seededPosition(id: $0, count: topology.count) }
        let after = layoutSnapshot(syncEngine: false)
        makeEngine(alpha: 1); persist(); autoFit = !overview
        if overview { storedCamera = fitCamera() }
        invalidate()
        registerLayoutChange("Reset graph layout", before: before, after: after)
    }

    func unpinSelection() { if let selectedIndex { unpin(selectedIndex); persist() } }

    var selectedEdges: [Graph.Edge] {
        guard let selectionPath else { return [] }
        return graph.edges.filter { $0.source == selectionPath || $0.target == selectionPath }
            .sorted { ($0.kind.rawValue, $0.source, $0.target) < ($1.kind.rawValue, $1.source, $1.target) }
    }

    private func publishSelection(_ node: Int, notify: Bool = true) {
        selectionPath = topology.ids[node]
        requestedSelection = topology.isFolder[node] ? nil : FileRef(relativePath: topology.ids[node])
        if notify, connectionMode == .browse { onSelectionChange(requestedSelection) }
    }

    // MARK: Arrangement

    /// Where a layout starts: an arrangement worked out from the folders, or for organic the
    /// saved force layout (a whole-disk map packs its hierarchy instead of simulating).
    nonisolated static func initialLayout(for topology: GraphTopology, arrangement: GraphArrangement,
                                          saved: SavedLayout?) -> LayoutStore.Initial {
        if arrangement != .organic { return ArrangedLayout.initial(for: topology, arrangement: arrangement) }
        return topology.count > GraphOverviewLayout.threshold
            ? GraphOverviewLayout.initial(for: topology, saved: saved)
            : LayoutStore.initial(for: topology, saved: saved)
    }

    /// Where everything is headed: a glide's destination while one runs. What gets saved.
    private var restingPositions: [CGPoint] {
        if let glide, glide.to.count == positions.count { return glide.to }
        return positions
    }

    /// Lays the canvas out another way. Every node glides to its new place, and organic comes
    /// back exactly as it was left, pins and all.
    func setArrangement(_ new: GraphArrangement, notify: Bool = true) {
        guard new != arrangement else { return }
        if mode == .live {
            finishCameraChange()
            // Leaving organic: remember the force layout first, while it is still on screen.
            persist()
            engine?.onSettle = nil; engine?.stop(); engine = nil
        }
        arrangement = new
        if mode == .live { rearrange() }
        if notify { onArrangementChange(new) }
    }

    private func rearrange() {
        arrangementGeneration += 1
        let generation = arrangementGeneration, topology = topology, arrangement = arrangement
        let fingerprint = graphFingerprint?.all, key = Self.layoutKey(vault), vault = vault
        Task { [weak self] in
            let initial = await Task.detached(priority: .userInitiated) {
                let saved = arrangement == .organic ? LayoutStore.cached(key) ?? vault.flatMap(LayoutStore.load(from:)) : nil
                return Self.initialLayout(for: topology, arrangement: arrangement, saved: saved)
            }.value
            // A new graph in the meantime was laid out for this arrangement when it was shown.
            guard let self, generation == self.arrangementGeneration, fingerprint == self.graphFingerprint?.all,
                  initial.positions.count == self.topology.count else { return }
            self.rearranged(initial)
        }
    }

    private func rearranged(_ initial: LayoutStore.Initial) {
        // Mid-glide, nodes turn toward the new places from wherever they have got to.
        glide = nil; drop = nil
        pinned = initial.pinned
        autoFit = false
        if arrangement == .organic {
            slots = nil
            guard initial.alpha < 1 else {
                // No force layout saved yet: it grows out of the arrangement on screen.
                makeEngine(alpha: 1)
                autoFit = true
                invalidate()
                return
            }
            startGlide(to: initial.positions, engineAlpha: initial.alpha)
        } else {
            slots = initial.positions
            startGlide(to: initial.positions, engineAlpha: nil)
        }
        guard size.width > 0 else { return }
        let now = CACurrentMediaTime()
        cameraAnimation = (storedCamera, fitCamera(initial.positions), now, max((glide?.end ?? now) - now, Theme.Motion.normalSeconds))
        startFrames()
    }

    /// A new graph in an arrangement: what was already on the canvas glides to its new place
    /// and newcomers leave from their folder, so a new file is seen joining it.
    private func arrange(_ target: [CGPoint], after old: GraphTopology, at oldPositions: [CGPoint]) {
        makeEngine(alpha: 0)
        slots = target
        autoFit = false
        guard old.count > 0 else {
            positions = target
            if size.width > 0 { storedCamera = fitCamera(); hasFitted = true }
            return
        }
        positions = target.indices.map { i in
            if let j = old.index[topology.ids[i]], oldPositions.indices.contains(j) { return oldPositions[j] }
            if let parent = GraphOverviewLayout.parentIndex(of: i, in: topology),
               let j = old.index[topology.ids[parent]], oldPositions.indices.contains(j) { return oldPositions[j] }
            return target[i]
        }
        startGlide(to: target, engineAlpha: nil)
    }

    static let glideSeconds: TimeInterval = 0.6
    /// The outermost node leaves this much after the innermost, so a new layout opens outward.
    static let glideStagger: TimeInterval = 0.18
    static let dropSeconds: TimeInterval = 0.8

    /// Glides every node from where it is to `target`. Organic simulates again once everything
    /// has arrived, from `engineAlpha`.
    private func startGlide(to target: [CGPoint], engineAlpha: Double?) {
        let from = positions
        let moved = from.count == target.count
            && zip(from, target).contains { abs($0.x - $1.x) > 0.5 || abs($0.y - $1.y) > 0.5 }
        guard moved else {
            positions = target
            if let engineAlpha { makeEngine(alpha: engineAlpha) }
            invalidate()
            return
        }
        let now = CACurrentMediaTime(), reduced = Theme.Motion.reduced
        var delay = [Double](repeating: 0, count: target.count)
        if !reduced {
            var cx: CGFloat = 0, cy: CGFloat = 0
            for p in target { cx += p.x; cy += p.y }
            cx /= CGFloat(target.count); cy /= CGFloat(target.count)
            let distance = target.map { Double(hypot($0.x - cx, $0.y - cy)) }
            let farthest = max(distance.max() ?? 0, 1)
            delay = distance.map { Self.glideStagger * $0 / farthest }
        }
        let duration = reduced ? Theme.Motion.normalSeconds : Self.glideSeconds
        glide = Glide(from: from, to: target, start: now, delay: delay, duration: duration,
                      end: now + duration + (delay.max() ?? 0), engineAlpha: engineAlpha, reduced: reduced)
        startFrames()
        invalidate()
    }

    /// Steps a glide and a dropped node's spring home. Called while drawing, so starting the
    /// simulation after an organic glide waits for the next turn.
    private func advanceGlide(to now: TimeInterval) {
        if let g = glide {
            if now >= g.end || g.to.count != topology.count {
                glide = nil
                if g.to.count == topology.count { positions = g.to }
                if let alpha = g.engineAlpha {
                    let token = topology.token
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.topology.token == token, self.arrangement == .organic,
                              self.engine == nil, self.glide == nil else { return }
                        self.makeEngine(alpha: alpha)
                    }
                }
            } else {
                positions = g.positions(at: now)
            }
        }
        if let d = drop {
            guard let slots, slots.indices.contains(d.node), positions.indices.contains(d.node),
                  slots.count == positions.count else { drop = nil; return }
            let t = now - d.start
            guard t < Self.dropSeconds else { positions[d.node] = slots[d.node]; drop = nil; return }
            let k = CGFloat(Self.arrive(t))
            positions[d.node] = CGPoint(x: d.from.x + (slots[d.node].x - d.from.x) * k,
                                        y: d.from.y + (slots[d.node].y - d.from.y) * k)
        }
    }

    /// Ends a glide now, every node where it was going.
    private func finishGlide() {
        guard let g = glide else { return }
        glide = nil
        if g.to.count == positions.count { positions = g.to }
        if let alpha = g.engineAlpha, arrangement == .organic, engine == nil { makeEngine(alpha: alpha) }
    }

    /// `Theme.Motion.arrive` (0.5 s, bounce 0.22) for a frame loop, `t` seconds in: something
    /// let go by hand overshoots its place a touch and settles. Under Reduce Motion, the plain
    /// settle.
    static func arrive(_ t: TimeInterval) -> Double {
        guard !Theme.Motion.reduced else { return Theme.Motion.settle(t / Theme.Motion.normalSeconds) }
        let w = 2 * Double.pi / 0.5, z = 1 - 0.22, wd = w * (1 - z * z).squareRoot()
        return 1 - exp(-z * w * t) * (cos(wd * t) + z * w / wd * sin(wd * t))
    }

    /// Every node from `from` to `to` on the settle curve, each leaving after its `delay`.
    private struct Glide {
        var from: [CGPoint]
        var to: [CGPoint]
        var start: TimeInterval
        var delay: [Double]
        var duration: TimeInterval
        var end: TimeInterval
        var engineAlpha: Double?
        /// Read once: `Theme.Motion.settle` asks the system on every call.
        var reduced: Bool

        func positions(at now: TimeInterval) -> [CGPoint] {
            let elapsed = now - start
            // `Theme.Motion.settle`, inlined.
            let w = 7.43, end = 1 - (1 + w) * exp(-w)
            return [CGPoint](unsafeUninitializedCapacity: to.count) { buffer, initialized in
                for i in 0..<to.count {
                    let x = min(max((elapsed - delay[i]) / duration, 0), 1)
                    let k = CGFloat(reduced ? 1 - (1 - x) * (1 - x) * (1 - x) : (1 - (1 + w * x) * exp(-w * x)) / end)
                    buffer[i] = CGPoint(x: from[i].x + (to[i].x - from[i].x) * k, y: from[i].y + (to[i].y - from[i].y) * k)
                }
                initialized = to.count
            }
        }
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
        advanceGlide(to: now)

        if let anim = cameraAnimation {
            let p = min(max((now - anim.start) / anim.duration, 0), 1)
            storedCamera = anim.from.interpolated(to: anim.to, CGFloat(Theme.Motion.settle(p)))
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

        var frame = GraphFrame(
            topology: topology,
            positions: positions,
            camera: storedCamera,
            selected: selectedIndex,
            hovered: dragging ?? hoverShown,
            hoverAmount: dragging != nil ? 1 : hoverAmount,
            filterMask: filterMask,
            labelAmount: labelFade.value(at: now),
            pinned: pinned,
            dragging: dragging,
            pulse: pulse.flatMap { p in
                let t = (now - p.start) / Self.pulseSeconds
                return t < 1 ? (p.node, t) : nil
            })
        frame.multiSelected = Set(chosenIDs.compactMap { topology.index[$0] })
        frame.link = linkDraft
        frame.calm = calm
        frame.labelLimit = labelLimit
        if labelLimit != nil { frame.labelOrder = Array(0..<topology.count) }
        frame.detailOpacity = currentDetailOpacity()
        if let replay {
            let t = (now - replay.start) / Self.replaySeconds
            if t >= 1.15 {
                self.replay = nil
            } else {
                for i in frame.detailOpacity.indices where i < replay.births.count {
                    let shown = min(1, max(0, (t - replay.births[i]) / 0.05))
                    frame.detailOpacity[i] *= shown
                }
                let reached = min(replay.dates.count - 1, max(0, Int(t * Double(replay.dates.count))))
                if replay.dates.indices.contains(reached) {
                    frame.caption = replay.dates[reached].formatted(.dateTime.day().month(.abbreviated).year())
                }
            }
        }
        if let p = pulse, now - p.start >= Self.pulseSeconds { pulse = nil }
        frame.celebration = advanceCelebration(to: now)

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
        if cameraAnimation != nil || dragging != nil || pulse != nil || replay != nil || celebration != nil { return true }
        if glide != nil || drop != nil { return true }
        if !hoverFade.isDone(at: now) || !labelFade.isDone(at: now) { return true }
        if autoFit, size.width > 0, !storedCamera.isClose(to: fitCamera()) { return true }
        return false
    }

    private func startFrames() {
        if !redraw.isAnimating { redraw.isAnimating = true }
    }

    // MARK: Replay

    static let replaySeconds = 7.0
    /// Each node's moment in the replay (0…1, by rank so quiet months don't stall it), and
    /// the dates in order for the caption.
    private var replay: (start: TimeInterval, births: [Double], dates: [Date])?
    /// Set by the view: loads when each file was first touched.
    var onReplayRequested: (() -> Void)?

    /// Plays the graph growing: files appear in the order they were first opened, thought
    /// about or changed, and their connections draw in as both ends arrive. Folders stay.
    func startReplay(firstSeen: [String: Date]) {
        guard topology.count > 0 else { return }
        let dated = topology.ids.indices.filter { !topology.isFolder[$0] }
            .map { ($0, firstSeen[topology.ids[$0]] ?? .distantFuture) }
            .sorted { $0.1 < $1.1 }
        var births = [Double](repeating: 0, count: topology.count)
        let count = Double(max(1, dated.count))
        for (rank, entry) in dated.enumerated() { births[entry.0] = Double(rank) / count }
        let dates = dated.map(\.1).filter { $0 != .distantFuture }
        replay = (CACurrentMediaTime(), births, dates.isEmpty ? [Date()] : dates)
        fitAll()
        startFrames()
        invalidate()
    }

    // MARK: Context menu

    /// Shows the accessible list of nodes (for VoiceOver and for finding a node by name).
    @Published var showsNodeList = false

    func contextMenu(at p: CGPoint) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let i = node(atScreen: p) {
            let name = topology.labels[i]
            menu.addItem(GraphMenuItem(topology.isFolder[i] ? "Show Folder" : "Open") { [weak self] in self?.activate(i) })
            if let s = selectedIndex, s != i, linkable(s) != nil, linkable(i) != nil {
                menu.addItem(GraphMenuItem("Connect to " + topology.labels[s]) { [weak self] in self?.connectPair(s, i) })
            }
            if isPinned(i) { menu.addItem(GraphMenuItem("Unpin " + name) { [weak self] in self?.unpin(i); self?.persist() }) }
            menu.addItem(.separator())
        }
        menu.addItem(GraphMenuItem("Fit All") { [weak self] in self?.fitAll() })
        if mode == .live {
            let layouts = NSMenu()
            for a in GraphArrangement.allCases {
                let item = GraphMenuItem(a.title) { [weak self] in self?.setArrangement(a) }
                item.state = a == arrangement ? .on : .off
                layouts.addItem(item)
            }
            let layout = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
            layout.submenu = layouts
            menu.addItem(layout)
        }
        if arrangement == .organic {
            menu.addItem(GraphMenuItem("Reset Layout") { [weak self] in self?.resetVisibleLayout() })
        }
        menu.addItem(GraphMenuItem("Node List") { [weak self] in self?.showsNodeList = true })
        if onReplayRequested != nil {
            menu.addItem(GraphMenuItem("Replay History") { [weak self] in self?.onReplayRequested?() })
        }
        if scopeIsTruncated {
            menu.addItem(.separator())
            menu.addItem(GraphMenuItem("Show More Files") { [weak self] in self?.showMore() })
        }
        return menu
    }

    // MARK: ⌥-drag to connect

    private var linkDraft: (from: Int, to: CGPoint, over: Int?)?

    private func linkable(_ i: Int?) -> Int? {
        guard let i, topology.ids.indices.contains(i), !topology.isFolder[i], !topology.missing[i] else { return nil }
        return i
    }

    func beginLink(from node: Int, to p: CGPoint) {
        guard linkable(node) != nil, vault != nil else { return }
        linkDraft = (node, p, nil)
        invalidate()
    }

    func updateLink(to p: CGPoint, over node: Int?) {
        guard let draft = linkDraft else { return }
        let target = linkable(node).flatMap { $0 == draft.from ? nil : $0 }
        if target != nil, target != draft.over {
            Feedback.haptic(.detent)
        }
        linkDraft = (draft.from, p, target)
        invalidate()
    }

    func endLink(from node: Int, onto target: Int?) {
        let over = linkDraft?.over
        linkDraft = nil
        invalidate()
        guard let target = linkable(target ?? over), target != node, linkable(node) != nil else { return }
        Feedback.haptic(.threshold)
        connectPair(node, target)
    }

    /// Connects two files by hand, undoably, through the same path as any connection.
    func connectPair(_ a: Int, _ b: Int) {
        let previous = (connectionMode, chosenIDs)
        chosenIDs = [topology.ids[a], topology.ids[b]]
        connectionMode = .add
        applyConnections(label: nil)
        (connectionMode, chosenIDs) = previous
        celebrate(from: FileRef(relativePath: topology.ids[a]), to: [FileRef(relativePath: topology.ids[b])], level: 1, zoom: false)
    }

    // MARK: Celebration

    struct Celebration {
        var from: String
        var to: [String]
        var level: Int
        var zoom: Bool
        var requested: TimeInterval
        /// When both ends were first on the canvas; the timeline runs from here.
        var start: TimeInterval?
        var departed = false
        var arrived = false
    }

    /// How long to wait for the ends to appear, e.g. while the graph rebuilds with a new link.
    static let celebrationWait: TimeInterval = 3
    /// QA: `FLAMINGO_SLOWMO=10` plays celebrations ten times slower.
    static let celebrationSlowdown = max(1, Double(ProcessInfo.processInfo.environment["FLAMINGO_SLOWMO"] ?? "") ?? 1)

    /// Shows a new connection: the camera settles on the pair (with `zoom`), a line in the
    /// thought's tint (`Theme.Color.thought(level)`) draws from `from` to each of `to`, rings
    /// land on both ends with the chime, and the line fades into the edge. With no `to`, only
    /// `from` rings. Waits up to `celebrationWait` for the nodes to be in the graph.
    func celebrate(from: FileRef, to: [FileRef], level: Int, zoom: Bool) {
        celebration = Celebration(from: from.relativePath, to: to.map(\.relativePath).filter { $0 != from.relativePath },
                                  level: min(max(level, 0), 2), zoom: zoom, requested: CACurrentMediaTime())
        startFrames()
        invalidate()
    }

    private func advanceCelebration(to now: TimeInterval) -> GraphFrame.Celebration? {
        guard var c = celebration else { return nil }
        let a = topology.index[c.from]
        let bs = c.to.compactMap { topology.index[$0] }
        if c.start == nil {
            guard let a, c.to.isEmpty || !bs.isEmpty, size.width > 0 else {
                if now - c.requested > Self.celebrationWait {
                    celebration = nil
                    let missed = c
                    DispatchQueue.main.async { [weak self] in
                        self?.onCelebrationMissed(FileRef(relativePath: missed.from), missed.to.map { FileRef(relativePath: $0) }, missed.level)
                    }
                }
                return nil
            }
            c.start = now
            if c.zoom, !bs.isEmpty { zoomCamera(onto: [a] + bs, duration: CelebrationTime.zoom * Self.celebrationSlowdown) }
        }
        // The source left the graph mid-celebration (a rebuild or a new scope): let it go.
        guard let a, let start = c.start else { celebration = nil; return nil }
        let t = (now - start) / Self.celebrationSlowdown
        if !c.departed, t >= CelebrationTime.depart {
            c.departed = true
            let level = c.level, alone = bs.isEmpty
            DispatchQueue.main.async { alone ? Chime.play(level: level) : Chime.depart() }
        }
        if !c.arrived, !bs.isEmpty, t >= CelebrationTime.arrive {
            c.arrived = true
            let level = c.level
            DispatchQueue.main.async { Chime.arrive(level: level) }
        }
        if t >= CelebrationTime.end(alone: bs.isEmpty) {
            celebration = nil
            DispatchQueue.main.async { [weak self] in self?.onCelebrationEnded() }
        } else {
            celebration = c
        }
        return GraphFrame.Celebration(from: a, to: bs, level: c.level, t: t)
    }

    /// Settles the camera on `nodes`, as close as a fit goes.
    private func zoomCamera(onto nodes: [Int], duration: TimeInterval) {
        guard size.width > 0 else { return }
        let points = nodes.map { positions[$0] }
        let radii = nodes.map { topology.radius[$0] }
        let room = nodes.map { i -> CGFloat in
            let label = LabelLayout.truncated(topology.labels[i], limit: GraphRenderer.Style.labelMaxCharacters)
            return (label as NSString).size(withAttributes: [.font: Theme.NS.small]).width / 2
        }.max() ?? 0
        let target = GraphCamera.fitting(points, radii: radii, in: size, padding: fitPadding,
                                         horizontalPadding: fitPadding + room, maxZoom: fitMaxZoom)
        autoFit = false
        cameraAnimation = (storedCamera, target, CACurrentMediaTime(), duration)
        startFrames()
    }

    private func invalidate() {
        if !redraw.isAnimating { redraw.revision &+= 1 }
    }

    /// The camera that shows `points` (by default, everything where it is now).
    private func fitCamera(_ points: [CGPoint]? = nil) -> GraphCamera {
        GraphCamera.fitting(points ?? positions, radii: topology.radius, in: size, padding: fitPadding,
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
        cameraAnimation = (storedCamera, target, CACurrentMediaTime(), Theme.Motion.normalSeconds)
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
            if let before = cameraChangeStart {
                if let record = cameraChangeRecord { record.after = newValue }
                else {
                    let record = GraphCameraChange(after: newValue), generation = vaultGeneration
                    cameraChangeRecord = record
                    actionHistory?.register(name: "Move graph view", undo: {
                        try self.restoreCamera(before, generation: generation)
                    }, redo: {
                        try self.restoreCamera(record.after, generation: generation)
                    })
                }
                cameraChangeTask?.cancel()
                cameraChangeTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    self?.finishCameraChange()
                }
            }
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
            let detail = detailOpacity(for: i)
            guard detail >= GraphDetail.visibilityCutoff else { continue }
            let s = storedCamera.toScreen(positions[i], size: size)
            let dx = s.x - p.x, dy = s.y - p.y
            let reach = max(GraphRenderer.screenRadius(worldRadius: topology.radius[i], zoom: zoom,
                                                       detailOpacity: detail, isFolder: topology.isFolder[i]) + 4, 7)
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

    /// Single click: select, a haptic tap, a pulse, and the camera eases onto the node at a
    /// readable zoom. Nothing opens; that's `activate`.
    func click(_ node: Int) { click(node, additive: false) }

    func click(_ node: Int, additive: Bool) {
        guard topology.ids.indices.contains(node), positions.indices.contains(node) else { return }
        finishCameraChange()
        if (additive || connectionMode != .browse), !topology.isFolder[node] {
            if chosenIDs.isEmpty, let requestedSelection, requestedSelection.relativePath != topology.ids[node] {
                chosenIDs.insert(requestedSelection.relativePath)
            }
            let id = topology.ids[node]
            if !chosenIDs.insert(id).inserted { chosenIDs.remove(id) }
        } else if !additive { chosenIDs = [] }
        selectedIndex = node
        publishSelection(node, notify: !additive)
        Feedback.haptic(.detent)
        pulse = (node, CACurrentMediaTime())
        autoFit = false
        let zoom = max(storedCamera.zoom, clickZoom)
        animateCamera(to: GraphCamera(center: positions[node], zoom: min(zoom, GraphCamera.zoomRange.upperBound)))
    }

    func activate(_ node: Int) {
        guard topology.ids.indices.contains(node) else { return }
        selectedIndex = node
        Feedback.haptic(.threshold)
        open(node)
    }

    func beginNodeDrag(_ node: Int) {
        guard positions.indices.contains(node) else { return }
        finishCameraChange()
        finishGlide()
        if drop?.node == node { drop = nil }
        dragStartLayout = arrangement == .organic ? layoutSnapshot() : nil
        dragging = node
        if mode == .live, arrangement == .organic {
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
        if slots != nil, positions.indices.contains(node) {
            // An arrangement owns every place: let go, and the node springs home.
            drop = (node, positions[node], CACurrentMediaTime())
            startFrames()
            invalidate()
            return
        }
        persist()
        if let before = dragStartLayout {
            registerLayoutChange("Move graph node", before: before, after: layoutSnapshot())
        }
        dragStartLayout = nil
        invalidate()
    }

    func unpin(_ node: Int) {
        guard pinned.contains(node) else { return }
        finishCameraChange()
        let before = layoutSnapshot()
        pinned.remove(node)
        engine?.unpin(node)
        let after = layoutSnapshot(syncEngine: false)
        persist()
        registerLayoutChange("Unpin graph node", before: before, after: after)
        startFrames()
        invalidate()
    }

    private func layoutSnapshot(syncEngine: Bool = true) -> SavedLayout {
        if syncEngine, let engine { positions = engine.snapshot().positions }
        return LayoutStore.layout(for: topology, positions: restingPositions, pinned: pinned)
    }

    private func registerLayoutChange(_ name: String, before: SavedLayout, after: SavedLayout) {
        guard before != after else { return }
        let generation = vaultGeneration
        actionHistory?.register(name: name, undo: {
            try self.restoreLayout(before, expecting: after, generation: generation)
        }, redo: {
            try self.restoreLayout(after, expecting: before, generation: generation)
        })
    }

    private func restoreLayout(_ layout: SavedLayout, expecting expected: SavedLayout, generation: Int) throws {
        guard generation == vaultGeneration else { throw GraphUndoError.vaultChanged }
        let key = Self.layoutKey(vault)
        // An arrangement shows places of its own; the force layout to restore is in the store.
        let current = arrangement == .organic ? layoutSnapshot() : SavedLayout(nodes: [:], pinned: [])
        let known = LayoutStore.merging(current, into: LayoutStore.cached(key))
        let affected = Set(expected.nodes.keys)
        let expectedPins = Set(expected.pinned)
        guard Set(known.pinned).intersection(affected) == expectedPins else { throw GraphUndoError.layoutChanged }
        // An unpinned node may move on its own; only fixed coordinates represent user intent.
        for id in expectedPins where known.nodes[id] != expected.nodes[id] {
            throw GraphUndoError.layoutChanged
        }
        let alpha = engine?.snapshot().alpha ?? 0
        engine?.onSettle = nil; engine?.stop()
        let restored: SavedLayout
        do { restored = try LayoutStore.restore(layout, key: key, vault: vault) }
        catch { makeEngine(alpha: alpha); throw error }
        guard arrangement == .organic else { return }
        let initial = Self.initialLayout(for: topology, arrangement: .organic, saved: restored)
        positions = initial.positions; pinned = initial.pinned
        makeEngine(alpha: 0)
        autoFit = false; cameraAnimation = nil; dragging = nil
        invalidate()
    }

    func fitAll() {
        guard size.width > 0 else { return }
        finishCameraChange()
        let before = storedCamera, after = fitCamera()
        autoFit = false
        animateCamera(to: after)
        registerCameraChange("Fit graph", before: before, after: after)
    }

    func userMovedCamera() {
        if cameraChangeStart == nil { cameraChangeStart = storedCamera }
        autoFit = false
        cameraAnimation = nil
    }

    func finishCameraChange() {
        cameraChangeTask?.cancel(); cameraChangeTask = nil
        cameraChangeStart = nil; cameraChangeRecord = nil
    }

    private func registerCameraChange(_ name: String, before: GraphCamera, after: GraphCamera) {
        guard !before.isClose(to: after) else { return }
        let generation = vaultGeneration
        actionHistory?.register(name: name, undo: {
            try self.restoreCamera(before, generation: generation)
        }, redo: {
            try self.restoreCamera(after, generation: generation)
        })
    }

    private func restoreCamera(_ camera: GraphCamera, generation: Int) throws {
        guard generation == vaultGeneration else { throw GraphUndoError.vaultChanged }
        applyRestoredCamera(camera)
        NotificationCenter.default.post(name: GraphUndoNotification.camera, object: Self.layoutKey(vault),
                                        userInfo: ["camera": camera])
    }

    func applyRestoredCamera(_ camera: GraphCamera) {
        (inputView as? GraphInputNSView)?.recognizer.reset()
        finishCameraChange()
        cameraAnimation = nil; autoFit = false; storedCamera = camera
        invalidate()
    }

    func reloadRestoredLayout() {
        guard mode == .live, arrangement == .organic, let saved = LayoutStore.cached(Self.layoutKey(vault)) else { return }
        let initial = LayoutStore.initial(for: topology, saved: saved)
        positions = initial.positions; pinned = initial.pinned
        makeEngine(alpha: 0)
        autoFit = false; cameraAnimation = nil; dragging = nil
        invalidate()
    }

    func moveSelection(_ direction: GraphDirection) {
        let eligible = topology.ids.indices.map {
            (filterMask?[$0] ?? true) && detailOpacity(for: $0) >= GraphDetail.visibilityCutoff
        }
        let next: Int?
        if let s = selectedIndex, positions.indices.contains(s) {
            next = GraphNavigation.next(from: s, direction, positions: positions, topology: topology, eligible: eligible)
        } else {
            next = GraphNavigation.nearest(to: storedCamera.center, positions: positions, eligible: eligible)
        }
        guard let next else { return }
        selectedIndex = next
        publishSelection(next)
        reveal(next)
        invalidate()
    }

    func openSelection() {
        if let s = selectedIndex { open(s) }
    }

    /// Drawing, pointer input and arrow navigation use the same visibility rule. Explicit
    /// user context stays visible even at overview scale.
    /// Everything the per-node fade depends on. The fade is mapped over every node, so it is
    /// rebuilt only when one of these changes, not on every display frame.
    private struct DetailKey: Equatable {
        var token: UUID, zoom: CGFloat, selected: Int?, dragging: Int?, pinned: Int, chosen: Int, filter: Int, labels: Bool
    }
    private var detailCache: (key: DetailKey, values: [Double])?

    private func currentDetailOpacity() -> [Double] {
        let key = DetailKey(token: topology.token, zoom: storedCamera.zoom, selected: selectedIndex, dragging: dragging,
                            pinned: pinned.hashValue, chosen: chosenIDs.hashValue, filter: filterVersion, labels: alwaysShowLabels)
        if let cache = detailCache, cache.key == key { return cache.values }
        let values = topology.ids.indices.map { detailOpacity(for: $0) }
        detailCache = (key, values)
        return values
    }

    func detailOpacity(for i: Int) -> Double {
        guard !alwaysShowLabels, topology.isFolder[i] else { return 1 }
        if i == selectedIndex || i == dragging || pinned.contains(i)
            || chosenIDs.contains(topology.ids[i]) || filterMask?[i] == true { return 1 }
        return GraphDetail.opacity(revealZoom: topology.detailRevealZoom[i], zoom: storedCamera.zoom)
    }

    func type(_ text: String) { onType(text) }

    func clearSelection() {
        selectedIndex = nil
        requestedSelection = nil
        selectionPath = nil
        chosenIDs = []
        connectionMode = .browse
        pulse = nil
        onSelectionChange(nil)
        invalidate()
    }

    func escape() {
        clearSelection()
        onEscape()
    }
}

extension GraphCamera {
    /// Within half a point and a tenth of a percent of zoom.
    func isClose(to other: GraphCamera) -> Bool {
        abs(zoom / other.zoom - 1) < 0.001
            && abs(center.x - other.center.x) * zoom < 0.5
            && abs(center.y - other.center.y) * zoom < 0.5
    }
}
