import Foundation
import CoreGraphics
import FlamingoDesign

/// How the vault graph is laid out. Organic is the force layout people shape by dragging; the
/// others are worked out from the folder tree every time the graph changes, so a file always
/// sits with its folder and nothing needs tidying by hand.
public enum GraphArrangement: String, CaseIterable, Identifiable, Sendable {
    /// The force layout: links pull, everything else pushes apart. Drags pin.
    case organic
    /// Every folder is a circle: its files in rings around it, its subfolders packed outside.
    case circles
    /// The top folder in the middle, each level of folders on its own ring, every file on
    /// one outer circle beside its siblings.
    case radial
    /// Circles on one hexagonal grid: each folder a cell cluster of its files.
    case honeycomb
    /// Each folder above its contents, in tidy rows.
    case grid

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .organic: "Organic"
        case .circles: "Circles"
        case .radial: "Radial"
        case .honeycomb: "Honeycomb"
        case .grid: "Grid"
        }
    }

    public var symbol: String {
        switch self {
        case .organic: "point.3.connected.trianglepath.dotted"
        case .circles: "circle.dotted.circle"
        case .radial: "target"
        case .honeycomb: "circle.hexagongrid"
        case .grid: "square.grid.3x3"
        }
    }
}

/// Positions for every arrangement but organic. Pure, deterministic and independent of node
/// order; O(n log n) for the tree and sorting, so a whole-disk map arranges off the main
/// thread in about the time it takes to index.
enum ArrangedLayout {
    /// World units between neighbouring files in a folder: two of the largest common nodes
    /// side by side with room to spare.
    static let spacing: CGFloat = 22
    /// Radial: world units between rings of folders.
    static let ringGap: CGFloat = 66

    static func initial(for topology: GraphTopology, arrangement: GraphArrangement) -> LayoutStore.Initial {
        let positions = self.positions(for: topology, arrangement: arrangement)
        return .init(positions: positions, pinned: [], restored: topology.count, alpha: 0)
    }

    static func positions(for topology: GraphTopology, arrangement: GraphArrangement) -> [CGPoint] {
        guard topology.count > 0 else { return [] }
        switch arrangement {
        case .organic, .grid: return GraphOverviewLayout.baseline(for: topology)
        case .circles: return packed(topology, hex: false)
        case .honeycomb: return packed(topology, hex: true)
        case .radial: return radial(topology)
        }
    }

    // MARK: - Folder tree

    /// Containment from paths, with a virtual root (index `count`) above the top folder and
    /// anything that has no folder of its own (inbox notes, links from outside the scope).
    /// Children are folders first, then files by family (decks together, sheets together)
    /// and name, so arrangements read in the same order every time.
    struct FolderTree {
        let root: Int
        var children: [[Int]]
        /// Parents before children, starting at `root`.
        var order: [Int]

        init(_ topology: GraphTopology) {
            let n = topology.count
            root = n
            children = [[Int]](repeating: [], count: n + 1)
            for i in 0..<n { children[GraphOverviewLayout.parentIndex(of: i, in: topology) ?? n].append(i) }
            let families = FileFamily.allCases
            let rank = (0..<n).map { i -> Int in
                topology.isFolder[i] ? -1 : FileFamily(ext: topology.exts[i]).flatMap { families.firstIndex(of: $0) } ?? families.count
            }
            let names = topology.labels.map { $0.lowercased() }
            for i in children.indices {
                children[i].sort { a, b in
                    if rank[a] != rank[b] { return rank[a] < rank[b] }
                    if names[a] != names[b] { return names[a] < names[b] }
                    return topology.ids[a] < topology.ids[b]
                }
            }
            order = [root]
            order.reserveCapacity(n + 1)
            var head = 0
            while head < order.count {
                order.append(contentsOf: children[order[head]])
                head += 1
            }
        }
    }

    // MARK: - Circles and honeycomb

    /// Bottom-up: a folder's files form its core (rings, or hexagonal rings, around the folder
    /// node), and its subfolders' clusters are packed around the core as circles. The folder
    /// node stays at the middle of its own core, so every cluster has its folder at the hub.
    /// Honeycomb snaps each cluster onto one hexagonal lattice, which keeps every node of the
    /// whole map on it.
    private static func packed(_ topology: GraphTopology, hex: Bool) -> [CGPoint] {
        let n = topology.count
        let tree = FolderTree(topology)
        let d = Double(spacing)
        // Room between clusters on top of the spacing inside one: a full spacing, plus the
        // most a snap to the lattice can move a cluster.
        let pad = d / 2 + (hex ? d * 0.6 : 0)
        var offset = [CGPoint](repeating: .zero, count: n + 1)
        // Distance from a node to the farthest node of its cluster, plus half a spacing.
        var extent = [Double](repeating: d / 2, count: n + 1)

        for i in tree.order.reversed() {
            let kids = tree.children[i]
            guard !kids.isEmpty else { continue }
            let leaves = kids.filter { tree.children[$0].isEmpty }
            let groups = kids.filter { !tree.children[$0].isEmpty }
            let hub = i < n
            let slots = hex ? hexSlots(leaves.count, aroundHub: hub) : ringSlots(leaves.count, aroundHub: hub)
            var core = hub ? d / 2 : 0
            for (k, leaf) in leaves.enumerated() {
                let p = CGPoint(x: slots[k].x * d, y: slots[k].y * d)
                offset[leaf] = p
                core = max(core, Double(hypot(p.x, p.y)) + d / 2)
            }
            guard !groups.isEmpty else { extent[i] = core; continue }

            let sorted = groups.sorted { extent[$0] != extent[$1] ? extent[$0] > extent[$1] : topology.ids[$0] < topology.ids[$1] }
            var circles: [PackCircle] = core > 0 ? [PackCircle(r: core + pad)] : []
            circles += sorted.map { PackCircle(r: extent[$0] + pad) }
            packSiblings(&circles)
            let first = circles.count - sorted.count
            var reach = core
            for (k, g) in sorted.enumerated() {
                var p = CGPoint(x: circles[first + k].x, y: circles[first + k].y)
                if hex { p = snapToLattice(p, spacing: d) }
                offset[g] = p
                reach = max(reach, Double(hypot(p.x, p.y)) + extent[g])
            }
            extent[i] = reach
        }

        var positions = [CGPoint](repeating: .zero, count: n + 1)
        for i in tree.order {
            for c in tree.children[i] {
                positions[c] = CGPoint(x: positions[i].x + offset[c].x, y: positions[i].y + offset[c].y)
            }
        }
        return Array(positions.prefix(n))
    }

    /// `count` points in units of the spacing on concentric rings, the last ring spread evenly.
    /// Ring k holds ⌊2πk⌋ points, so neighbours on a ring are at least one spacing apart. With
    /// no hub, the first point takes the middle.
    static func ringSlots(_ count: Int, aroundHub hub: Bool) -> [CGPoint] {
        var out: [CGPoint] = []
        out.reserveCapacity(count)
        if !hub && count > 0 { out.append(.zero) }
        var ring = 1
        while out.count < count {
            let capacity = Int(2 * Double.pi * Double(ring))
            let m = min(capacity, count - out.count)
            // Alternate rings start half a step apart so spokes don't line up.
            let phase = -Double.pi / 2 + (ring.isMultiple(of: 2) ? Double.pi / Double(m) : 0)
            for t in 0..<m {
                let a = phase + 2 * Double.pi * Double(t) / Double(m)
                out.append(CGPoint(x: Double(ring) * cos(a), y: Double(ring) * sin(a)))
            }
            ring += 1
        }
        return out
    }

    /// `count` cells of a hexagonal lattice (unit spacing) in rings around the middle, the last
    /// ring spread evenly round its six sides.
    static func hexSlots(_ count: Int, aroundHub hub: Bool) -> [CGPoint] {
        // Axial directions, walked once round each ring.
        let directions = [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)]
        var out: [CGPoint] = []
        out.reserveCapacity(count)
        if !hub && count > 0 { out.append(.zero) }
        var ring = 1
        while out.count < count {
            var cells: [(Int, Int)] = []
            var q = -ring, r = ring
            for (dq, dr) in directions {
                for _ in 0..<ring {
                    cells.append((q, r))
                    q += dq; r += dr
                }
            }
            let m = min(cells.count, count - out.count)
            for t in 0..<m {
                let (cq, cr) = cells[t * cells.count / m]
                out.append(axial(cq, cr))
            }
            ring += 1
        }
        return out
    }

    /// Axial lattice coordinates to unit-spacing world units: rows `√3/2` apart, each row
    /// shifted half a cell.
    private static func axial(_ q: Int, _ r: Int) -> CGPoint {
        CGPoint(x: Double(q) + Double(r) / 2, y: Double(r) * 3.0.squareRoot() / 2)
    }

    /// The nearest point of the hexagonal lattice with `spacing` through the origin.
    static func snapToLattice(_ p: CGPoint, spacing d: Double) -> CGPoint {
        let fr = Double(p.y) / (d * 3.0.squareRoot() / 2)
        let fq = Double(p.x) / d - fr / 2
        let fs = -fq - fr
        var q = fq.rounded(), r = fr.rounded()
        let s = fs.rounded()
        let dq = abs(q - fq), dr = abs(r - fr), ds = abs(s - fs)
        if dq > dr && dq > ds { q = -r - s } else if dr > ds { r = -q - s }
        return CGPoint(x: d * (q + r / 2), y: d * 3.0.squareRoot() / 2 * r)
    }

    // MARK: - Sibling packing

    struct PackCircle {
        var x: Double = 0
        var y: Double = 0
        var r: Double
    }

    /// d3's front-chain sibling packing (Wang et al., `d3.packSiblings`), with the first circle
    /// held at the origin so the rest gather round it rather than round the pair's midpoint.
    static func packSiblings(_ c: inout [PackCircle]) {
        let n = c.count
        guard n > 0 else { return }
        c[0].x = 0; c[0].y = 0
        guard n > 1 else { return }
        c[1].x = c[0].r + c[1].r; c[1].y = 0
        guard n > 2 else { return }
        place(c[1], c[0], &c[2])

        var next = [Int](repeating: 0, count: n), previous = [Int](repeating: 0, count: n)
        next[0] = 1; next[1] = 2; next[2] = 0
        previous[1] = 0; previous[2] = 1; previous[0] = 2
        var a = 0, b = 1, i = 3

        func score(_ node: Int) -> Double {
            let p = c[node], q = c[next[node]], ab = p.r + q.r
            let dx = (p.x * q.r + q.x * p.r) / ab, dy = (p.y * q.r + q.y * p.r) / ab
            return dx * dx + dy * dy
        }

        pack: while i < n {
            place(c[a], c[b], &c[i])
            // The closest circle on the front chain that the new one overlaps, if any;
            // closeness is distance along the chain.
            var j = next[b], k = previous[a]
            var sj = c[b].r, sk = c[a].r
            repeat {
                if sj <= sk {
                    if intersects(c[j], c[i]) {
                        b = j; next[a] = b; previous[b] = a
                        continue pack
                    }
                    sj += c[j].r; j = next[j]
                } else {
                    if intersects(c[k], c[i]) {
                        a = k; next[a] = b; previous[b] = a
                        continue pack
                    }
                    sk += c[k].r; k = previous[k]
                }
            } while j != next[k]

            previous[i] = a; next[i] = b; next[a] = i; previous[b] = i; b = i
            // The new closest pair to the centre.
            var best = score(a), node = next[i]
            while node != b {
                let s = score(node)
                if s < best { a = node; best = s }
                node = next[node]
            }
            b = next[a]
            i += 1
        }
    }

    /// Puts `c` tangent to both `a` and `b` (d3's `place(b, a, c)`).
    private static func place(_ b: PackCircle, _ a: PackCircle, _ c: inout PackCircle) {
        let dx = b.x - a.x, dy = b.y - a.y, d2 = dx * dx + dy * dy
        guard d2 > 0 else { c.x = a.x + c.r; c.y = a.y; return }
        let a2 = (a.r + c.r) * (a.r + c.r), b2 = (b.r + c.r) * (b.r + c.r)
        if a2 > b2 {
            let x = (d2 + b2 - a2) / (2 * d2), y = max(0, b2 / d2 - x * x).squareRoot()
            c.x = b.x - x * dx - y * dy
            c.y = b.y - x * dy + y * dx
        } else {
            let x = (d2 + a2 - b2) / (2 * d2), y = max(0, a2 / d2 - x * x).squareRoot()
            c.x = a.x + x * dx - y * dy
            c.y = a.y + x * dy + y * dx
        }
    }

    private static func intersects(_ a: PackCircle, _ b: PackCircle) -> Bool {
        let dr = a.r + b.r - 1e-6, dx = b.x - a.x, dy = b.y - a.y
        return dr > 0 && dr * dr > dx * dx + dy * dy
    }

    // MARK: - Radial

    /// A radial tree. The top folder sits in the middle (or nothing does, when there are
    /// several), folders at depth k on ring k, and every file on one outer circle, siblings
    /// side by side. Each node's wedge is what its subtree needs at its own radius; when the
    /// circle is too small for everything, all the rings grow by the same factor.
    private static func radial(_ topology: GraphTopology) -> [CGPoint] {
        let n = topology.count
        let tree = FolderTree(topology)
        var children = tree.children
        var center = tree.root
        let topFolders = children[tree.root].filter { !children[$0].isEmpty }
        if topFolders.count == 1 {
            // Loose files from outside the folder go round the edge with the rest.
            center = topFolders[0]
            children[center] += children[tree.root].filter { $0 != center }
            children[tree.root] = [center]
        }

        var order = [center], depth = [Int](repeating: 0, count: n + 1), head = 0
        while head < order.count {
            let i = order[head]; head += 1
            for c in children[i] { depth[c] = depth[i] + 1; order.append(c) }
        }
        let deepest = order.filter { !children[$0].isEmpty }.map { depth[$0] }.max() ?? 0
        let s = Double(spacing), g = Double(ringGap)
        let outer = Double(deepest + 1) * g

        // Angle each subtree needs at unit scale.
        var need = [Double](repeating: 0, count: n + 1)
        for i in order.reversed() {
            if children[i].isEmpty { need[i] = s / outer; continue }
            let sum = children[i].reduce(0) { $0 + need[$1] }
            need[i] = i == center ? sum : max(s / (Double(depth[i]) * g), sum)
        }
        let scale = max(1, need[center] / (2 * Double.pi))

        var positions = [CGPoint](repeating: .zero, count: n + 1)
        var wedge = [(start: Double, width: Double)](repeating: (0, 0), count: n + 1)
        wedge[center] = (-Double.pi / 2, 2 * Double.pi)
        for i in order {
            let kids = children[i]
            guard !kids.isEmpty else { continue }
            let total = kids.reduce(0) { $0 + need[$1] }
            var start = wedge[i].start
            for c in kids {
                let width = total > 0 ? wedge[i].width * need[c] / total : 0
                wedge[c] = (start, width)
                let angle = start + width / 2
                let radius = (children[c].isEmpty ? outer : Double(depth[c]) * g) * scale
                positions[c] = CGPoint(x: radius * cos(angle), y: radius * sin(angle))
                start += width
            }
        }
        return Array(positions.prefix(n))
    }
}
