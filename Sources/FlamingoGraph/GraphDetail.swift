import Foundation
import CoreGraphics

/// Semantic zoom changes only presentation. The full folder hierarchy stays in the layout,
/// so zooming back out and in never reseeds nodes or moves the point under the cursor.
enum GraphDetail {
    static let visibilityCutoff = 0.02

    /// Zoom at the middle of each folder's reveal. Small graphs need no decluttering.
    /// Depth is relative to the displayed subtree; siblings are slightly staggered so a
    /// crowded level does not appear all at once.
    static func revealZooms(ids: [String]) -> [CGFloat] {
        let folders = ids.filter { $0.hasSuffix("/") }
        guard folders.count > 12 else { return Array(repeating: 0, count: ids.count) }
        let shallowest = folders.map { $0.split(separator: "/").count }.min() ?? 0
        var siblings: [String: Int] = [:]
        for id in folders { siblings[parent(id), default: 0] += 1 }
        return ids.map { id in
            guard id.hasSuffix("/") else { return 0 }
            let depth = id.split(separator: "/").count - shallowest
            guard depth > 0 else { return 0 }
            let crowd = min(1.7, 1 + max(0, log2(Double(siblings[parent(id), default: 1]) / 8)) * 0.15)
            let stagger = 0.85 + Double(LayoutStore.hash(id) % 301) / 1000
            return CGFloat(min(2.4, 0.12 * pow(1.65, Double(min(depth - 1, 6))) * crowd * stagger))
        }
    }

    /// A continuous, reversible fade tied directly to magnification. It needs no timer and
    /// does not continue moving after a gesture stops (including under Reduce Motion).
    static func opacity(revealZoom: CGFloat, zoom: CGFloat) -> Double {
        guard revealZoom > 0 else { return 1 }
        guard zoom.isFinite, zoom > 0 else { return 0 }
        let t = Double(min(1, max(0, (zoom / revealZoom - 0.65) / 0.7)))
        return t * t * (3 - 2 * t)
    }

    private static func parent(_ id: String) -> String {
        (String(id.dropLast()) as NSString).deletingLastPathComponent
    }
}
