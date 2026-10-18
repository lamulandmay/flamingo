import Foundation
import CoreGraphics

/// Whole-disk folder maps have too many nodes for a continuously running force simulation.
/// Pack their complete hierarchy once, retaining every node's coordinates during zoom.
enum GraphOverviewLayout {
    static let threshold = 10_000
    private static let minimumCell: CGFloat = 28
    private static let gap: CGFloat = 12

    /// Deterministic subtree packing, with saved coordinates and pins taking precedence.
    /// Each folder sits above its children; child subtrees occupy disjoint rectangles packed
    /// into near-square rows. No recursion, force ticks, or pairwise distance checks are needed.
    /// Sorting siblings costs O(n log n) at worst; measurement and placement are O(n).
    static func initial(for topology: GraphTopology, saved: SavedLayout?) -> LayoutStore.Initial {
        let n = topology.count
        guard n > 0 else { return .init(positions: [], pinned: [], restored: 0, alpha: 0) }
        let (baseline, children, order) = pack(topology)
        // Preserve the user's map. New descendants follow the nearest restored ancestor's
        // translation instead of appearing at unrelated global coordinates.
        var positions = baseline
        var translation = [CGPoint](repeating: .zero, count: n + 1)
        let savedPins = Set(saved?.pinned ?? [])
        var pinned = Set<Int>(), restored = 0
        for i in order {
            if i < n {
                if let xy = saved?.nodes[topology.ids[i]], xy.count >= 2, xy[0].isFinite, xy[1].isFinite {
                    positions[i] = CGPoint(x: xy[0], y: xy[1])
                    translation[i] = CGPoint(x: positions[i].x - baseline[i].x, y: positions[i].y - baseline[i].y)
                    restored += 1
                    if savedPins.contains(topology.ids[i]) { pinned.insert(i) }
                } else {
                    positions[i] = CGPoint(x: baseline[i].x + translation[i].x, y: baseline[i].y + translation[i].y)
                }
            }
            for child in children[i] { translation[child] = translation[i] }
        }
        return .init(positions: positions, pinned: pinned, restored: restored, alpha: 0)
    }

    /// The packing alone, with nothing restored: the Grid arrangement.
    static func baseline(for topology: GraphTopology) -> [CGPoint] {
        topology.count > 0 ? pack(topology).baseline : []
    }

    private static func pack(_ topology: GraphTopology) -> (baseline: [CGPoint], children: [[Int]], order: [Int]) {
        let n = topology.count
        // A virtual parent packs disconnected roots, including synthetic notes, identically.
        let virtualRoot = n
        var children = [[Int]](repeating: [], count: n + 1)
        for i in 0..<n {
            let parent = parentIndex(of: i, in: topology) ?? virtualRoot
            children[parent].append(i)
        }
        for i in children.indices { children[i].sort { topology.ids[$0] < topology.ids[$1] } }

        var order = [virtualRoot], head = 0
        order.reserveCapacity(n + 1)
        while head < order.count {
            order.append(contentsOf: children[order[head]])
            head += 1
        }

        var width = [CGFloat](repeating: 0, count: n + 1)
        var height = [CGFloat](repeating: 0, count: n + 1)
        var diameter = [CGFloat](repeating: 0, count: n + 1)
        var offset = [CGPoint](repeating: .zero, count: n + 1)
        for i in 0..<n { diameter[i] = max(minimumCell, CGFloat(topology.radius[i]) * 2 + gap) }

        for i in order.reversed() {
            guard !children[i].isEmpty else {
                width[i] = diameter[i]; height[i] = diameter[i]
                continue
            }
            var area: CGFloat = 0, widest: CGFloat = 0
            for child in children[i] {
                area += (width[child] + gap) * (height[child] + gap)
                widest = max(widest, width[child])
            }
            let targetWidth = max(widest, area.squareRoot())
            let header = i == virtualRoot ? 0 : diameter[i] + gap
            var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
            for child in children[i] {
                if x > 0 && x + width[child] > targetWidth {
                    y += rowHeight + gap
                    x = 0; rowHeight = 0
                }
                offset[child] = CGPoint(x: x, y: y + header)
                usedWidth = max(usedWidth, x + width[child])
                rowHeight = max(rowHeight, height[child])
                x += width[child] + gap
            }
            width[i] = max(diameter[i], usedWidth)
            height[i] = header + y + rowHeight
        }

        var origins = [CGPoint](repeating: .zero, count: n + 1)
        origins[virtualRoot] = CGPoint(x: -width[virtualRoot] / 2, y: -height[virtualRoot] / 2)
        var baseline = [CGPoint](repeating: .zero, count: n)
        for i in order {
            if i < n {
                baseline[i] = CGPoint(x: origins[i].x + width[i] / 2, y: origins[i].y + diameter[i] / 2)
            }
            for child in children[i] {
                origins[child] = CGPoint(x: origins[i].x + offset[child].x, y: origins[i].y + offset[child].y)
            }
        }

        return (baseline, children, order)
    }

    static func parentIndex(of i: Int, in topology: GraphTopology) -> Int? {
        let id = topology.ids[i]
        guard id != "/" else { return nil }
        let path = topology.isFolder[i] ? String(id.dropLast()) : id
        let directory = (path as NSString).deletingLastPathComponent
        let parentID = directory.isEmpty || directory == "." ? "/" : directory + "/"
        guard let parent = topology.index[parentID], parent != i, topology.isFolder[parent],
              parentID == "/" || parentID.utf8.count < id.utf8.count else { return nil }
        return parent
    }
}
