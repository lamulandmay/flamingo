import XCTest
import FlamingoCore
@testable import FlamingoGraph

private func node(_ id: String, comments: Int = 0) -> Graph.Node {
    Graph.Node(id: id, name: (id as NSString).lastPathComponent,
               ext: (id as NSString).pathExtension, commentCount: comments)
}

/// a — b — c, a — d (trail), e alone.
private let small = Graph(
    nodes: [node("decks/a.pptx"), node("sheets/b.xlsx"), node("docs/c.docx"), node("notes/d.md"), node("e.png")],
    edges: [.init(source: "decks/a.pptx", target: "sheets/b.xlsx", kind: .link),
            .init(source: "sheets/b.xlsx", target: "docs/c.docx", kind: .link),
            .init(source: "decks/a.pptx", target: "notes/d.md", kind: .trail)])

final class GraphFilterTests: XCTestCase {
    func testEmptyFilterHasNoMask() {
        XCTAssertNil(GraphFilter("").mask(for: GraphTopology(small)))
        XCTAssertNil(GraphFilter("   ").mask(for: GraphTopology(small)))
        XCTAssertNil(GraphFilter("ext:").mask(for: GraphTopology(small)), "a bare ext: while typing filters nothing")
    }

    func testTextMatchesPathIgnoringCaseAndDiacritics() {
        let t = GraphTopology(small)
        XCTAssertEqual(GraphFilter("DECKS").mask(for: t), [true, false, false, false, false])
        XCTAssertEqual(GraphFilter("shéets").mask(for: t), [false, true, false, false, false])
        XCTAssertEqual(GraphFilter("s/").mask(for: t), [true, true, true, true, false])
    }

    func testExtAndOrphansAndConjunction() {
        let t = GraphTopology(small)
        XCTAssertEqual(GraphFilter("ext:pptx").mask(for: t), [true, false, false, false, false])
        XCTAssertEqual(GraphFilter("ext:PPTX,.md").mask(for: t), [true, false, false, true, false])
        XCTAssertEqual(GraphFilter("orphans").mask(for: t), [false, false, false, false, true])
        XCTAssertEqual(GraphFilter("ext:pptx,xlsx sheets").mask(for: t), [false, true, false, false, false])
    }
}

final class GraphNavigationTests: XCTestCase {
    func testMovesInDirectionAndPrefersAlignedNodes() {
        //        1
        //  3  0     2
        //        4
        let t = GraphTopology(Graph(nodes: (0..<5).map { node("n\($0).md") }))
        let p = [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: -50), CGPoint(x: 100, y: 0),
                 CGPoint(x: -60, y: 0), CGPoint(x: 40, y: 50)]
        XCTAssertEqual(GraphNavigation.next(from: 0, .right, positions: p, topology: t), 2)
        XCTAssertEqual(GraphNavigation.next(from: 0, .left, positions: p, topology: t), 3)
        XCTAssertEqual(GraphNavigation.next(from: 0, .up, positions: p, topology: t), 1)
        XCTAssertEqual(GraphNavigation.next(from: 0, .down, positions: p, topology: t), 4)
        XCTAssertNil(GraphNavigation.next(from: 2, .right, positions: p, topology: t))
    }

    func testGraphNeighborBeatsSlightlyCloserStranger() {
        let g = Graph(nodes: (0..<3).map { node("n\($0).md") },
                      edges: [.init(source: "n0.md", target: "n2.md", kind: .link)])
        let t = GraphTopology(g)
        let p = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 70, y: 0)]
        XCTAssertEqual(GraphNavigation.next(from: 0, .right, positions: p, topology: t), 2)
    }

    func testRespectsFilter() {
        let t = GraphTopology(Graph(nodes: (0..<3).map { node("n\($0).md") }))
        let p = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 90, y: 0)]
        XCTAssertEqual(GraphNavigation.next(from: 0, .right, positions: p, topology: t, eligible: [true, false, true]), 2)
        XCTAssertEqual(GraphNavigation.nearest(to: CGPoint(x: 45, y: 0), positions: p, eligible: [true, false, true]), 0)
    }
}

final class RadialLayoutTests: XCTestCase {
    func testNeighborhoodDepth() {
        let one = RadialLayout.neighborhood(of: "decks/a.pptx", in: small, depth: 1)
        XCTAssertEqual(one.nodes.map(\.id), ["decks/a.pptx", "notes/d.md", "sheets/b.xlsx"])
        XCTAssertEqual(one.edges.count, 2)
        let two = RadialLayout.neighborhood(of: "decks/a.pptx", in: small, depth: 2)
        XCTAssertEqual(Set(two.nodes.map(\.id)), ["decks/a.pptx", "sheets/b.xlsx", "notes/d.md", "docs/c.docx"])
        XCTAssertEqual(RadialLayout.neighborhood(of: "missing", in: small, depth: 2), Graph())
    }

    func testRingsAndSpacing() {
        // A hub with 12 spokes, each spoke with two leaves.
        var nodes = [node("hub.md")], edges: [Graph.Edge] = []
        for i in 0..<12 {
            nodes.append(node("s\(i).md")); edges.append(.init(source: "hub.md", target: "s\(i).md", kind: .link))
            for j in 0..<2 {
                nodes.append(node("s\(i)-\(j).md")); edges.append(.init(source: "s\(i).md", target: "s\(i)-\(j).md", kind: .link))
            }
        }
        let local = RadialLayout.local(graph: Graph(nodes: nodes, edges: edges), center: FileRef(relativePath: "hub.md"), depth: 2)
        let t = GraphTopology(local.graph)
        XCTAssertEqual(local.center, 0)
        XCTAssertEqual(local.positions[0], .zero)
        func r(_ id: String) -> CGFloat { let p = local.positions[t.index[id]!]; return (p.x * p.x + p.y * p.y).squareRoot() }
        XCTAssertEqual(r("s0.md"), r("s7.md"), accuracy: 1e-6)
        XCTAssertGreaterThan(r("s3-1.md"), r("s3.md") + RadialLayout.ringGap - 1)
        // No two nodes closer than the minimum arc's chord on their ring.
        for i in local.positions.indices { for j in local.positions.indices where j > i {
            let dx = local.positions[i].x - local.positions[j].x, dy = local.positions[i].y - local.positions[j].y
            XCTAssertGreaterThan((dx * dx + dy * dy).squareRoot(), RadialLayout.minArc * 0.9, "\(t.ids[i]) vs \(t.ids[j])")
        } }
        // Leaves sit near their spoke.
        let spoke = local.positions[t.index["s5.md"]!], leaf = local.positions[t.index["s5-0.md"]!]
        XCTAssertLessThan(abs(atan2(spoke.y, spoke.x) - atan2(leaf.y, leaf.x)), 0.5)
    }

    func testSpreadKeepsClusterCentered() {
        let spread = RadialLayout.spreadOnCircle([1, 1, 1], minGap: 0.2)
        XCTAssertEqual(spread[0], 0.8, accuracy: 1e-3)
        XCTAssertEqual(spread[1], 1.0, accuracy: 1e-3)
        XCTAssertEqual(spread[2], 1.2, accuracy: 1e-3)
    }
}

@MainActor
final class GraphModelTests: XCTestCase {
    private func fixedModel() -> GraphModel {
        let t = GraphTopology(small)
        let positions = (0..<t.count).map { CGPoint(x: Double($0) * 40, y: 0) }
        let m = GraphModel(fixedGraph: small, positions: positions)
        m.fitMaxZoom = 1
        m.viewResized(to: CGSize(width: 400, height: 300))
        return m
    }

    func testHitTestingFindsNodesAndPrefersFilterMatches() {
        let m = fixedModel()
        let s = m.camera.toScreen(CGPoint(x: 40, y: 0), size: m.size)
        XCTAssertEqual(m.node(atScreen: s), 1)
        XCTAssertNil(m.node(atScreen: CGPoint(x: s.x, y: s.y + 60)))
    }

    func testClickSelectsWithoutOpeningAndActivateOpens() {
        let m = fixedModel()
        var opened: [String] = []
        m.onSelect = { opened.append($0.relativePath) }
        m.click(2)
        XCTAssertEqual(m.selectedIndex, 2)
        XCTAssertEqual(opened, [])
        m.activate(2)
        XCTAssertEqual(opened, ["docs/c.docx"])
        m.openSelection()
        XCTAssertEqual(opened.count, 2)
    }

    func testArrowsMoveSelectionWithoutOpening() {
        let m = fixedModel()
        var opened = 0
        m.onSelect = { _ in opened += 1 }
        m.moveSelection(.right)
        XCTAssertNotNil(m.selectedIndex)
        let first = m.selectedIndex!
        m.moveSelection(.right)
        XCTAssertEqual(m.selectedIndex, first + 1)
        XCTAssertEqual(opened, 0)
    }

    func testFilterAndBestMatch() {
        let m = fixedModel()
        var opened: [String] = []
        m.onSelect = { opened.append($0.relativePath) }
        m.setFilter("ext:xlsx,docx")
        XCTAssertEqual(m.filterMask, [false, true, true, false, false])
        m.openBestMatch()
        XCTAssertEqual(opened, ["sheets/b.xlsx"], "b has the most edges among the matches")
    }

    func testSelectFromOutsideAndUpdateKeepsSelection() {
        let m = fixedModel()
        m.select(FileRef(relativePath: "notes/d.md"))
        XCTAssertEqual(m.selectedIndex, 3)
        var g = small
        g.nodes.insert(node("z.key"), at: 0)
        m.update(graph: g)
        XCTAssertEqual(m.selectedIndex, 4, "selection follows the id, not the index")
        m.select(FileRef(relativePath: "not/there.pdf"))
        XCTAssertNil(m.selectedIndex)
    }

    func testFrameCarriesHoverAndLabels() {
        let m = fixedModel()
        m.hover(1)
        let f = m.advance(to: CACurrentMediaTime() + 1, canvasSize: m.size)
        XCTAssertEqual(f.hovered, 1)
        XCTAssertEqual(f.hoverAmount, 1, accuracy: 1e-9)
        m.hover(nil)
        let later = m.advance(to: CACurrentMediaTime() + 2, canvasSize: m.size)
        XCTAssertEqual(later.hoverAmount, 0, accuracy: 1e-9)
        XCTAssertNil(later.hovered)
    }

    func testFixedModeDragMovesNodeWithoutPinning() {
        let m = fixedModel()
        m.beginNodeDrag(0)
        m.dragNode(0, toWorld: CGPoint(x: 5, y: 7))
        m.endNodeDrag(0)
        XCTAssertEqual(m.worldPosition(of: 0), CGPoint(x: 5, y: 7))
        XCTAssertFalse(m.isPinned(0))
    }

    func testLiveModelPersistsToVault() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("graph-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = Vault(root: dir)
        let m = GraphModel(graph: small, vault: vault)
        m.suspend()
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: LayoutStore.fileURL(in: vault).path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let saved = try XCTUnwrap(LayoutStore.load(from: vault))
        XCTAssertEqual(Set(saved.nodes.keys), Set(small.nodes.map(\.id)))
    }
}

final class GhostAndInboxTests: XCTestCase {
    func testMissingFilesAreMarkedAndInboxIsANote() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ghost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("decks"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("decks/a.pptx").path, contents: Data())
        let g = Graph(nodes: [node("decks/a.pptx"), Graph.Node(id: "Pricing Ideas", name: "Pricing Ideas", ext: ""),
                              Graph.Node(id: "_inbox/2026-10-14", name: "2026-10-14", ext: "")])
        var t = GraphTopology(g)
        XCTAssertEqual(t.missing, [false, false, false], "nothing is missing until a vault says so")
        XCTAssertEqual(t.exts[2], "md", "inbox thoughts are notes")
        t.markMissing(in: Vault(root: dir))
        XCTAssertEqual(t.missing, [false, true, false])
    }

    func testFitLeavesRoomForLabels() {
        let size = CGSize(width: 300, height: 300)
        let tight = GraphCamera.fitting([CGPoint(x: -100, y: 0), CGPoint(x: 100, y: 0)], radii: [0, 0], in: size, padding: 20, maxZoom: 10)
        let roomy = GraphCamera.fitting([CGPoint(x: -100, y: 0), CGPoint(x: 100, y: 0)], radii: [0, 0], in: size, padding: 20,
                                        horizontalPadding: 70, maxZoom: 10)
        XCTAssertEqual(tight.zoom, 260.0 / 200, accuracy: 1e-9)
        XCTAssertEqual(roomy.zoom, 160.0 / 200, accuracy: 1e-9)
    }
}
