import Foundation
import CoreGraphics

/// Single-threaded force simulation with d3-force semantics. Not thread-safe; `LayoutEngine`
/// owns one and ticks it on its worker thread.
///
/// Forces, applied in this order every tick (as d3 would with forces registered in this order):
/// - link springs (`forceLink`): one spring per connected pair, strength `1/min(degree)`,
///   biased by degree. `trail`-only pairs are longer and weaker.
/// - many-body repulsion (`forceManyBody`) through a Barnes-Hut `Quadtree`.
/// - gravity toward the origin (`forceX` + `forceY`), which keeps orphans and small
///   components in a ring around the main cluster.
/// - mild collision (`forceCollide`) through a uniform grid.
///
/// The whole thing is bit-for-bit deterministic for the same inputs: no system randomness,
/// no dictionary iteration in the force code, coincident points are separated with a seeded
/// LCG. Hot loops are written for -Onone (see `Quadtree`).
final class ForceSimulation {
    struct Parameters: Equatable, Sendable {
        /// Many-body strength per node. Negative repels. d3's default is -30.
        var charge: Double = -40
        /// Barnes-Hut accuracy. 0 is exact.
        var theta: Double = 0.9
        var distanceMin: Double = 1
        var distanceMax: Double = .infinity
        /// Rest length of `link` springs, world units.
        var linkDistance: Double = 32
        /// Multiplies d3's default spring strength `1/min(degree)`.
        var linkStrength: Double = 1
        /// `trail`-only pairs: rest length and strength relative to a `link`.
        var trailDistanceScale: Double = 1.3
        var trailStrengthScale: Double = 0.5
        /// `forceX`/`forceY` strength toward the origin.
        var gravity: Double = 0.06
        /// Collision radius is `topology.radius[i] + collisionPadding`.
        var collisionPadding: Double = 2
        var collisionStrength: Double = 0.6
        var alphaMin: Double = 0.001
        /// Ticks from alpha 1 to `alphaMin`; sets `alphaDecay`.
        var settleTicks: Double = 250
        var velocityDecay: Double = 0.4

        var alphaDecay: Double { 1 - pow(alphaMin, 1 / max(settleTicks, 1)) }

        init() {}
    }

    let count: Int
    let parameters: Parameters

    var alpha: Double = 1
    var alphaMin: Double
    var alphaDecay: Double
    var alphaTarget: Double = 0
    /// d3 semantics: velocities are multiplied by `1 - velocityDecay` every tick.
    var velocityDecay: Double
    var isSettled: Bool { alpha < alphaMin && alphaTarget < alphaMin }
    /// Ticks run so far.
    private(set) var tickCount = 0
    private(set) var fixed: Set<Int> = []

    private let xs, ys, vxs, vys, fxs, fys: UnsafeMutablePointer<Double>
    private let isFixed: UnsafeMutablePointer<UInt8>
    private let charges: UnsafeMutablePointer<Double>
    private let collideRadius: UnsafeMutablePointer<Double>
    private let maxCollideRadius: Double

    private let linkCount: Int
    private let linkSource, linkTarget: UnsafeMutablePointer<Int>
    private let linkLength, linkStrength, linkBias: UnsafeMutablePointer<Double>

    private let tree = Quadtree()
    private let cellOf, cellItems: UnsafeMutablePointer<Int>
    private var cellStart: UnsafeMutablePointer<Int>
    private var cellCapacity: Int
    private let gridMaxDim: Int
    private var rng: UInt64 = 0x853C49E6748FEA9B

    /// `positions` is indexed like `topology`; missing or non-finite entries get a d3
    /// phyllotaxis position. Pinned nodes are fixed where they are.
    init(topology: GraphTopology, positions: [CGPoint], pinned: Set<Int> = [], parameters: Parameters = Parameters()) {
        let n = topology.count
        count = n
        self.parameters = parameters
        alphaMin = parameters.alphaMin
        alphaDecay = parameters.alphaDecay
        velocityDecay = parameters.velocityDecay

        let cap = max(n, 1)
        xs = .allocate(capacity: cap); ys = .allocate(capacity: cap)
        vxs = .allocate(capacity: cap); vys = .allocate(capacity: cap)
        fxs = .allocate(capacity: cap); fys = .allocate(capacity: cap)
        isFixed = .allocate(capacity: cap)
        charges = .allocate(capacity: cap)
        collideRadius = .allocate(capacity: cap)
        cellOf = .allocate(capacity: cap)
        cellItems = .allocate(capacity: cap)

        var maxR = 1.0
        for i in 0..<n {
            var x = 0.0, y = 0.0
            if i < positions.count, positions[i].x.isFinite, positions[i].y.isFinite {
                x = Double(positions[i].x); y = Double(positions[i].y)
            } else {
                // d3's default placement.
                let r = 10 * (0.5 + Double(i)).squareRoot(), a = Double(i) * Double.pi * (3 - 5.0.squareRoot())
                x = r * cos(a); y = r * sin(a)
            }
            xs[i] = x; ys[i] = y; vxs[i] = 0; vys[i] = 0; fxs[i] = 0; fys[i] = 0; isFixed[i] = 0
            charges[i] = parameters.charge
            let r = (i < topology.radius.count ? topology.radius[i] : 3) + parameters.collisionPadding
            collideRadius[i] = r
            if r > maxR { maxR = r }
        }
        maxCollideRadius = maxR
        gridMaxDim = max(8, Int((Double(n).squareRoot() * 2).rounded()))
        cellCapacity = 64
        cellStart = .allocate(capacity: cellCapacity + 1)

        // One spring per connected pair, in first-seen edge order.
        struct Pair: Hashable { var a: Int, b: Int }
        var slot: [Pair: Int] = [:]
        var pairs: [Pair] = [], hasLink: [Bool] = []
        for e in topology.edges where e.a != e.b && e.a >= 0 && e.b >= 0 && e.a < n && e.b < n {
            let key = Pair(a: min(e.a, e.b), b: max(e.a, e.b))
            if let s = slot[key] {
                if e.kind != .trail { hasLink[s] = true }
            } else {
                slot[key] = pairs.count
                pairs.append(key)
                hasLink.append(e.kind != .trail)
            }
        }
        var degree = [Int](repeating: 0, count: n)
        for p in pairs { degree[p.a] += 1; degree[p.b] += 1 }
        linkCount = pairs.count
        let lc = max(pairs.count, 1)
        linkSource = .allocate(capacity: lc); linkTarget = .allocate(capacity: lc)
        linkLength = .allocate(capacity: lc); linkStrength = .allocate(capacity: lc); linkBias = .allocate(capacity: lc)
        for (k, p) in pairs.enumerated() {
            let da = Double(degree[p.a]), db = Double(degree[p.b])
            linkSource[k] = p.a
            linkTarget[k] = p.b
            let strength = parameters.linkStrength / min(da, db)
            if hasLink[k] {
                linkLength[k] = parameters.linkDistance
                linkStrength[k] = strength
            } else {
                linkLength[k] = parameters.linkDistance * parameters.trailDistanceScale
                linkStrength[k] = strength * parameters.trailStrengthScale
            }
            linkBias[k] = da / (da + db)
        }

        for i in pinned where i >= 0 && i < n {
            setFixed(i, at: CGPoint(x: xs[i], y: ys[i]))
        }
    }

    deinit {
        xs.deallocate(); ys.deallocate(); vxs.deallocate(); vys.deallocate()
        fxs.deallocate(); fys.deallocate(); isFixed.deallocate()
        charges.deallocate(); collideRadius.deallocate()
        cellOf.deallocate(); cellItems.deallocate(); cellStart.deallocate()
        linkSource.deallocate(); linkTarget.deallocate()
        linkLength.deallocate(); linkStrength.deallocate(); linkBias.deallocate()
    }

    // MARK: - State

    var positions: [CGPoint] {
        let n = count, xs = self.xs, ys = self.ys
        return [CGPoint](unsafeUninitializedCapacity: n) { buffer, initialized in
            guard let out = buffer.baseAddress else { initialized = 0; return }
            var i = 0
            while i < n {
                (out + i).initialize(to: CGPoint(x: xs[i], y: ys[i]))
                i += 1
            }
            initialized = n
        }
    }

    func position(of i: Int) -> CGPoint {
        guard i >= 0, i < count else { return .zero }
        return CGPoint(x: xs[i], y: ys[i])
    }

    /// Non-nil pins node `i` at `p` (moving it there and zeroing its velocity); nil releases it.
    func setFixed(_ i: Int, at p: CGPoint?) {
        guard i >= 0, i < count else { return }
        if let p, p.x.isFinite, p.y.isFinite {
            isFixed[i] = 1
            fxs[i] = Double(p.x); fys[i] = Double(p.y)
            xs[i] = Double(p.x); ys[i] = Double(p.y)
            vxs[i] = 0; vys[i] = 0
            fixed.insert(i)
        } else if p == nil {
            isFixed[i] = 0
            fixed.remove(i)
        }
    }

    // MARK: - Tick

    func tick() {
        alpha += (alphaTarget - alpha) * alphaDecay
        tickCount += 1
        guard count > 0 else { return }
        let a = alpha
        applyLinks(alpha: a)
        applyCharge(alpha: a)
        applyGravity(alpha: a)
        applyCollision()
        integrate()
    }

    private func applyLinks(alpha: Double) {
        let m = linkCount
        let xs = self.xs, ys = self.ys, vxs = self.vxs, vys = self.vys
        let src = linkSource, dst = linkTarget, len = linkLength, str = linkStrength, bias = linkBias
        var seed = rng
        var k = 0
        while k < m {
            let s = src[k], t = dst[k]
            var x = xs[t] + vxs[t] - xs[s] - vxs[s]
            var y = ys[t] + vys[t] - ys[s] - vys[s]
            if x == 0 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                x = (Double(seed &>> 11) * 0x1p-53 - 0.5) * 1e-6
            }
            if y == 0 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                y = (Double(seed &>> 11) * 0x1p-53 - 0.5) * 1e-6
            }
            var l = (x * x + y * y).squareRoot()
            l = (l - len[k]) / l * alpha * str[k]
            x *= l; y *= l
            let b = bias[k]
            vxs[t] -= x * b; vys[t] -= y * b
            let b1 = 1 - b
            vxs[s] += x * b1; vys[s] += y * b1
            k += 1
        }
        rng = seed
    }

    private func applyCharge(alpha: Double) {
        let n = count
        guard n > 1, parameters.charge != 0 else { return }
        let p = parameters
        var seed = rng
        tree.build(count: n, xs: xs, ys: ys, strengths: charges)
        tree.applyCharge(count: n, xs: xs, ys: ys, strengths: charges, alpha: alpha,
                         theta2: p.theta * p.theta,
                         distanceMin2: p.distanceMin * p.distanceMin,
                         distanceMax2: p.distanceMax * p.distanceMax,
                         vx: vxs, vy: vys, rng: &seed)
        rng = seed
    }

    private func applyGravity(alpha: Double) {
        let g = parameters.gravity * alpha
        guard g != 0 else { return }
        let n = count, xs = self.xs, ys = self.ys, vxs = self.vxs, vys = self.vys
        var i = 0
        while i < n {
            vxs[i] -= xs[i] * g
            vys[i] -= ys[i] * g
            i += 1
        }
    }

    /// d3 `forceCollide` (one iteration, predicted positions) with a uniform grid instead of a
    /// quadtree. Cells are at least one collision diameter wide, so overlaps are always found
    /// in the 3x3 neighborhood.
    private func applyCollision() {
        let n = count
        let strength = parameters.collisionStrength
        guard n > 1, strength > 0 else { return }
        let xs = self.xs, ys = self.ys, vxs = self.vxs, vys = self.vys, rad = collideRadius
        let cellOf = self.cellOf, items = self.cellItems

        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        var i = 0
        while i < n {
            let x = xs[i] + vxs[i], y = ys[i] + vys[i]
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
            i += 1
        }
        let spanX = maxX - minX, spanY = maxY - minY
        guard spanX < Double.infinity, spanY < Double.infinity else { return }
        let span = spanX > spanY ? spanX : spanY
        var cell = maxCollideRadius * 2
        let maxDim = Double(gridMaxDim - 1)
        if span / cell > maxDim { cell = span / maxDim }
        let inv = 1 / cell
        let gw = Int(spanX * inv) + 1, gh = Int(spanY * inv) + 1
        let cells = gw * gh
        if cells > cellCapacity {
            cellStart.deallocate()
            cellCapacity = cells * 2
            cellStart = .allocate(capacity: cellCapacity + 1)
        }
        let start = cellStart
        var c = 0
        while c <= cells { start[c] = 0; c += 1 }
        i = 0
        while i < n {
            var gx = Int((xs[i] + vxs[i] - minX) * inv)
            var gy = Int((ys[i] + vys[i] - minY) * inv)
            if gx >= gw { gx = gw - 1 }
            if gy >= gh { gy = gh - 1 }
            let cc = gy * gw + gx
            cellOf[i] = cc
            start[cc] += 1
            i += 1
        }
        // Inclusive prefix sums give each cell's end; filling backwards turns them into starts.
        c = 1
        while c < cells { start[c] += start[c - 1]; c += 1 }
        i = n - 1
        while i >= 0 {
            let cc = cellOf[i]
            start[cc] -= 1
            items[start[cc]] = i
            i -= 1
        }
        start[cells] = n

        var seed = rng
        i = 0
        while i < n {
            let ri = rad[i], ri2 = ri * ri
            let xi = xs[i] + vxs[i], yi = ys[i] + vys[i]
            let cc = cellOf[i]
            let gy = cc / gw, gx = cc - gy * gw
            let y0 = gy > 0 ? gy - 1 : 0, y1 = gy < gh - 1 ? gy + 1 : gh - 1
            let x0 = gx > 0 ? gx - 1 : 0, x1 = gx < gw - 1 ? gx + 1 : gw - 1
            var yy = y0
            while yy <= y1 {
                var xx = x0
                while xx <= x1 {
                    let slot = yy * gw + xx
                    var k = start[slot]
                    let end = start[slot + 1]
                    while k < end {
                        let j = items[k]
                        k += 1
                        if j <= i { continue }
                        let rj = rad[j]
                        let r = ri + rj
                        var x = xi - xs[j] - vxs[j]
                        var y = yi - ys[j] - vys[j]
                        var l = x * x + y * y
                        if l < r * r {
                            if x == 0 {
                                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                                x = (Double(seed &>> 11) * 0x1p-53 - 0.5) * 1e-6
                                l += x * x
                            }
                            if y == 0 {
                                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                                y = (Double(seed &>> 11) * 0x1p-53 - 0.5) * 1e-6
                                l += y * y
                            }
                            l = l.squareRoot()
                            l = (r - l) / l * strength
                            x *= l; y *= l
                            let rj2 = rj * rj
                            let w = rj2 / (ri2 + rj2)
                            vxs[i] += x * w; vys[i] += y * w
                            let w1 = 1 - w
                            vxs[j] -= x * w1; vys[j] -= y * w1
                        }
                    }
                    xx += 1
                }
                yy += 1
            }
            i += 1
        }
        rng = seed
    }

    private func integrate() {
        let n = count, keep = 1 - velocityDecay
        let xs = self.xs, ys = self.ys, vxs = self.vxs, vys = self.vys
        let fxs = self.fxs, fys = self.fys, isFixed = self.isFixed
        var i = 0
        while i < n {
            if isFixed[i] != 0 {
                xs[i] = fxs[i]; ys[i] = fys[i]
                vxs[i] = 0; vys[i] = 0
            } else {
                var vx = vxs[i] * keep, vy = vys[i] * keep
                // Never let a non-finite value in (x - x is NaN for inf and NaN).
                if !(vx - vx == 0) { vx = 0 }
                if !(vy - vy == 0) { vy = 0 }
                vxs[i] = vx; vys[i] = vy
                let x = xs[i] + vx, y = ys[i] + vy
                if x - x == 0 && y - y == 0 {
                    xs[i] = x; ys[i] = y
                } else {
                    vxs[i] = 0; vys[i] = 0
                }
            }
            i += 1
        }
    }
}
