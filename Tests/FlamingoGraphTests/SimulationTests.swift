import XCTest
import CoreGraphics
import FlamingoCore
@testable import FlamingoGraph

/// Deterministic generator for test fixtures (never system randomness).
struct TestLCG {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) * 0x1p-53
    }
    mutating func int(_ n: Int) -> Int { min(n - 1, Int(next() * Double(n))) }
}

/// `n` nodes in `clusters` groups; each edge stays inside its group with probability 0.85.
/// Every fifth edge is a trail edge.
func makeTopology(nodes n: Int, edges m: Int, clusters: Int = 3, orphans: Int = 0, seed: UInt64 = 1) -> GraphTopology {
    var rng = TestLCG(seed)
    let nodes = (0..<n).map { Graph.Node(id: "dir\($0 % max(clusters, 1))/n\($0).md", name: "n\($0).md", ext: "md") }
    let connected = max(n - orphans, 0)
    var edges: [Graph.Edge] = []
    var attempts = 0
    while edges.count < m && connected > 1 && attempts < m * 50 {
        attempts += 1
        let s = rng.int(connected)
        var t = rng.int(connected)
        if rng.next() < 0.85, clusters > 1 { t = (t / clusters) * clusters + s % clusters }
        guard t < connected, s != t else { continue }
        edges.append(.init(source: nodes[s].id, target: nodes[t].id, kind: edges.count % 5 == 4 ? .trail : .link))
    }
    return GraphTopology(Graph(nodes: nodes, edges: edges))
}

func allFinite(_ points: [CGPoint]) -> Bool { points.allSatisfy { $0.x.isFinite && $0.y.isFinite } }

final class QuadtreeTests: XCTestCase {
    private func bruteForce(xs: [Double], ys: [Double], strengths: [Double], distanceMin: Double = 1) -> ([Double], [Double]) {
        let n = xs.count
        var fx = [Double](repeating: 0, count: n), fy = [Double](repeating: 0, count: n)
        for i in 0..<n {
            for j in 0..<n where j != i {
                let dx = xs[j] - xs[i], dy = ys[j] - ys[i]
                var l = dx * dx + dy * dy
                if l < distanceMin * distanceMin { l = (distanceMin * distanceMin * l).squareRoot() }
                fx[i] += dx * strengths[j] / l
                fy[i] += dy * strengths[j] / l
            }
        }
        return (fx, fy)
    }

    private func points(_ n: Int, seed: UInt64) -> ([Double], [Double], [Double]) {
        var rng = TestLCG(seed)
        var xs: [Double] = [], ys: [Double] = [], s: [Double] = []
        for k in 0..<n {
            // Clumpy: a few dense blobs plus uniform background, like a real layout.
            if k % 3 == 0 {
                xs.append(rng.next() * 1000 - 500); ys.append(rng.next() * 1000 - 500)
            } else {
                let c = Double(k % 5) * 180 - 360, r = 60 * rng.next().squareRoot(), a = rng.next() * 2 * .pi
                xs.append(c + r * cos(a)); ys.append(c * 0.5 + r * sin(a))
            }
            s.append(k % 7 == 0 ? -60 : -30)
        }
        return (xs, ys, s)
    }

    func testThetaZeroIsExact() {
        let (xs, ys, s) = points(400, seed: 11)
        let exact = bruteForce(xs: xs, ys: ys, strengths: s)
        let bh = Quadtree.chargeForces(xs: xs, ys: ys, strengths: s, theta: 0)
        for i in 0..<xs.count {
            let scale = max(1e-12, hypot(exact.0[i], exact.1[i]))
            XCTAssertEqual(bh.x[i], exact.0[i], accuracy: scale * 1e-9)
            XCTAssertEqual(bh.y[i], exact.1[i], accuracy: scale * 1e-9)
        }
    }

    func testBarnesHutMatchesBruteForce() {
        let (xs, ys, s) = points(1000, seed: 5)
        let exact = bruteForce(xs: xs, ys: ys, strengths: s)
        let bh = Quadtree.chargeForces(xs: xs, ys: ys, strengths: s, theta: 0.9)
        var errorSum = 0.0, magnitudeSum = 0.0
        var relative: [Double] = []
        for i in 0..<xs.count {
            let e = hypot(bh.x[i] - exact.0[i], bh.y[i] - exact.1[i]), m = hypot(exact.0[i], exact.1[i])
            errorSum += e; magnitudeSum += m
            relative.append(e / m)
        }
        relative.sort()
        // Aggregate error a few percent; the median node much better than that.
        XCTAssertLessThan(errorSum / magnitudeSum, 0.04)
        XCTAssertLessThan(relative[relative.count / 2], 0.03)
    }

    func testCoincidentPointsSeparateDeterministically() {
        let xs = [Double](repeating: 5, count: 50), ys = [Double](repeating: -3, count: 50)
        let s = [Double](repeating: -30, count: 50)
        let a = Quadtree.chargeForces(xs: xs, ys: ys, strengths: s, theta: 0.9)
        let b = Quadtree.chargeForces(xs: xs, ys: ys, strengths: s, theta: 0.9)
        XCTAssertEqual(a.x, b.x)
        XCTAssertEqual(a.y, b.y)
        XCTAssertTrue(a.x.allSatisfy(\.isFinite) && a.y.allSatisfy(\.isFinite))
        XCTAssertTrue(a.x.contains { $0 != 0 })
    }

    func testEmptyAndSingle() {
        XCTAssertEqual(Quadtree.chargeForces(xs: [], ys: [], strengths: [], theta: 0.9).x, [])
        XCTAssertEqual(Quadtree.chargeForces(xs: [1], ys: [2], strengths: [-30], theta: 0.9).x, [0])
    }
}

final class ForceSimulationTests: XCTestCase {
    func testDeterministic() {
        let t = makeTopology(nodes: 200, edges: 400, clusters: 4, orphans: 10)
        let start = LayoutStore.initial(for: t, saved: nil).positions
        let a = ForceSimulation(topology: t, positions: start, pinned: [3])
        let b = ForceSimulation(topology: t, positions: start, pinned: [3])
        for _ in 0..<100 { a.tick(); b.tick() }
        XCTAssertEqual(a.positions, b.positions)
        XCTAssertEqual(a.alpha, b.alpha)

        // Also through the jiggle path: everything coincident.
        let same = [CGPoint](repeating: CGPoint(x: 1, y: 1), count: t.count)
        let c = ForceSimulation(topology: t, positions: same), d = ForceSimulation(topology: t, positions: same)
        for _ in 0..<100 { c.tick(); d.tick() }
        XCTAssertEqual(c.positions, d.positions)
    }

    func testSettlesWithinBudgetAndClusters() {
        let t = makeTopology(nodes: 60, edges: 90, clusters: 3, orphans: 4)
        let sim = ForceSimulation(topology: t, positions: LayoutStore.initial(for: t, saved: nil).positions)
        while !sim.isSettled && sim.tickCount < 1000 {
            sim.tick()
            XCTAssertTrue(allFinite(sim.positions))
        }
        XCTAssertTrue(sim.isSettled)
        XCTAssertLessThanOrEqual(sim.tickCount, 300)
        XCTAssertGreaterThanOrEqual(sim.tickCount, 200)

        let p = sim.positions
        func dist(_ i: Int, _ j: Int) -> Double { Double(hypot(p[i].x - p[j].x, p[i].y - p[j].y)) }
        var linked = 0.0, linkedCount = 0.0, other = 0.0, otherCount = 0.0
        for i in 0..<t.count {
            for j in (i + 1)..<t.count {
                if t.neighbors[i].contains(j) { linked += dist(i, j); linkedCount += 1 } else { other += dist(i, j); otherCount += 1 }
            }
        }
        XCTAssertLessThan(linked / linkedCount, 0.6 * (other / otherCount))
        // Collision: no two nodes overlap.
        for i in 0..<t.count { for j in (i + 1)..<t.count { XCTAssertGreaterThan(dist(i, j), t.radius[i] + t.radius[j]) } }
    }

    func testDegenerateInputsStayFinite() {
        // 0 nodes.
        let empty = ForceSimulation(topology: GraphTopology(Graph()), positions: [])
        for _ in 0..<10 { empty.tick() }
        XCTAssertEqual(empty.positions, [])

        // 1 node, off center: gravity pulls it in, nothing explodes.
        let one = GraphTopology(Graph(nodes: [.init(id: "a", name: "a", ext: "")]))
        let s1 = ForceSimulation(topology: one, positions: [CGPoint(x: 50, y: -20)])
        for _ in 0..<300 { s1.tick() }
        XCTAssertTrue(allFinite(s1.positions))
        XCTAssertLessThan(hypot(s1.positions[0].x, s1.positions[0].y), 50)

        // 2 linked nodes at the same point.
        let two = GraphTopology(Graph(nodes: [.init(id: "a", name: "a", ext: ""), .init(id: "b", name: "b", ext: "")],
                                      edges: [.init(source: "a", target: "b", kind: .link)]))
        let s2 = ForceSimulation(topology: two, positions: [.zero, .zero])
        for _ in 0..<300 { s2.tick(); XCTAssertTrue(allFinite(s2.positions)) }
        let d = hypot(s2.positions[0].x - s2.positions[1].x, s2.positions[0].y - s2.positions[1].y)
        XCTAssertGreaterThan(d, 10)

        // Many nodes, all at one point, with and without links.
        for edges in [0, 300] {
            let t = makeTopology(nodes: 150, edges: edges)
            let s = ForceSimulation(topology: t, positions: [CGPoint](repeating: CGPoint(x: 7, y: 7), count: t.count))
            while !s.isSettled { s.tick(); XCTAssertTrue(allFinite(s.positions)) }
            let p = s.positions
            XCTAssertGreaterThan(Set(p.map { "\($0.x),\($0.y)" }).count, 140)
        }

        // Missing and non-finite starting positions are replaced.
        let t = makeTopology(nodes: 5, edges: 4)
        let s = ForceSimulation(topology: t, positions: [CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: CGFloat.infinity, y: 1)])
        XCTAssertTrue(allFinite(s.positions))
        for _ in 0..<50 { s.tick() }
        XCTAssertTrue(allFinite(s.positions))
    }

    func testPinnedNodesNeverMove() {
        let t = makeTopology(nodes: 40, edges: 60)
        let start = LayoutStore.initial(for: t, saved: nil).positions
        var positions = start
        positions[0] = CGPoint(x: 100, y: 50)
        let sim = ForceSimulation(topology: t, positions: positions, pinned: [0, 5])
        XCTAssertEqual(sim.fixed, [0, 5])
        for k in 0..<300 {
            sim.tick()
            XCTAssertEqual(sim.positions[0], CGPoint(x: 100, y: 50))
            XCTAssertEqual(sim.positions[5], start[5])
            if k == 100 { sim.setFixed(7, at: CGPoint(x: -40, y: 12)) }
            if k > 100 { XCTAssertEqual(sim.positions[7], CGPoint(x: -40, y: 12)) }
        }
        sim.setFixed(7, at: nil)
        XCTAssertEqual(sim.fixed, [0, 5])
        sim.alpha = 0.3
        for _ in 0..<50 { sim.tick() }
        XCTAssertNotEqual(sim.positions[7], CGPoint(x: -40, y: 12))
        XCTAssertEqual(sim.positions[0], CGPoint(x: 100, y: 50))
    }

    func testAlphaTargetKeepsItWarm() {
        let t = makeTopology(nodes: 20, edges: 30)
        let sim = ForceSimulation(topology: t, positions: LayoutStore.initial(for: t, saved: nil).positions)
        sim.alphaTarget = 0.3
        for _ in 0..<600 { sim.tick() }
        XCTAssertFalse(sim.isSettled)
        XCTAssertEqual(sim.alpha, 0.3, accuracy: 0.01)
        sim.alphaTarget = 0
        var ticks = 0
        while !sim.isSettled { sim.tick(); ticks += 1 }
        XCTAssertLessThan(ticks, 300)
    }
}

final class LayoutEngineTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }

    func testStartSettlesAndCallsOnSettle() {
        let t = makeTopology(nodes: 50, edges: 80)
        let initial = LayoutStore.initial(for: t, saved: nil)
        let engine = LayoutEngine(topology: t, positions: initial.positions, pinned: [], alpha: initial.alpha, maxTicksPerSecond: 0)
        XCTAssertFalse(engine.snapshot().isRunning)
        let settled = expectation(description: "settled")
        engine.onSettle = { positions, pinned in
            XCTAssertEqual(positions.count, 50)
            XCTAssertTrue(pinned.isEmpty)
            settled.fulfill()
        }
        engine.start()
        engine.start()   // idempotent
        XCTAssertTrue(engine.snapshot().isRunning)
        wait(for: [settled], timeout: 10)
        let snap = engine.snapshot()
        XCTAssertFalse(snap.isRunning)
        XCTAssertLessThan(snap.alpha, 0.001)
        XCTAssertGreaterThan(snap.generation, 200)
        XCTAssertTrue(allFinite(snap.positions))

        // Settled: start does nothing.
        engine.start()
        XCTAssertFalse(engine.snapshot().isRunning)
        XCTAssertEqual(engine.snapshot().generation, snap.generation)

        // Reheat runs it again and settles again.
        let again = expectation(description: "settled again")
        engine.onSettle = { _, _ in again.fulfill() }
        engine.reheat(0.2)
        XCTAssertTrue(engine.snapshot().isRunning)
        wait(for: [again], timeout: 10)
        XCTAssertFalse(engine.snapshot().isRunning)
    }

    func testAlphaZeroNeverRuns() {
        let t = makeTopology(nodes: 10, edges: 10)
        let p = LayoutStore.initial(for: t, saved: nil).positions
        let engine = LayoutEngine(topology: t, positions: p, pinned: [2], alpha: 0)
        engine.start()
        let snap = engine.snapshot()
        XCTAssertFalse(snap.isRunning)
        XCTAssertEqual(snap.positions, p)
        XCTAssertEqual(engine.pinned, [2])
    }

    func testDragIsImmediateAndPins() {
        let t = makeTopology(nodes: 30, edges: 45)
        let initial = LayoutStore.initial(for: t, saved: nil)
        let engine = LayoutEngine(topology: t, positions: initial.positions, pinned: [], alpha: 1)
        engine.start()
        Thread.sleep(forTimeInterval: 0.05)

        engine.beginDrag(4)
        XCTAssertTrue(engine.pinned.contains(4))
        let target = CGPoint(x: 321, y: -123)
        let before = engine.snapshot().generation
        engine.drag(4, to: target)
        let snap = engine.snapshot()
        XCTAssertEqual(snap.positions[4], target)
        XCTAssertGreaterThan(snap.generation, before)

        // It stays there while the worker keeps ticking.
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.01)
            XCTAssertEqual(engine.snapshot().positions[4], target)
        }
        let next = CGPoint(x: 330, y: -100)
        engine.drag(4, to: next)
        XCTAssertEqual(engine.snapshot().positions[4], next)

        let settled = expectation(description: "settled")
        engine.onSettle = { positions, pinned in
            XCTAssertEqual(positions[4], next)
            XCTAssertEqual(pinned, [4])
            settled.fulfill()
        }
        engine.endDrag(4)
        XCTAssertTrue(engine.pinned.contains(4))
        wait(for: [settled], timeout: 10)
        XCTAssertEqual(engine.snapshot().positions[4], next)
        XCTAssertFalse(engine.snapshot().isRunning)

        // Unpin releases and restarts.
        engine.onSettle = nil
        engine.unpin(4)
        XCTAssertFalse(engine.pinned.contains(4))
        XCTAssertTrue(engine.snapshot().isRunning)
        XCTAssertTrue(waitUntil { engine.snapshot().positions[4] != next })
        engine.stop()
    }

    func testDragAfterSettleRestartsWorker() {
        let t = makeTopology(nodes: 12, edges: 14)
        let engine = LayoutEngine(topology: t, positions: LayoutStore.initial(for: t, saved: nil).positions, pinned: [], alpha: 0)
        XCTAssertFalse(engine.snapshot().isRunning)
        engine.beginDrag(1)
        XCTAssertTrue(engine.snapshot().isRunning)
        engine.drag(1, to: CGPoint(x: 5, y: 5))
        XCTAssertEqual(engine.snapshot().positions[1], CGPoint(x: 5, y: 5))
        XCTAssertTrue(waitUntil { engine.snapshot().alpha > 0.01 })
        engine.endDrag(1)
        engine.stop()
        XCTAssertFalse(engine.snapshot().isRunning)
    }

    func testStopIsPromptAndEngineDeallocates() {
        let baseline = LayoutEngine.liveWorkerCount
        weak var weakEngine: LayoutEngine?
        do {
            let t = makeTopology(nodes: 400, edges: 800)
            let engine = LayoutEngine(topology: t, positions: LayoutStore.initial(for: t, saved: nil).positions,
                                      pinned: [], alpha: 1, maxTicksPerSecond: 0)
            weakEngine = engine
            engine.onSettle = { _, _ in XCTFail("stopped engines do not settle") }
            engine.start()
            XCTAssertTrue(waitUntil { engine.snapshot().generation > 3 })
            let t0 = Date()
            engine.stop()
            XCTAssertLessThan(Date().timeIntervalSince(t0), 0.05)
            engine.stop()
            XCTAssertFalse(engine.snapshot().isRunning)
            let g = engine.snapshot().generation
            Thread.sleep(forTimeInterval: 0.05)
            XCTAssertEqual(engine.snapshot().generation, g, "no publishes after stop")
        }
        XCTAssertNil(weakEngine)
        XCTAssertTrue(waitUntil { LayoutEngine.liveWorkerCount == baseline })

        // Dropping a running engine without stop() also ends its worker.
        do {
            let t = makeTopology(nodes: 50, edges: 60)
            let engine = LayoutEngine(topology: t, positions: LayoutStore.initial(for: t, saved: nil).positions, pinned: [], alpha: 1)
            weakEngine = engine
            engine.start()
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertNil(weakEngine)
        XCTAssertTrue(waitUntil { LayoutEngine.liveWorkerCount == baseline })
    }

    func testStopThenStartResumes() {
        let t = makeTopology(nodes: 40, edges: 60)
        let engine = LayoutEngine(topology: t, positions: LayoutStore.initial(for: t, saved: nil).positions,
                                  pinned: [], alpha: 1, maxTicksPerSecond: 0)
        let settled = expectation(description: "settled")
        engine.onSettle = { _, _ in settled.fulfill() }
        for _ in 0..<5 {
            engine.start()
            Thread.sleep(forTimeInterval: 0.002)
            engine.stop()
        }
        engine.start()
        wait(for: [settled], timeout: 10)
        XCTAssertFalse(engine.snapshot().isRunning)
    }
}
