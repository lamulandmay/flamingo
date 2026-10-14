import Foundation

/// Barnes-Hut quadtree over a point set, stored as flat buffers and rebuilt in place every
/// tick. Used by `ForceSimulation` for many-body repulsion with d3-force semantics.
///
/// Written for unoptimized builds (`scripts/run.sh` builds debug): raw pointers instead of
/// arrays (pointer subscripts are transparent, array subscripts are calls at -Onone), `while`
/// loops instead of ranges, no generics, closures or reference counting in the hot paths, and
/// an explicit stack instead of recursion. Not thread-safe.
final class Quadtree {
    /// Points that still share a cell this deep are kept together in one leaf. Keeps nearly
    /// coincident points from building arbitrarily deep chains.
    static let maxDepth = 48

    private(set) var nodeCount = 0
    private var nodeCapacity = 0
    private var pointCapacity = 0

    /// Four child slots per node, `-1` when empty.
    private var child: UnsafeMutablePointer<Int>
    /// `>= 0`: leaf, index of its first point (coincident points chain through `next`).
    /// `-1`: internal node. `-2`: empty root.
    private var head: UnsafeMutablePointer<Int>
    /// Side length of the node's square cell.
    private var width: UnsafeMutablePointer<Double>
    /// Strength-weighted center and summed strength of everything below the node.
    private var cx: UnsafeMutablePointer<Double>
    private var cy: UnsafeMutablePointer<Double>
    private var value: UnsafeMutablePointer<Double>
    /// Per point: next point in the same leaf, `-1` at the end.
    private var next: UnsafeMutablePointer<Int>
    private let stack: UnsafeMutablePointer<Int>
    private let stackCapacity = 4 * (Quadtree.maxDepth + 4)

    /// Root cell, valid after `build`.
    private(set) var originX = 0.0
    private(set) var originY = 0.0
    private(set) var size = 0.0

    init() {
        nodeCapacity = 64
        pointCapacity = 16
        child = .allocate(capacity: 4 * nodeCapacity)
        head = .allocate(capacity: nodeCapacity)
        width = .allocate(capacity: nodeCapacity)
        cx = .allocate(capacity: nodeCapacity)
        cy = .allocate(capacity: nodeCapacity)
        value = .allocate(capacity: nodeCapacity)
        next = .allocate(capacity: pointCapacity)
        stack = .allocate(capacity: stackCapacity)
    }

    deinit {
        child.deallocate(); head.deallocate(); width.deallocate()
        cx.deallocate(); cy.deallocate(); value.deallocate()
        next.deallocate(); stack.deallocate()
    }

    private func growNodes(to minimum: Int) {
        var cap = nodeCapacity
        while cap < minimum { cap *= 2 }
        let n = nodeCount
        func move(_ p: inout UnsafeMutablePointer<Double>) {
            let q = UnsafeMutablePointer<Double>.allocate(capacity: cap)
            q.update(from: p, count: n)
            p.deallocate()
            p = q
        }
        let c = UnsafeMutablePointer<Int>.allocate(capacity: 4 * cap)
        c.update(from: child, count: 4 * n)
        child.deallocate(); child = c
        let h = UnsafeMutablePointer<Int>.allocate(capacity: cap)
        h.update(from: head, count: n)
        head.deallocate(); head = h
        move(&width); move(&cx); move(&cy); move(&value)
        nodeCapacity = cap
    }

    private func reservePoints(_ n: Int) {
        guard n > pointCapacity else { return }
        next.deallocate()
        pointCapacity = max(n, pointCapacity * 2)
        next = .allocate(capacity: pointCapacity)
    }

    /// Rebuilds the tree over `n` points. `strengths` are the per-point charges summed into
    /// each cell (d3: `quad.value`); cell centers are weighted by their absolute value.
    func build(count n: Int, xs: UnsafePointer<Double>, ys: UnsafePointer<Double>, strengths: UnsafePointer<Double>) {
        reservePoints(n)
        nodeCount = 0
        if nodeCapacity < 2 * n + Quadtree.maxDepth + 8 { growNodes(to: 2 * n + Quadtree.maxDepth + 8) }

        // Bounds: a square cell over every point.
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        var i = 0
        while i < n {
            let x = xs[i], y = ys[i]
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
            i += 1
        }
        if n == 0 { minX = 0; minY = 0; maxX = 0; maxY = 0 }
        var s = maxX - minX
        let sh = maxY - minY
        if sh > s { s = sh }
        if !(s > 0) || !(s < Double.infinity) { s = 1 }
        originX = minX; originY = minY; size = s

        var child = self.child, head = self.head, width = self.width
        let next = self.next
        let maxDepth = Quadtree.maxDepth

        head[0] = -2
        child[0] = -1; child[1] = -1; child[2] = -1; child[3] = -1
        width[0] = s
        var nc = 1

        var p = 0
        while p < n {
            if nc + maxDepth + 4 > nodeCapacity {
                nodeCount = nc
                growNodes(to: nc + maxDepth + 4)
                child = self.child; head = self.head; width = self.width
            }
            let px = xs[p], py = ys[p]
            var q = 0
            var qx0 = minX, qy0 = minY, qw = s
            var depth = 0
            while true {
                let h = head[q]
                if h == -2 {
                    head[q] = p; next[p] = -1
                    break
                }
                if h >= 0 {
                    // Leaf. Coincident (or too deep): chain the point onto it.
                    if depth >= maxDepth || (xs[h] == px && ys[h] == py) {
                        next[p] = h; head[q] = p
                        break
                    }
                    // Split: push the existing leaf one level down, then descend again.
                    let half = qw * 0.5
                    var k = 0
                    if xs[h] >= qx0 + half { k = 1 }
                    if ys[h] >= qy0 + half { k += 2 }
                    let c = nc
                    nc += 1
                    head[c] = h; width[c] = half
                    let c4 = 4 * c
                    child[c4] = -1; child[c4 + 1] = -1; child[c4 + 2] = -1; child[c4 + 3] = -1
                    head[q] = -1
                    child[4 * q + k] = c
                    continue
                }
                // Internal: descend into the point's quadrant.
                let half = qw * 0.5
                var k = 0
                if px >= qx0 + half { k = 1; qx0 += half }
                if py >= qy0 + half { k += 2; qy0 += half }
                qw = half
                depth += 1
                let slot = 4 * q + k
                let c = child[slot]
                if c < 0 {
                    let c2 = nc
                    nc += 1
                    head[c2] = p; next[p] = -1; width[c2] = half
                    let c4 = 4 * c2
                    child[c4] = -1; child[c4 + 1] = -1; child[c4 + 2] = -1; child[c4 + 3] = -1
                    child[slot] = c2
                    break
                }
                q = c
            }
            p += 1
        }
        nodeCount = nc

        // Children are always allocated after their parent, so a reverse sweep is post-order.
        let cx = self.cx, cy = self.cy, value = self.value
        var q = nc - 1
        while q >= 0 {
            let h = head[q]
            if h >= 0 {
                var v = 0.0, w = 0.0, sx = 0.0, sy = 0.0, ux = 0.0, uy = 0.0, cnt = 0.0
                var j = h
                while j >= 0 {
                    let sj = strengths[j]
                    v += sj
                    let a = sj < 0 ? -sj : sj
                    w += a
                    let x = xs[j], y = ys[j]
                    sx += a * x; sy += a * y
                    ux += x; uy += y; cnt += 1
                    j = next[j]
                }
                value[q] = v
                if w > 0 { cx[q] = sx / w; cy[q] = sy / w } else { cx[q] = ux / cnt; cy[q] = uy / cnt }
            } else if h == -1 {
                var v = 0.0, w = 0.0, sx = 0.0, sy = 0.0
                let c4 = 4 * q
                var k = 0
                while k < 4 {
                    let c = child[c4 + k]
                    if c >= 0 {
                        let cv = value[c]
                        v += cv
                        let a = cv < 0 ? -cv : cv
                        w += a
                        sx += a * cx[c]; sy += a * cy[c]
                    }
                    k += 1
                }
                value[q] = v
                if w > 0 { cx[q] = sx / w; cy[q] = sy / w } else { cx[q] = 0; cy[q] = 0 }
            } else {
                value[q] = 0; cx[q] = 0; cy[q] = 0
            }
            q -= 1
        }
    }

    /// d3 `forceManyBody` over the tree built by the last `build` (same points, same
    /// strengths). Adds `alpha`-scaled velocity to `vx`/`vy`. `theta2` is theta squared;
    /// 0 is exact. Coincident points are separated with a deterministic jiggle from `rng`.
    func applyCharge(count n: Int, xs: UnsafePointer<Double>, ys: UnsafePointer<Double>,
                     strengths: UnsafePointer<Double>, alpha: Double, theta2: Double,
                     distanceMin2: Double, distanceMax2: Double,
                     vx: UnsafeMutablePointer<Double>, vy: UnsafeMutablePointer<Double>,
                     rng: inout UInt64) {
        guard nodeCount > 0, n > 1 else { return }
        let child = self.child, head = self.head, width = self.width
        let cx = self.cx, cy = self.cy, value = self.value, next = self.next
        let stack = self.stack
        let invTheta2 = 1 / theta2
        var seed = rng

        var i = 0
        while i < n {
            let xi = xs[i], yi = ys[i]
            var fx = 0.0, fy = 0.0
            stack[0] = 0
            var sp = 1
            while sp > 0 {
                sp -= 1
                let q = stack[sp]
                let v = value[q]
                if v == 0 { continue }
                var dx = cx[q] - xi
                var dy = cy[q] - yi
                var l = dx * dx + dy * dy
                let w = width[q]
                // Far enough: treat the whole cell as one body at its center.
                if w * w * invTheta2 < l {
                    if l < distanceMax2 {
                        if dx == 0 {
                            seed = seed &* 6364136223846793005 &+ 1442695040888963407
                            dx = (Double(seed &>> 11) * 0x1p-53 - 0.5) * 1e-6
                            l += dx * dx
                        }
                        if dy == 0 {
                            seed = seed &* 6364136223846793005 &+ 1442695040888963407
                            dy = (Double(seed &>> 11) * 0x1p-53 - 0.5) * 1e-6
                            l += dy * dy
                        }
                        if l < distanceMin2 { l = (distanceMin2 * l).squareRoot() }
                        let f = v * alpha / l
                        fx += dx * f
                        fy += dy * f
                    }
                    continue
                }
                let h = head[q]
                if h < 0 {
                    let c4 = 4 * q
                    var c = child[c4]
                    if c >= 0 { stack[sp] = c; sp += 1 }
                    c = child[c4 + 1]
                    if c >= 0 { stack[sp] = c; sp += 1 }
                    c = child[c4 + 2]
                    if c >= 0 { stack[sp] = c; sp += 1 }
                    c = child[c4 + 3]
                    if c >= 0 { stack[sp] = c; sp += 1 }
                    continue
                }
                if l >= distanceMax2 { continue }
                if h != i || next[h] >= 0 {
                    if dx == 0 {
                        seed = seed &* 6364136223846793005 &+ 1442695040888963407
                        dx = (Double(seed &>> 11) * 0x1p-53 - 0.5) * 1e-6
                        l += dx * dx
                    }
                    if dy == 0 {
                        seed = seed &* 6364136223846793005 &+ 1442695040888963407
                        dy = (Double(seed &>> 11) * 0x1p-53 - 0.5) * 1e-6
                        l += dy * dy
                    }
                    if l < distanceMin2 { l = (distanceMin2 * l).squareRoot() }
                }
                var j = h
                while j >= 0 {
                    if j != i {
                        let f = strengths[j] * alpha / l
                        fx += dx * f
                        fy += dy * f
                    }
                    j = next[j]
                }
            }
            vx[i] += fx
            vy[i] += fy
            i += 1
        }
        rng = seed
    }
}

extension Quadtree {
    /// Convenience for tests and tools: the velocity change one many-body pass would apply to
    /// each point (alpha 1, d3 semantics).
    static func chargeForces(xs: [Double], ys: [Double], strengths: [Double], theta: Double,
                             distanceMin: Double = 1, distanceMax: Double = .infinity) -> (x: [Double], y: [Double]) {
        let n = xs.count
        precondition(ys.count == n && strengths.count == n)
        var fx = [Double](repeating: 0, count: n), fy = [Double](repeating: 0, count: n)
        var rng: UInt64 = 0x9E3779B97F4A7C15
        let tree = Quadtree()
        xs.withUnsafeBufferPointer { xb in
            ys.withUnsafeBufferPointer { yb in
                strengths.withUnsafeBufferPointer { sb in
                    fx.withUnsafeMutableBufferPointer { fxb in
                        fy.withUnsafeMutableBufferPointer { fyb in
                            guard let x = xb.baseAddress, let y = yb.baseAddress, let s = sb.baseAddress,
                                  let vx = fxb.baseAddress, let vy = fyb.baseAddress else { return }
                            tree.build(count: n, xs: x, ys: y, strengths: s)
                            tree.applyCharge(count: n, xs: x, ys: y, strengths: s, alpha: 1, theta2: theta * theta,
                                             distanceMin2: distanceMin * distanceMin,
                                             distanceMax2: distanceMax * distanceMax,
                                             vx: vx, vy: vy, rng: &rng)
                        }
                    }
                }
            }
        }
        return (fx, fy)
    }
}
