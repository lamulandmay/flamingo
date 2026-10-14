import SwiftUI
import FlamingoCore
import FlamingoDesign

/// The neighborhood of one file within `depth` hops, laid out in rings around it. Sized for the
/// space under the comments rail. Hover shows names, click opens, arrows walk, Return opens.
public struct LocalGraphView: View {
    public var graph: Graph
    public var center: FileRef
    public var depth: Int
    public var onSelect: (FileRef) -> Void

    @StateObject private var model: GraphModel

    public init(graph: Graph, center: FileRef, depth: Int = 1, onSelect: @escaping (FileRef) -> Void) {
        self.graph = graph; self.center = center; self.depth = depth; self.onSelect = onSelect
        _model = StateObject(wrappedValue: LocalGraphView.makeModel(graph: graph, center: center, depth: depth))
    }

    public var body: some View {
        let _ = model.onSelect = onSelect
        GraphCanvas(model: model, redraw: model.redraw)
            .overlay(GraphInputLayer(target: model))
            .onChange(of: LocalKey(graph: graph, center: center, depth: depth)) { _, key in
                let local = RadialLayout.local(graph: key.graph, center: key.center, depth: key.depth)
                model.setFixed(graph: local.graph, positions: local.positions, selected: local.center)
            }
    }

    private struct LocalKey: Equatable { var graph: Graph; var center: FileRef; var depth: Int }

    @MainActor
    private static func makeModel(graph: Graph, center: FileRef, depth: Int) -> GraphModel {
        let local = RadialLayout.local(graph: graph, center: center, depth: depth)
        let model = GraphModel(fixedGraph: local.graph, positions: local.positions)
        model.setFixed(graph: local.graph, positions: local.positions, selected: local.center)
        model.alwaysShowLabels = true
        model.fitPadding = Theme.Space.xl
        model.fitMaxZoom = 2
        return model
    }
}

/// Rings around a center node: ring k holds the nodes k hops away. Ring 1 is spaced evenly,
/// grouped by file family; deeper rings sit near the angle of their parents and are pushed
/// apart just enough to stay legible.
enum RadialLayout {
    struct Local {
        var graph: Graph
        var positions: [CGPoint]
        var center: Int?
    }

    /// World units between rings, and the least arc between two nodes on a ring.
    static let ringGap: CGFloat = 64
    static let minArc: CGFloat = 22

    static func local(graph: Graph, center: FileRef, depth: Int) -> Local {
        let sub = neighborhood(of: center.relativePath, in: graph, depth: max(depth, 1))
        let topology = GraphTopology(sub)
        let root = topology.index[center.relativePath]
        return Local(graph: sub, positions: positions(for: topology, root: root), center: root)
    }

    /// Nodes within `depth` hops of `id` (edges taken both ways) and the edges among them.
    /// The center comes first, then nodes by hop count, then by path.
    static func neighborhood(of id: String, in graph: Graph, depth: Int) -> Graph {
        guard let centerNode = graph.nodes.first(where: { $0.id == id }) else { return Graph() }
        var adjacency: [String: [String]] = [:]
        for e in graph.edges where e.source != e.target {
            adjacency[e.source, default: []].append(e.target)
            adjacency[e.target, default: []].append(e.source)
        }
        var hops: [String: Int] = [id: 0]
        var frontier = [id]
        for level in 1...max(depth, 1) {
            var next: [String] = []
            for n in frontier {
                for m in adjacency[n] ?? [] where hops[m] == nil {
                    hops[m] = level
                    next.append(m)
                }
            }
            frontier = next
        }
        let nodes = graph.nodes
            .filter { $0.id != id && hops[$0.id] != nil }
            .sorted { (hops[$0.id]!, $0.id) < (hops[$1.id]!, $1.id) }
        let edges = graph.edges.filter { hops[$0.source] != nil && hops[$0.target] != nil }
        return Graph(nodes: [centerNode] + nodes, edges: edges)
    }

    static func positions(for topology: GraphTopology, root: Int?) -> [CGPoint] {
        var positions = [CGPoint](repeating: .zero, count: topology.count)
        guard let root else { return positions }

        var level = [Int](repeating: -1, count: topology.count)
        level[root] = 0
        var rings: [[Int]] = [[root]]
        while true {
            var next: [Int] = []
            for n in rings[rings.count - 1] {
                for m in topology.neighbors[n] where level[m] < 0 {
                    level[m] = rings.count
                    next.append(m)
                }
            }
            if next.isEmpty { break }
            rings.append(next)
        }

        var angle = [CGFloat](repeating: 0, count: topology.count)
        var radius: CGFloat = 0
        for k in 1..<rings.count {
            let ring = rings[k]
            radius = max(radius + ringGap, CGFloat(ring.count) * minArc / (2 * .pi))
            if k == 1 {
                // Even spacing from twelve o'clock, families together, then by name.
                let ordered = ring.sorted {
                    (family($0, topology), topology.labels[$0].lowercased()) < (family($1, topology), topology.labels[$1].lowercased())
                }
                for (i, n) in ordered.enumerated() {
                    angle[n] = -.pi / 2 + 2 * .pi * CGFloat(i) / CGFloat(ordered.count)
                }
            } else {
                // Near the circular mean of the parents, then spread to a minimum gap.
                var desired: [(node: Int, angle: CGFloat)] = ring.map { n in
                    var sx: CGFloat = 0, sy: CGFloat = 0
                    for p in topology.neighbors[n] where level[p] == k - 1 {
                        sx += cos(angle[p]); sy += sin(angle[p])
                    }
                    return (n, atan2(sy, sx))
                }
                desired.sort { ($0.angle, $0.node) < ($1.angle, $1.node) }
                let spread = spreadOnCircle(desired.map(\.angle), minGap: min(2 * .pi / CGFloat(ring.count), minArc / radius))
                for (i, d) in desired.enumerated() { angle[d.node] = spread[i] }
            }
            for n in ring { positions[n] = CGPoint(x: cos(angle[n]) * radius, y: sin(angle[n]) * radius) }
        }

        // Anything not connected to the center (can't happen for a neighborhood, but a caller
        // may pass any topology) waits on an outer ring.
        let strays = (0..<topology.count).filter { level[$0] < 0 }
        if !strays.isEmpty {
            radius = max(radius + ringGap, CGFloat(strays.count) * minArc / (2 * .pi))
            for (i, n) in strays.enumerated() {
                let a = -.pi / 2 + 2 * .pi * CGFloat(i) / CGFloat(strays.count)
                positions[n] = CGPoint(x: cos(a) * radius, y: sin(a) * radius)
            }
        }
        return positions
    }

    /// Sorted angles pushed apart until neighbors (cyclically) are at least `minGap` apart,
    /// each move split between the pair so clusters stay centered on where they wanted to be.
    static func spreadOnCircle(_ angles: [CGFloat], minGap: CGFloat) -> [CGFloat] {
        var a = angles
        let n = a.count
        guard n > 1 else { return a }
        for _ in 0..<64 {
            var moved = false
            for i in 0..<n {
                let j = (i + 1) % n
                var gap = a[j] - a[i]
                if j == 0 { gap += 2 * .pi }
                if gap < minGap - 1e-6 {
                    let push = (minGap - gap) / 2
                    a[i] -= push; a[j] += push
                    moved = true
                }
            }
            if !moved { break }
        }
        return a
    }

    private static func family(_ i: Int, _ topology: GraphTopology) -> String {
        FileFamily(ext: topology.exts[i])?.rawValue ?? "~" + topology.exts[i]
    }
}
