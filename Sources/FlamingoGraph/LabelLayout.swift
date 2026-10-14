import Foundation
import CoreGraphics

/// Label placement for the graph canvas, free of fonts and `GraphicsContext` so it can be
/// tested on its own. The renderer measures labels once per topology, then feeds candidates
/// here in priority order every frame.
///
/// A label sits centered under its node with its top edge `gap` points below the node's screen
/// radius, so it can never overlap its own node. If that spot is taken it tries over the node,
/// then right, then left. Placement is greedy: a label is skipped when every spot, grown by
/// `padding`, overlaps a label placed before it.
enum LabelLayout {
    struct Candidate: Equatable {
        var node: Int
        /// Node center, screen space.
        var center: CGPoint
        /// Node radius, screen space.
        var radius: CGFloat
        /// Measured label size.
        var size: CGSize
    }

    struct Placement: Equatable {
        var node: Int
        var rect: CGRect
    }

    /// A node circle that later labels must not cover.
    struct Obstacle: Equatable {
        var node: Int
        var center: CGPoint
        var radius: CGFloat
    }

    /// The part of a node circle labels must keep clear of: its bounding box, shrunk so a label
    /// may graze the empty corners of the box.
    @inline(__always)
    static func obstacleRect(center: CGPoint, radius: CGFloat) -> CGRect {
        let r = radius * 0.85
        return CGRect(x: center.x - r, y: center.y - r, width: r + r, height: r + r)
    }

    /// Where `candidate`'s label goes: centered horizontally, top edge `gap` below the node.
    @inline(__always)
    static func rect(center: CGPoint, radius: CGFloat, size: CGSize, gap: CGFloat) -> CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y + radius + gap, width: size.width, height: size.height)
    }

    static func rect(for candidate: Candidate, gap: CGFloat) -> CGRect {
        rect(center: candidate.center, radius: candidate.radius, size: candidate.size, gap: gap)
    }

    /// Where a label may go, in order of preference: under its node, over it, to its right,
    /// to its left. None of them touch the node. A label that loses the spot under its node to
    /// a busier neighbor still gets shown somewhere nearby.
    @inline(__always)
    static func rects(center: CGPoint, radius: CGFloat, size: CGSize, gap: CGFloat) -> [CGRect] {
        let below = rect(center: center, radius: radius, size: size, gap: gap)
        let side = radius + gap + 1
        return [
            below,
            CGRect(x: below.minX, y: center.y - radius - gap - size.height, width: size.width, height: size.height),
            CGRect(x: center.x + side, y: center.y - size.height / 2, width: size.width, height: size.height),
            CGRect(x: center.x - side - size.width, y: center.y - size.height / 2, width: size.width, height: size.height),
        ]
    }

    /// Greedy placement, the same procedure the renderer runs each frame.
    ///
    /// `candidates` must already be in priority order (first wins). The first `priorityCount`
    /// (selected, hovered and their neighbors) only avoid each other; after them, `obstacles`
    /// (the visible node circles) are laid down and every later label must also keep clear of
    /// nodes other than its own. Labels with an empty or non-finite rect are skipped; with
    /// `bounds`, so are labels entirely outside it.
    static func place(_ candidates: [Candidate], gap: CGFloat, padding: CGFloat, bounds: CGRect? = nil,
                      priorityCount: Int = 0, obstacles: [Obstacle] = []) -> [Placement] {
        var placer = LabelPlacer()
        var out: [Placement] = []
        for (k, c) in candidates.enumerated() {
            if k == priorityCount {
                for o in obstacles { placer.insertObstacle(obstacleRect(center: o.center, radius: o.radius), owner: o.node) }
            }
            for r in rects(center: c.center, radius: c.radius, size: c.size, gap: gap) {
                if let b = bounds, !LabelPlacer.overlaps(r, b) { continue }
                if placer.tryPlace(r, padding: padding, owner: c.node) { out.append(Placement(node: c.node, rect: r)); break }
            }
        }
        return out
    }

    /// Shortens long file names in the middle: `Quarterly Business Rev…ew Final v3`.
    static func truncated(_ name: String, limit: Int) -> String {
        var s = name
        let utf8 = s.utf8
        if utf8.contains(0x0A) || utf8.contains(0x0D) {
            s = String(s.map { $0.isNewline ? " " : $0 })
        }
        // UTF-8 length bounds the character count from above: most names stop here.
        guard limit > 1, s.utf8.count > limit, s.count > limit else { return s }
        let keep = limit - 1
        let head = (keep + 1) / 2
        let tail = keep - head
        let h = String(s.prefix(head)).trimmingCharacters(in: .whitespaces)
        let t = String(s.suffix(tail)).trimmingCharacters(in: .whitespaces)
        return h + "\u{2026}" + t
    }
}

/// Reusable overlap index for greedy label placement: a spatial hash of placed rects (labels and
/// node obstacles), stored in flat arrays so a frame allocates nothing once the buffers have grown.
/// Every rect has an owner node; a label never collides with rects of its own node.
struct LabelPlacer {
    private var heads: [Int32]
    private var next: [Int32] = []
    private var entry: [Int32] = []
    /// Rects too large to hash (never real labels); every probe checks them linearly.
    private var oversized: [Int32] = []
    /// Indexed rects, unpadded: placed labels and obstacles, in insertion order.
    private(set) var rects: [CGRect] = []
    private var owners: [Int] = []
    /// Labels placed (excludes obstacles).
    private(set) var count = 0
    private let mask: Int
    private let cellW: CGFloat
    private let cellH: CGFloat

    /// `buckets` must be a power of two.
    init(buckets: Int = 2048, cell: CGSize = CGSize(width: 64, height: 24)) {
        heads = [Int32](repeating: -1, count: buckets)
        mask = buckets - 1
        cellW = cell.width
        cellH = cell.height
    }

    mutating func reset() {
        if rects.isEmpty { return }
        for i in 0..<heads.count { heads[i] = -1 }
        next.removeAll(keepingCapacity: true)
        entry.removeAll(keepingCapacity: true)
        oversized.removeAll(keepingCapacity: true)
        rects.removeAll(keepingCapacity: true)
        owners.removeAll(keepingCapacity: true)
        count = 0
    }

    @inline(__always)
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }

    /// Places `rect` unless `rect` grown by `padding` overlaps an indexed rect of another owner.
    mutating func tryPlace(_ rect: CGRect, padding: CGFloat, owner: Int = -1) -> Bool {
        guard Self.usable(rect) else { return false }
        if collides(rect, padding: padding, owner: owner) { return false }
        index(rect, owner: owner)
        count += 1
        return true
    }

    /// Indexes `rect` without checking it, so later labels avoid it.
    mutating func insertObstacle(_ rect: CGRect, owner: Int) {
        guard Self.usable(rect) else { return }
        index(rect, owner: owner)
    }

    /// Whether `rect` grown by `padding` overlaps an indexed rect whose owner isn't `owner`.
    func collides(_ rect: CGRect, padding: CGFloat, owner: Int = -1) -> Bool {
        guard Self.usable(rect) else { return true }
        let probe = CGRect(x: rect.origin.x - padding, y: rect.origin.y - padding,
                           width: rect.size.width + 2 * padding, height: rect.size.height + 2 * padding)
        for o in oversized {
            let k = Int(o)
            if Self.overlaps(probe, rects[k]) && (owner < 0 || owners[k] != owner) { return true }
        }
        let cx0 = Int((probe.minX / cellW).rounded(.down)), cx1 = Int((probe.maxX / cellW).rounded(.down))
        let cy0 = Int((probe.minY / cellH).rounded(.down)), cy1 = Int((probe.maxY / cellH).rounded(.down))
        if (cx1 - cx0 + 1) * (cy1 - cy0 + 1) > heads.count {
            for k in 0..<rects.count where Self.overlaps(probe, rects[k]) && (owner < 0 || owners[k] != owner) { return true }
            return false
        }
        for cy in cy0...cy1 {
            for cx in cx0...cx1 {
                var e = heads[Self.hash(cx, cy) & mask]
                while e >= 0 {
                    let k = Int(entry[Int(e)])
                    if Self.overlaps(probe, rects[k]) && (owner < 0 || owners[k] != owner) { return true }
                    e = next[Int(e)]
                }
            }
        }
        return false
    }

    @inline(__always)
    private static func usable(_ r: CGRect) -> Bool {
        let x = r.origin.x, y = r.origin.y, w = r.size.width, h = r.size.height
        return x.isFinite && y.isFinite && w.isFinite && h.isFinite && w > 0 && h > 0 && abs(x) < 1e9 && abs(y) < 1e9
    }

    private mutating func index(_ rect: CGRect, owner: Int) {
        let id = Int32(rects.count)
        rects.append(rect)
        owners.append(owner)
        let ix0 = Int((rect.minX / cellW).rounded(.down)), ix1 = Int((rect.maxX / cellW).rounded(.down))
        let iy0 = Int((rect.minY / cellH).rounded(.down)), iy1 = Int((rect.maxY / cellH).rounded(.down))
        // Rects spanning more cells than there are buckets are checked linearly instead.
        if (ix1 - ix0 + 1) * (iy1 - iy0 + 1) > heads.count {
            oversized.append(id)
            return
        }
        for cy in iy0...iy1 {
            for cx in ix0...ix1 {
                let b = Self.hash(cx, cy) & mask
                next.append(heads[b])
                entry.append(id)
                heads[b] = Int32(next.count - 1)
            }
        }
    }

    @inline(__always)
    private static func hash(_ x: Int, _ y: Int) -> Int {
        (x &* 73_856_093) ^ (y &* 19_349_663)
    }
}
