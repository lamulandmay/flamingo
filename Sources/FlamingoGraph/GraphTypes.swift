import Foundation
import CoreGraphics
import AppKit
import FlamingoCore

// Shared vocabulary for the graph module. The simulation, the renderer, the input layer
// and the model all speak in node indices into a `GraphTopology` and in world-space
// `CGPoint`s. World space is y-down like the canvas; the camera maps it to the screen.
//
// No SIMD here on purpose: generic SIMD arithmetic is unspecialized in debug builds and
// `scripts/run.sh` builds debug.

// MARK: - Topology

/// A `Graph` re-indexed for drawing and layout. Built once per `Graph` value.
struct GraphTopology: Sendable {
    struct Edge: Hashable, Sendable {
        /// Node indices, `a < b`. Edges are undirected for layout and drawing.
        var a: Int
        var b: Int
        var kind: Graph.Edge.Kind
        var weight: Double

        /// Which kind a pair connected several ways is drawn as.
        static func precedence(_ kind: Graph.Edge.Kind) -> Int {
            switch kind {
            case .manual: 6
            case .link: 5
            case .mention: 4
            case .related: 3
            case .trail: 2
            case .folder: 1
            }
        }

        /// 0 explicit (solid), 1 inferred (dashed), 2 folder containment (faint solid).
        var strokeClass: Int { kind.isExplicit ? 0 : (kind == .folder ? 2 : 1) }
    }

    /// Fresh per instance. Caches keyed by node index (label sizes, adjacency masks) must be
    /// dropped when this changes.
    let token = UUID()
    let ids: [String]
    /// File name without extension. What the canvas prints.
    let labels: [String]
    let exts: [String]
    let commentCounts: [Int]
    let index: [String: Int]
    /// One edge per pair of nodes; self loops and edges to unknown nodes dropped. When a pair
    /// is connected several ways, `kind` is the strongest (`Edge.precedence`): a link someone
    /// wrote outranks a mention Flamingo found, so the pair draws solid.
    let edges: [Edge]
    /// Sorted, unique adjacency regardless of edge kind.
    let neighbors: [[Int]]
    /// World-space node radius: `3 + ln(1 + commentCount + degree)`.
    let radius: [Double]
    /// Nodes with no file behind them: wikilink targets that resolve to nothing and sidecar
    /// targets whose file is gone. Drawn ghosted. All false until `markMissing(in:)`.
    private(set) var missing: [Bool]
    /// Folder nodes (ids ending in `/`), drawn as hollow rings.
    let isFolder: [Bool]
    /// Folder detail thresholds, computed once per topology, never during a gesture.
    let detailRevealZoom: [CGFloat]

    var count: Int { ids.count }
    func degree(_ i: Int) -> Int { neighbors[i].count }

    init(_ graph: Graph) {
        var ids: [String] = [], labels: [String] = [], exts: [String] = [], counts: [Int] = []
        var index: [String: Int] = [:]
        ids.reserveCapacity(graph.nodes.count)
        for node in graph.nodes where index[node.id] == nil {
            index[node.id] = ids.count
            ids.append(node.id)
            let folder = node.id.hasSuffix("/")
            let name = node.name.isEmpty ? ((folder ? String(node.id.dropLast()) : node.id) as NSString).lastPathComponent : node.name
            let stem = folder ? name : (name as NSString).deletingPathExtension
            labels.append(stem.isEmpty ? name : stem)
            var ext = node.ext.isEmpty ? (name as NSString).pathExtension.lowercased() : node.ext.lowercased()
            // Inbox and web thoughts (`_inbox/2026-10-14`, `_web/host/page-ab12cd`) are markdown notes with no file of their own.
            if ext.isEmpty, FileRef(relativePath: node.id).isVirtual { ext = "md" }
            exts.append(ext)
            counts.append(max(0, node.commentCount))
        }

        struct Key: Hashable { var a: Int, b: Int }
        var merged: [Key: Edge] = [:]
        var order: [Key] = []
        for e in graph.edges {
            guard let s = index[e.source], let t = index[e.target], s != t else { continue }
            let key = Key(a: min(s, t), b: max(s, t))
            if var existing = merged[key] {
                if Edge.precedence(e.kind) > Edge.precedence(existing.kind) { existing.kind = e.kind }
                existing.weight += e.weight
                merged[key] = existing
            } else {
                merged[key] = Edge(a: key.a, b: key.b, kind: e.kind, weight: e.weight)
                order.append(key)
            }
        }
        var adjacency = [Set<Int>](repeating: [], count: ids.count)
        var edges: [Edge] = []
        edges.reserveCapacity(order.count)
        for key in order {
            if let edge = merged[key] { edges.append(edge) }
            adjacency[key.a].insert(key.b)
            adjacency[key.b].insert(key.a)
        }

        self.ids = ids
        self.labels = labels
        self.exts = exts
        self.commentCounts = counts
        self.index = index
        self.edges = edges
        self.neighbors = adjacency.map { $0.sorted() }
        let folders = ids.map { $0.hasSuffix("/") }
        self.isFolder = folders
        self.detailRevealZoom = GraphDetail.revealZooms(ids: ids)
        self.radius = (0..<ids.count).map { folders[$0] ? 4.5 + log(1 + Double(adjacency[$0].count)) : 3 + log(1 + Double(counts[$0] + adjacency[$0].count)) }
        self.missing = [Bool](repeating: false, count: ids.count)
    }

    /// Marks nodes whose file doesn't exist in `vault`. Inbox and web notes are never missing.
    mutating func markMissing(in vault: Vault) {
        let fm = FileManager.default
        for i in ids.indices where !isFolder[i] {
            let ref = FileRef(relativePath: ids[i])
            missing[i] = !ref.isVirtual && !fm.fileExists(atPath: vault.url(for: ref).path)
        }
    }
}

// MARK: - Camera

/// Maps world space to the canvas. `center` is the world point under the middle of the view.
struct GraphCamera: Equatable, Sendable {
    var center: CGPoint = .zero
    /// Screen points per world unit.
    var zoom: CGFloat = 1

    static let zoomRange: ClosedRange<CGFloat> = 0.04...10
    /// Labels for every node fade in above this zoom.
    static let labelZoom: CGFloat = 1.2

    func toScreen(_ p: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: (p.x - center.x) * zoom + size.width / 2, y: (p.y - center.y) * zoom + size.height / 2)
    }

    func toWorld(_ p: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: (p.x - size.width / 2) / zoom + center.x, y: (p.y - size.height / 2) / zoom + center.y)
    }

    /// Moves the content by a screen-space delta (content follows the pointer).
    mutating func pan(by screenDelta: CGSize) {
        center.x -= screenDelta.width / zoom
        center.y -= screenDelta.height / zoom
    }

    /// Multiplies zoom, keeping the world point under `anchor` (screen space) fixed.
    mutating func zoom(by factor: CGFloat, around anchor: CGPoint, size: CGSize) {
        guard factor.isFinite, factor > 0 else { return }
        let before = toWorld(anchor, size: size)
        zoom = min(max(zoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let after = toWorld(anchor, size: size)
        center.x += before.x - after.x
        center.y += before.y - after.y
    }

    /// Smallest camera that shows every node with `padding` points to spare. `maxZoom` keeps a
    /// five-node graph from filling the screen.
    /// `horizontalPadding` overrides `padding` left and right, for labels wider than their node.
    static func fitting(_ positions: [CGPoint], radii: [Double], in size: CGSize,
                        padding: CGFloat = 48, horizontalPadding: CGFloat? = nil,
                        maxZoom: CGFloat = 2.4) -> GraphCamera {
        guard !positions.isEmpty, size.width > 1, size.height > 1 else { return GraphCamera() }
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for i in positions.indices {
            let p = positions[i], r = i < radii.count ? CGFloat(radii[i]) : 0
            minX = min(minX, p.x - r); maxX = max(maxX, p.x + r)
            minY = min(minY, p.y - r); maxY = max(maxY, p.y + r)
        }
        let w = max(maxX - minX, 1), h = max(maxY - minY, 1)
        let availW = max(size.width - 2 * (horizontalPadding ?? padding), 1), availH = max(size.height - 2 * padding, 1)
        let zoom = min(min(availW / w, availH / h), maxZoom)
        return GraphCamera(center: CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2),
                           zoom: min(max(zoom, zoomRange.lowerBound), zoomRange.upperBound))
    }

    /// Interpolates center linearly and zoom geometrically, so zooming feels even.
    func interpolated(to other: GraphCamera, _ t: CGFloat) -> GraphCamera {
        let t = min(max(t, 0), 1)
        return GraphCamera(
            center: CGPoint(x: center.x + (other.center.x - center.x) * t,
                            y: center.y + (other.center.y - center.y) * t),
            zoom: exp(log(zoom) + (log(other.zoom) - log(zoom)) * t))
    }
}

// MARK: - Frame

/// Everything the renderer needs to draw one frame. The model builds one per display frame;
/// the renderer is a pure function of it (plus its own caches keyed by node index).
struct GraphFrame {
    var topology: GraphTopology
    /// World positions, indexed like `topology`.
    var positions: [CGPoint]
    var camera: GraphCamera

    /// The graph's own selection: mirrors `GraphView.selected`, moved by arrow keys. Drawn in
    /// accent with its neighbors; its label always shows.
    var selected: Int?
    /// Node whose neighborhood is emphasized. Stays set while `hoverAmount` fades out.
    var hovered: Int?
    /// 0...1. At 1, everything outside `hovered` and its neighbors is at `Theme.Opacity.dimmed`.
    var hoverAmount: Double
    /// nil = no filter. Otherwise `false` entries are drawn at `Theme.Opacity.dimmed`.
    var filterMask: [Bool]?
    /// 0...1 opacity of zoom-driven labels (all nodes). Eased by the model over 150ms when
    /// zoom crosses `GraphCamera.labelZoom`.
    var labelAmount: Double
    /// Nodes the user dragged; drawn with a subtle marker.
    var pinned: Set<Int>
    /// Node under an active drag, if any.
    var dragging: Int?
    /// A click just landed on this node: a ring expands and fades over `pulseSeconds`.
    var pulse: (node: Int, progress: Double)?
    var multiSelected: Set<Int> = []
    /// Semantic zoom visibility. Empty means fully visible (local graphs and callers that
    /// supply their own frames). Edges and labels inherit their nodes' visibility.
    var detailOpacity: [Double] = []
    /// An ⌥-drag from `from` toward a screen point, possibly over a node it would connect to.
    var link: (from: Int, to: CGPoint, over: Int?)?
    /// One quiet line drawn at the canvas's bottom left: the date a replay has reached.
    var caption: String?
    /// The vault graph: suggested edges only around the selected or hovered node, and the
    /// selection's neighborhood lit while the rest recedes. A local graph draws everything.
    var calm = true
    /// At most this many zoom-driven names (selected and hovered always show).
    var labelLimit: Int?
    /// Name nodes in this order instead of by connectedness.
    var labelOrder: [Int]?
    /// A connection being shown off, `t` seconds in. See `CelebrationTime`.
    var celebration: Celebration?
    struct Celebration { var from: Int; var to: [Int]; var level: Int; var t: Double }
}

/// A celebration's beats, in seconds from when both ends are on the canvas: the camera
/// settles, the line leaves with the first note, arrives with the rest, holds, then fades
/// into the ordinary edge.
enum CelebrationTime {
    static let zoom: TimeInterval = 0.45
    static let depart: TimeInterval = 0.3
    static let travel: TimeInterval = 0.4
    static let hold: TimeInterval = 1.2
    static let fade: TimeInterval = 0.6
    static let ripple: TimeInterval = 0.5
    static var arrive: TimeInterval { depart + travel }
    /// When the line starts fading; a lone file (no link) rings and fades sooner.
    static func fadeStart(alone: Bool) -> TimeInterval { alone ? depart + ripple + 0.3 : arrive + hold }
    static func end(alone: Bool) -> TimeInterval { fadeStart(alone: alone) + fade }
}

// MARK: - Input

enum GraphDirection: Sendable { case up, down, left, right }

/// What the input layer (`GraphInputView`) drives. Implemented by `GraphModel`. All points are
/// in the canvas's coordinate space: origin top-left, y down, points.
@MainActor
protocol GraphInteractionTarget: AnyObject {
    /// The input layer mutates this directly for pan and zoom; the model redraws on set.
    var camera: GraphCamera { get set }
    /// Called once the input view is in a window, so the model can hand it keyboard focus
    /// back (e.g. after Esc in the filter field). Keep it weak.
    func inputViewAttached(_ view: NSView)
    /// Called whenever the canvas size changes (and once on appear).
    func viewResized(to size: CGSize)
    /// Topmost node under a screen point, using a generous minimum hit radius.
    func node(atScreen p: CGPoint) -> Int?
    func worldPosition(of node: Int) -> CGPoint
    func isPinned(_ node: Int) -> Bool

    /// nil when the pointer leaves the canvas or is over empty space.
    func hover(_ node: Int?)
    /// A completed single click on a node: open it.
    func click(_ node: Int)
    func click(_ node: Int, additive: Bool)
    /// Double-click: open the file, or scope into the folder.
    func activate(_ node: Int)
    func beginNodeDrag(_ node: Int)
    /// World position the node's center should move to.
    func dragNode(_ node: Int, toWorld p: CGPoint)
    func endNodeDrag(_ node: Int)
    /// Double-click on a pinned node.
    func unpin(_ node: Int)
    /// Double-click on empty canvas: animate to fit everything.
    func fitAll()
    /// The user moved the camera (pan, zoom, pinch). Stops auto-fit.
    func userMovedCamera()

    func moveSelection(_ direction: GraphDirection)
    /// Return or Enter.
    func openSelection()
    /// Space on the canvas. Clears both the current node and any connection selection.
    func clearSelection()
    /// Printable characters other than Space typed while the canvas has focus go to the filter.
    func type(_ text: String)
    /// Esc on the canvas.
    func escape()

    /// ⌥-drag from a node: a line follows the pointer; releasing on another file connects
    /// the two by hand. `p` is a screen point.
    func beginLink(from node: Int, to p: CGPoint)
    func updateLink(to p: CGPoint, over node: Int?)
    func endLink(from node: Int, onto target: Int?)
    /// The context menu for a right-click at a screen point.
    func contextMenu(at p: CGPoint) -> NSMenu?
}

extension GraphInteractionTarget {
    func click(_ node: Int, additive: Bool) { click(node) }
    func beginLink(from node: Int, to p: CGPoint) {}
    func updateLink(to p: CGPoint, over node: Int?) {}
    func endLink(from node: Int, onto target: Int?) {}
    func contextMenu(at p: CGPoint) -> NSMenu? { nil }
}

/// An `NSMenuItem` that runs a closure.
final class GraphMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, enabled: Bool = true, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func fire() { run() }
}
