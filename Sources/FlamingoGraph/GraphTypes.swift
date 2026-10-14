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
    /// Deduplicated per (pair, kind); self loops and edges to unknown nodes dropped.
    /// A pair may appear twice, once as `link` and once as `trail`.
    let edges: [Edge]
    /// Sorted, unique adjacency regardless of edge kind.
    let neighbors: [[Int]]
    /// World-space node radius: `3 + ln(1 + commentCount + degree)`.
    let radius: [Double]

    var count: Int { ids.count }
    func degree(_ i: Int) -> Int { neighbors[i].count }

    init(_ graph: Graph) {
        var ids: [String] = [], labels: [String] = [], exts: [String] = [], counts: [Int] = []
        var index: [String: Int] = [:]
        ids.reserveCapacity(graph.nodes.count)
        for node in graph.nodes where index[node.id] == nil {
            index[node.id] = ids.count
            ids.append(node.id)
            let name = node.name.isEmpty ? (node.id as NSString).lastPathComponent : node.name
            let stem = (name as NSString).deletingPathExtension
            labels.append(stem.isEmpty ? name : stem)
            exts.append(node.ext.isEmpty ? (name as NSString).pathExtension.lowercased() : node.ext.lowercased())
            counts.append(max(0, node.commentCount))
        }

        struct Key: Hashable { var a: Int, b: Int, kind: Graph.Edge.Kind }
        var weights: [Key: Double] = [:]
        var order: [Key] = []
        for e in graph.edges {
            guard let s = index[e.source], let t = index[e.target], s != t else { continue }
            let key = Key(a: min(s, t), b: max(s, t), kind: e.kind)
            if let w = weights[key] { weights[key] = w + e.weight } else { weights[key] = e.weight; order.append(key) }
        }
        var adjacency = [Set<Int>](repeating: [], count: ids.count)
        var edges: [Edge] = []
        edges.reserveCapacity(order.count)
        for key in order {
            edges.append(Edge(a: key.a, b: key.b, kind: key.kind, weight: weights[key] ?? 1))
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
        self.radius = (0..<ids.count).map { 3 + log(1 + Double(counts[$0] + adjacency[$0].count)) }
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
    static func fitting(_ positions: [CGPoint], radii: [Double], in size: CGSize,
                        padding: CGFloat = 48, maxZoom: CGFloat = 2.4) -> GraphCamera {
        guard !positions.isEmpty, size.width > 1, size.height > 1 else { return GraphCamera() }
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for i in positions.indices {
            let p = positions[i], r = i < radii.count ? CGFloat(radii[i]) : 0
            minX = min(minX, p.x - r); maxX = max(maxX, p.x + r)
            minY = min(minY, p.y - r); maxY = max(maxY, p.y + r)
        }
        let w = max(maxX - minX, 1), h = max(maxY - minY, 1)
        let availW = max(size.width - 2 * padding, 1), availH = max(size.height - 2 * padding, 1)
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
    /// Printable characters typed while the canvas has focus; they go to the filter.
    func type(_ text: String)
    /// Esc on the canvas.
    func escape()
}
