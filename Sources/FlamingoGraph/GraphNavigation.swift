import Foundation
import CoreGraphics

/// Arrow-key movement between nodes.
enum GraphNavigation {
    /// Graph neighbors win over spatially closer strangers unless the stranger is a lot closer.
    static let neighborDiscount: CGFloat = 0.6

    /// The node to move to from `current` when an arrow is pressed. Candidates must lie ahead in
    /// that direction; within a 60° half-angle cone, scored by distance along the arrow plus twice
    /// the sideways drift (so aligned nodes win), with graph neighbors discounted. If the cone is
    /// empty, anything in the half-plane ahead. `eligible` (the filter mask) restricts candidates.
    static func next(from current: Int, _ direction: GraphDirection, positions: [CGPoint],
                     topology: GraphTopology, eligible: [Bool]? = nil) -> Int? {
        guard positions.indices.contains(current) else { return nil }
        let d: CGPoint
        switch direction {
        case .up: d = CGPoint(x: 0, y: -1)
        case .down: d = CGPoint(x: 0, y: 1)
        case .left: d = CGPoint(x: -1, y: 0)
        case .right: d = CGPoint(x: 1, y: 0)
        }
        var isNeighbor = [Bool](repeating: false, count: positions.count)
        for n in topology.neighbors[current] where n < isNeighbor.count { isNeighbor[n] = true }

        let origin = positions[current]
        var bestInCone: (index: Int, score: CGFloat)?
        var bestAhead: (index: Int, score: CGFloat)?
        for j in positions.indices where j != current {
            if let eligible, j < eligible.count, !eligible[j] { continue }
            let vx = positions[j].x - origin.x, vy = positions[j].y - origin.y
            let along = vx * d.x + vy * d.y
            guard along > 0.5 else { continue }
            let across = abs(vx * d.y - vy * d.x)
            var score = along + 2 * across
            if isNeighbor[j] { score *= neighborDiscount }
            if across <= along * 1.732 {
                if bestInCone == nil || score < bestInCone!.score { bestInCone = (j, score) }
            } else if bestAhead == nil || score < bestAhead!.score {
                bestAhead = (j, score)
            }
        }
        return bestInCone?.index ?? bestAhead?.index
    }

    /// The eligible node closest to a world point. Where arrows start when nothing is selected.
    static func nearest(to p: CGPoint, positions: [CGPoint], eligible: [Bool]? = nil) -> Int? {
        var best: (index: Int, d2: CGFloat)?
        for j in positions.indices {
            if let eligible, j < eligible.count, !eligible[j] { continue }
            let dx = positions[j].x - p.x, dy = positions[j].y - p.y
            let d2 = dx * dx + dy * dy
            if best == nil || d2 < best!.d2 { best = (j, d2) }
        }
        return best?.index
    }
}
