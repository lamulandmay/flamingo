import XCTest
import SwiftUI
import FlamingoCore
@testable import FlamingoGraph

final class RendererTests: XCTestCase {

    // MARK: - Fixtures

    private func topology(_ n: Int, edges: [(Int, Int, Graph.Edge.Kind)] = [], names: [String]? = nil,
                          comments: Int = 0) -> GraphTopology {
        let nodes = (0..<n).map { i -> Graph.Node in
            let name = names?[i] ?? "File \(i).pptx"
            return Graph.Node(id: "n\(i)/\(name)", name: name, ext: (name as NSString).pathExtension, commentCount: comments)
        }
        let es = edges.map { Graph.Edge(source: nodes[$0.0].id, target: nodes[$0.1].id, kind: $0.2) }
        return GraphTopology(Graph(nodes: nodes, edges: es))
    }

    private func frame(_ t: GraphTopology, _ positions: [CGPoint], camera: GraphCamera = GraphCamera(),
                       labels: Double = 0) -> GraphFrame {
        GraphFrame(topology: t, positions: positions, camera: camera, selected: nil, hovered: nil,
                   hoverAmount: 0, filterMask: nil, labelAmount: labels, pinned: [], dragging: nil)
    }

    /// Runs `draw` inside a real Canvas through ImageRenderer.
    @MainActor
    @discardableResult
    private func render(_ f: GraphFrame, size: CGSize = CGSize(width: 400, height: 300),
                        renderer: GraphRenderer = GraphRenderer()) -> GraphRenderer.Stats {
        let canvas = Canvas { ctx, sz in renderer.draw(f, in: &ctx, size: sz) }
            .frame(width: size.width, height: size.height)
        let r = ImageRenderer(content: canvas.environment(\.colorScheme, .dark))
        let image = r.cgImage
        if size.width >= 1, size.height >= 1 { XCTAssertNotNil(image) }
        return renderer.stats
    }

    private func grid(_ n: Int, spacing: CGFloat) -> [CGPoint] {
        let cols = max(1, Int(Double(n).squareRoot().rounded(.up)))
        return (0..<n).map { CGPoint(x: CGFloat($0 % cols) * spacing, y: CGFloat($0 / cols) * spacing) }
    }

    private struct LCG {
        var s: UInt64
        mutating func next() -> CGFloat {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(s >> 11) / CGFloat(1 << 53)
        }
    }

    // MARK: - Label layout (pure)

    func testLabelRectSitsBelowItsNode() {
        for r in [CGFloat(1.5), 4, 20] {
            let c = LabelLayout.Candidate(node: 0, center: CGPoint(x: 100, y: 50), radius: r, size: CGSize(width: 60, height: 13))
            let rect = LabelLayout.rect(for: c, gap: GraphRenderer.Style.labelGap)
            XCTAssertGreaterThan(rect.minY, c.center.y + r, "label must start below the node's circle")
            XCTAssertEqual(rect.midX, c.center.x, accuracy: 1e-9)
            // Not even the node's bounding box touches the label.
            let box = CGRect(x: c.center.x - r, y: c.center.y - r, width: 2 * r, height: 2 * r)
            XCTAssertFalse(rect.intersects(box))
        }
    }

    func testGreedyPlacementNeverOverlaps() {
        var rng = LCG(s: 42)
        var candidates: [LabelLayout.Candidate] = []
        for i in 0..<600 {
            candidates.append(.init(node: i, center: CGPoint(x: rng.next() * 800, y: rng.next() * 600),
                                    radius: 2 + rng.next() * 6, size: CGSize(width: 30 + rng.next() * 120, height: 13)))
        }
        let padding: CGFloat = 2
        let placed = LabelLayout.place(candidates, gap: 2, padding: padding)
        XCTAssertGreaterThan(placed.count, 20)
        XCTAssertLessThan(placed.count, candidates.count)
        for i in 0..<placed.count {
            for j in (i + 1)..<placed.count {
                let a = placed[i].rect.insetBy(dx: -padding + 1e-6, dy: -padding + 1e-6)
                XCTAssertFalse(a.intersects(placed[j].rect), "labels \(placed[i].node) and \(placed[j].node) overlap")
            }
        }
        // Greedy in order: the first candidate always wins.
        XCTAssertEqual(placed.first?.node, 0)
    }

    func testPlacementMatchesBruteForce() {
        var rng = LCG(s: 7)
        let candidates = (0..<300).map { i in
            LabelLayout.Candidate(node: i, center: CGPoint(x: rng.next() * 500 - 50, y: rng.next() * 400 - 50),
                                  radius: 3, size: CGSize(width: 20 + rng.next() * 140, height: 13))
        }
        let fast = LabelLayout.place(candidates, gap: 2, padding: 2).map(\.node)
        var kept: [CGRect] = []
        var slow: [Int] = []
        for c in candidates {
            for r in LabelLayout.rects(center: c.center, radius: c.radius, size: c.size, gap: 2) {
                let probe = r.insetBy(dx: -2, dy: -2)
                if kept.contains(where: { LabelPlacer.overlaps(probe, $0) }) { continue }
                kept.append(r)
                slow.append(c.node)
                break
            }
        }
        XCTAssertEqual(fast, slow, "spatial hash must agree with the O(n^2) definition")
    }

    func testObstaclesBlockZoomLabelsButNotPriorityOrOwnNode() {
        // Node 1 sits right where node 0's label would go.
        let c0 = LabelLayout.Candidate(node: 0, center: CGPoint(x: 100, y: 100), radius: 4, size: CGSize(width: 80, height: 13))
        let c1 = LabelLayout.Candidate(node: 1, center: CGPoint(x: 100, y: 113), radius: 4, size: CGSize(width: 10, height: 13))
        let obstacles = [c0, c1].map { LabelLayout.Obstacle(node: $0.node, center: $0.center, radius: $0.radius) }

        let asZoom = LabelLayout.place([c0], gap: 2, padding: 2, priorityCount: 0, obstacles: obstacles)
        XCTAssertEqual(asZoom.count, 1)
        let moved = try! XCTUnwrap(asZoom.first?.rect)
        XCTAssertFalse(moved.intersects(LabelLayout.obstacleRect(center: c1.center, radius: c1.radius)),
                       "a zoom label must not cover another node")
        XCTAssertLessThanOrEqual(moved.maxY, c0.center.y - c0.radius, "blocked below, it goes above")

        // Boxed in on every side, it gives up.
        let walls = [CGPoint(x: 100, y: 87), CGPoint(x: 150, y: 100), CGPoint(x: 50, y: 100)].enumerated().map {
            LabelLayout.Obstacle(node: 2 + $0.offset, center: $0.element, radius: 4)
        }
        XCTAssertTrue(LabelLayout.place([c0], gap: 2, padding: 2, priorityCount: 0, obstacles: obstacles + walls).isEmpty)

        let asPriority = LabelLayout.place([c0], gap: 2, padding: 2, priorityCount: 1, obstacles: obstacles)
        XCTAssertEqual(asPriority.map(\.node), [0], "selected/hovered labels always show")

        // A lone node's own circle never blocks its label.
        let alone = LabelLayout.place([c0], gap: 2, padding: 2, priorityCount: 0, obstacles: [obstacles[0]])
        XCTAssertEqual(alone.map(\.node), [0])
    }

    func testPlacerRejectsDegenerateRects() {
        var p = LabelPlacer()
        XCTAssertFalse(p.tryPlace(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), padding: 2))
        XCTAssertFalse(p.tryPlace(CGRect(x: 0, y: 0, width: 0, height: 10), padding: 2))
        XCTAssertFalse(p.tryPlace(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10), padding: 2))
        // Oversized rects still collide correctly.
        XCTAssertTrue(p.tryPlace(CGRect(x: 0, y: 0, width: 100_000, height: 2_000), padding: 2))
        XCTAssertFalse(p.tryPlace(CGRect(x: 50_000, y: 1_000, width: 10, height: 10), padding: 2))
        XCTAssertTrue(p.tryPlace(CGRect(x: 50_000, y: 3_000, width: 10, height: 10), padding: 2))
        p.reset()
        XCTAssertEqual(p.count, 0)
        XCTAssertTrue(p.tryPlace(CGRect(x: 50_000, y: 1_000, width: 10, height: 10), padding: 2))
    }

    func testTruncation() {
        XCTAssertEqual(LabelLayout.truncated("Launch Plan", limit: 28), "Launch Plan")
        let long = "Quarterly Business Review \u{2014} Final Final v3"
        let t = LabelLayout.truncated(long, limit: 28)
        XCTAssertLessThanOrEqual(t.count, 28)
        XCTAssertTrue(t.contains("\u{2026}"))
        XCTAssertTrue(t.hasPrefix("Quarterly"))
        XCTAssertTrue(t.hasSuffix("v3"))
        XCTAssertEqual(LabelLayout.truncated("a\nb", limit: 28), "a b")
        XCTAssertEqual(LabelLayout.truncated("", limit: 28), "")
        // Multi-byte names under the limit are untouched.
        XCTAssertEqual(LabelLayout.truncated("日本語のファイル名", limit: 28), "日本語のファイル名")
    }

    // MARK: - Geometry

    func testScreenRadius() {
        XCTAssertEqual(GraphRenderer.screenRadius(worldRadius: 3, zoom: 0.04), GraphRenderer.Style.minScreenRadius)
        XCTAssertEqual(GraphRenderer.screenRadius(worldRadius: 4, zoom: 1), 4, accuracy: 1e-9)
        let r2 = GraphRenderer.screenRadius(worldRadius: 4, zoom: 2)
        let r10 = GraphRenderer.screenRadius(worldRadius: 4, zoom: 10)
        XCTAssertGreaterThan(r2, 4)
        XCTAssertLessThan(r2, 8, "growth is damped above 1x")
        XCTAssertGreaterThan(r10, r2)
        XCTAssertLessThan(r10, 40)
        XCTAssertTrue(GraphRenderer.screenRadius(worldRadius: .nan, zoom: 1).isFinite)
        XCTAssertTrue(GraphRenderer.screenRadius(worldRadius: 3, zoom: .nan).isFinite)
        XCTAssertEqual(GraphRenderer.edgeFade(zoom: 2), 1)
        XCTAssertEqual(GraphRenderer.edgeFade(zoom: 0.04), GraphRenderer.Style.edgeFadeFloor, accuracy: 1e-9)
    }

    func testCullingExcludesOffscreenNodes() {
        let t = topology(5)
        let size = CGSize(width: 400, height: 300)
        // Camera centered on the origin at 1x: screen = world + (200, 150).
        let positions = [CGPoint(x: 0, y: 0),        // center
                         CGPoint(x: 1_000, y: 0),    // far right
                         CGPoint(x: 0, y: -1_000),   // far above
                         CGPoint(x: 203, y: 0),      // just past the right edge, within radius + margin
                         CGPoint(x: CGFloat.nan, y: 0)]
        let visible = GraphRenderer().visibleNodes(frame(t, positions), size: size)
        XCTAssertEqual(visible, [0, 3])
    }

    @MainActor
    func testOffscreenEdgesAreCulled() {
        let t = topology(4, edges: [(0, 1, .link), (2, 3, .link)])
        let positions = [CGPoint(x: -50, y: 0), CGPoint(x: 50, y: 0),
                         CGPoint(x: 5_000, y: 5_000), CGPoint(x: 5_100, y: 5_000)]
        let stats = render(frame(t, positions))
        XCTAssertEqual(stats.visibleNodes, 2)
        XCTAssertEqual(stats.drawnEdges, 1)
    }

    @MainActor
    func testEdgeCrossingViewportIsKept() {
        let t = topology(2, edges: [(0, 1, .link)])
        let stats = render(frame(t, [CGPoint(x: -5_000, y: 0), CGPoint(x: 5_000, y: 0)]))
        XCTAssertEqual(stats.visibleNodes, 0)
        XCTAssertEqual(stats.drawnEdges, 1, "an edge spanning the view is drawn even if both ends are off-screen")
    }

    @MainActor
    func testTrailShadowedByLinkIsDrawnOnce() {
        let t = topology(3, edges: [(0, 1, .link), (0, 1, .trail), (1, 2, .trail)])
        let stats = render(frame(t, [CGPoint(x: -60, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 60, y: 0)]))
        XCTAssertEqual(stats.drawnEdges, 2)
    }

    // MARK: - Labels in a real draw

    @MainActor
    func testDrawnLabelsNeverOverlapNodesOrEachOther() {
        let n = 400
        let names = (0..<n).map { "Quarterly Review Draft \($0).key" }
        let edges = (1..<n).map { ($0, $0 / 3, Graph.Edge.Kind.link) }
        let t = topology(n, edges: edges, names: names, comments: 2)
        let positions = grid(n, spacing: 22)
        var f = frame(t, positions, camera: GraphCamera(center: CGPoint(x: 200, y: 200), zoom: 2), labels: 1)
        // Grid is 20 wide: 189 is at world (198, 198), 210 at (220, 220); both on screen.
        f.selected = 189
        f.hovered = 210
        f.hoverAmount = 1
        let size = CGSize(width: 800, height: 600)
        let renderer = GraphRenderer()
        let stats = render(f, size: size, renderer: renderer)
        XCTAssertGreaterThan(stats.labels, 5)
        XCTAssertEqual(renderer.placedNode.count, stats.labels)

        let zoom = f.camera.zoom
        func circle(_ i: Int) -> (CGPoint, CGFloat) {
            let c = f.camera.toScreen(positions[i], size: size)
            return (c, GraphRenderer.screenRadius(worldRadius: t.radius[i], zoom: zoom))
        }
        let priority = Set([189, 210] + t.neighbors[210])
        for (k, i) in renderer.placedNode.enumerated() {
            let rect = renderer.placedRect[k]
            let (c, r) = circle(i)
            XCTAssertGreaterThan(rect.minY, c.y + r, "label \(i) overlaps its own node")
            for (k2, j) in renderer.placedNode.enumerated() where k2 > k {
                XCTAssertFalse(rect.intersects(renderer.placedRect[k2]), "labels \(i) and \(j) overlap")
            }
            guard !priority.contains(i) else { continue }
            for j in 0..<n where j != i {
                let (cj, rj) = circle(j)
                XCTAssertFalse(rect.intersects(LabelLayout.obstacleRect(center: cj, radius: rj)),
                               "zoom label \(i) covers node \(j)")
            }
        }
        // The selected and hovered labels win.
        XCTAssertEqual(Array(renderer.placedNode.prefix(2)), [189, 210])
    }

    @MainActor
    func testLabelsOnlyWhenAsked() {
        let t = topology(3, edges: [(0, 1, .link), (1, 2, .link)])
        let positions = [CGPoint(x: -80, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 80, y: 0)]
        XCTAssertEqual(render(frame(t, positions)).labels, 0)
        var f = frame(t, positions)
        f.selected = 2
        XCTAssertEqual(render(f).labels, 1)
        f = frame(t, positions)
        f.hovered = 1
        f.hoverAmount = 1
        XCTAssertEqual(render(f).labels, 3, "hovered node and both neighbors")
        f.hoverAmount = 0
        XCTAssertEqual(render(f).labels, 0, "hover faded out")
        XCTAssertEqual(render(frame(t, positions, labels: 1)).labels, 3)
    }

    // MARK: - Robustness

    @MainActor
    func testDrawSurvivesDegenerateFrames() {
        let size = CGSize(width: 300, height: 200)
        // 0 nodes.
        let empty = GraphTopology(Graph())
        XCTAssertEqual(render(frame(empty, []), size: size).visibleNodes, 0)
        // 1 node.
        let one = topology(1)
        XCTAssertEqual(render(frame(one, [.zero], labels: 1), size: size).visibleNodes, 1)
        // Identical positions with edges between them.
        let same = topology(20, edges: (1..<20).map { (0, $0, .link) })
        var f = frame(same, Array(repeating: CGPoint(x: 3, y: 3), count: 20), labels: 1)
        f.selected = 0
        f.hovered = 1
        f.hoverAmount = 0.5
        let s = render(f, size: size)
        XCTAssertEqual(s.visibleNodes, 20)
        XCTAssertEqual(s.drawnEdges, 0, "zero-length edges are skipped")
        // Extreme zooms.
        let big = topology(200, edges: (1..<200).map { ($0, $0 / 2, .link) })
        for z in [GraphCamera.zoomRange.lowerBound, GraphCamera.zoomRange.upperBound] {
            let st = render(frame(big, grid(200, spacing: 40), camera: GraphCamera(center: CGPoint(x: 200, y: 200), zoom: z), labels: 1), size: size)
            XCTAssertGreaterThan(st.visibleNodes, 0)
        }
        // Empty labels.
        let blank = topology(3, edges: [(0, 1, .link)], names: ["", ".pptx", "x.md"])
        var b = frame(blank, [CGPoint(x: -40, y: 0), .zero, CGPoint(x: 40, y: 0)], labels: 1)
        b.selected = 0
        render(b, size: size)
        // Out-of-range indices, short masks, positions shorter than the topology, NaN everywhere.
        let t = topology(5, edges: [(0, 1, .link), (3, 4, .trail)])
        var bad = frame(t, [.zero, CGPoint(x: CGFloat.nan, y: 1), CGPoint(x: 10, y: CGFloat.infinity)], labels: .nan)
        bad.selected = 99
        bad.hovered = -1
        bad.hoverAmount = .nan
        bad.dragging = 7
        bad.filterMask = [false]
        bad.pinned = [0, 1, 42, -3]
        bad.camera.zoom = .nan
        render(bad, size: size)
        // Zero-size canvas.
        render(frame(t, grid(5, spacing: 10)), size: CGSize(width: 0, height: 0))
    }

    @MainActor
    func testCachesFollowTopology() {
        let renderer = GraphRenderer()
        let a = topology(3, edges: [(0, 1, .link)])
        render(frame(a, grid(3, spacing: 50), labels: 1), renderer: renderer)
        // A different (bigger) topology through the same renderer must not index stale caches.
        let b = topology(50, edges: (1..<50).map { ($0, 0, .trail) })
        var f = frame(b, grid(50, spacing: 30), labels: 1)
        f.selected = 49
        f.pinned = [48]
        let s = render(f, renderer: renderer)
        XCTAssertGreaterThan(s.visibleNodes, 3)
        // And back to a smaller one.
        let c = topology(2)
        XCTAssertEqual(render(frame(c, [.zero, CGPoint(x: 30, y: 0)], labels: 1), renderer: renderer).labels, 2)
    }
}
