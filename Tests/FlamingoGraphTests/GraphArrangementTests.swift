import XCTest
import QuartzCore
import FlamingoCore
@testable import FlamingoGraph

private func node(_ path: String) -> Graph.Node {
    Graph.Node(id: path, name: (path as NSString).lastPathComponent, ext: (path as NSString).pathExtension)
}

/// A small vault's worth of shapes: a crowded folder of mixed files, many small projects, a deep
/// single-child chain, empty folders, a note with no folder and a link to nothing.
private func vaultGraph() -> Graph {
    var nodes: [Graph.Node] = []
    let exts = ["pptx", "xlsx", "docx", "pdf", "png", "md", "swift"]
    for i in 0..<40 { nodes.append(node("Work/Q3/file-\(i).\(exts[i % exts.count])")) }
    for p in 0..<24 { for f in 0..<(p % 7 + 1) { nodes.append(node("Projects/P\(p)/note-\(f).md")) } }
    nodes.append(node("One/Two/Three/Four/Five/deep.txt"))
    nodes += [node("Archive/Empty/"), node("Archive/Old/"), node("readme.md")]
    nodes.append(Graph.Node(id: "_inbox/2026-10-14", name: "2026-10-14", ext: ""))
    nodes.append(Graph.Node(id: "Pricing Ideas", name: "Pricing Ideas", ext: ""))
    let edges: [Graph.Edge] = [.init(source: "Work/Q3/file-0.pptx", target: "Projects/P3/note-0.md", kind: .link),
                               .init(source: "readme.md", target: "Pricing Ideas", kind: .link)]
    return GraphFolders.addingAncestors(to: Graph(nodes: nodes, edges: edges))
}

private let arranged = GraphArrangement.allCases.filter { $0 != .organic }

final class ArrangedLayoutTests: XCTestCase {
    private func points(_ t: GraphTopology, _ p: [CGPoint]) -> [String: CGPoint] {
        Dictionary(uniqueKeysWithValues: t.ids.enumerated().map { ($0.element, p[$0.offset]) })
    }

    func testEveryArrangementIsFiniteDeterministicAndIndependentOfOrder() {
        let graph = vaultGraph()
        var reversed = graph
        reversed.nodes.reverse(); reversed.edges.reverse()
        let a = GraphTopology(graph), b = GraphTopology(reversed)
        for arrangement in arranged {
            let first = ArrangedLayout.positions(for: a, arrangement: arrangement)
            XCTAssertEqual(first.count, a.count, arrangement.title)
            XCTAssertTrue(first.allSatisfy { $0.x.isFinite && $0.y.isFinite }, arrangement.title)
            XCTAssertEqual(points(a, first), points(b, ArrangedLayout.positions(for: b, arrangement: arrangement)), arrangement.title)
        }
        XCTAssertEqual(ArrangedLayout.positions(for: GraphTopology(Graph()), arrangement: .circles), [])
    }

    func testNoTwoNodesOverlap() {
        let t = GraphTopology(vaultGraph())
        for arrangement in arranged {
            let p = ArrangedLayout.positions(for: t, arrangement: arrangement)
            var worst = Double.infinity
            for i in 0..<t.count {
                for j in (i + 1)..<t.count {
                    let gap = Double(hypot(p[i].x - p[j].x, p[i].y - p[j].y)) - t.radius[i] - t.radius[j]
                    worst = min(worst, gap)
                }
            }
            XCTAssertGreaterThan(worst, 1, "\(arrangement.title): two nodes touch")
        }
    }

    func testHoneycombPutsEveryNodeOnOneHexagonalLattice() {
        let t = GraphTopology(vaultGraph())
        let p = ArrangedLayout.positions(for: t, arrangement: .honeycomb)
        let d = Double(ArrangedLayout.spacing)
        let origin = p[t.index["/"]!]
        for (i, q) in p.enumerated() {
            let local = CGPoint(x: q.x - origin.x, y: q.y - origin.y)
            let snapped = ArrangedLayout.snapToLattice(local, spacing: d)
            XCTAssertEqual(Double(hypot(local.x - snapped.x, local.y - snapped.y)), 0, accuracy: 1e-6, t.ids[i])
        }
    }

    func testCirclesKeepEachFolderInItsOwnDiscWithItsFilesInRings() {
        let t = GraphTopology(vaultGraph())
        let p = ArrangedLayout.positions(for: t, arrangement: .circles)
        let d = Double(ArrangedLayout.spacing)
        let q3 = p[t.index["Work/Q3/"]!]
        for i in 0..<40 {
            let id = t.ids.first { $0.hasPrefix("Work/Q3/file-\(i).") }!
            let r = Double(hypot(p[t.index[id]!].x - q3.x, p[t.index[id]!].y - q3.y)) / d
            XCTAssertEqual(r, r.rounded(), accuracy: 1e-6, "files sit on whole rings around their folder")
            XCTAssertGreaterThanOrEqual(r, 1 - 1e-9)
        }
        // Sibling projects own disjoint discs: nothing of one is inside another's reach.
        func reach(_ folder: String) -> (CGPoint, Double) {
            let c = p[t.index[folder]!]
            let r = t.ids.indices.filter { t.ids[$0].hasPrefix(folder) }.map { Double(hypot(p[$0].x - c.x, p[$0].y - c.y)) }.max()!
            return (c, r)
        }
        let discs = (0..<24).map { reach("Projects/P\($0)/") }
        for i in discs.indices {
            for j in discs.indices where j > i {
                let (a, ra) = discs[i], (b, rb) = discs[j]
                XCTAssertGreaterThan(Double(hypot(a.x - b.x, a.y - b.y)), ra + rb, "P\(i) and P\(j) overlap")
            }
        }
    }

    func testRadialCentresTheTopFolderPutsLevelsOnRingsAndFilesOnOneCircle() {
        let t = GraphTopology(vaultGraph())
        let p = ArrangedLayout.positions(for: t, arrangement: .radial)
        XCTAssertEqual(p[t.index["/"]!], .zero)
        func radius(_ id: String) -> Double { Double(hypot(p[t.index[id]!].x, p[t.index[id]!].y)) }
        let tree = ArrangedLayout.FolderTree(t)
        let leaves = (0..<t.count).filter { tree.children[$0].isEmpty }
        let outer = radius(t.ids[leaves[0]])
        for i in leaves { XCTAssertEqual(radius(t.ids[i]), outer, accuracy: 1e-6, t.ids[i]) }
        XCTAssertEqual(radius("Work/"), radius("Projects/"), accuracy: 1e-6)
        XCTAssertEqual(radius("Work/Q3/"), radius("Projects/P0/"), accuracy: 1e-6)
        XCTAssertEqual(radius("Work/Q3/"), 2 * radius("Work/"), accuracy: 1e-6)
        XCTAssertGreaterThan(outer, radius("One/Two/Three/Four/Five/"))
    }

    func testGridIsTheFolderPacking() {
        let t = GraphTopology(vaultGraph())
        XCTAssertEqual(ArrangedLayout.positions(for: t, arrangement: .grid), GraphOverviewLayout.initial(for: t, saved: nil).positions)
    }

    func testAWholeDiskMapArrangesQuickly() {
        var nodes: [Graph.Node] = []
        for f in 0..<800 { for i in 0..<25 { nodes.append(node("Disk/F\(f / 40)/G\(f)/item-\(i).txt")) } }
        let t = GraphTopology(GraphFolders.addingAncestors(to: Graph(nodes: nodes)))
        XCTAssertGreaterThan(t.count, 20_000)
        for arrangement in arranged {
            let start = CACurrentMediaTime()
            let p = ArrangedLayout.positions(for: t, arrangement: arrangement)
            XCTAssertEqual(p.count, t.count)
            XCTAssertLessThan(CACurrentMediaTime() - start, 5, arrangement.title)
        }
    }
}

@MainActor
final class GraphArrangementModelTests: XCTestCase {
    private func vault() throws -> Vault {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("graph-arrange-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Vault(root: root)
    }

    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// Every glide and spring finished.
    private func settle(_ m: GraphModel) {
        _ = m.advance(to: CACurrentMediaTime() + 10, canvasSize: CGSize(width: 800, height: 600))
    }

    private func arranged(_ m: GraphModel, _ a: GraphArrangement) -> [CGPoint] {
        ArrangedLayout.positions(for: m.topology, arrangement: a)
    }

    func testArrangingLeavesTheSavedForceLayoutAndPinsAlone() throws {
        let vault = try vault()
        let g = vaultGraph()
        let saved = SavedLayout(nodes: Dictionary(uniqueKeysWithValues: g.nodes.enumerated().map { ($0.element.id, [Double($0.offset) * 7, 3]) }),
                                pinned: ["readme.md"])
        try LayoutStore.save(saved, to: vault)
        let m = GraphModel(graph: g, vault: vault)
        m.refreshScope()
        waitUntil { !m.isPreparing && m.topology.count == g.nodes.count }
        XCTAssertTrue(m.isPinned(m.topology.index["readme.md"]!))
        let organic = m.positions

        m.setArrangement(.honeycomb)
        waitUntil { m.slots != nil }
        settle(m)
        XCTAssertEqual(m.positions, arranged(m, .honeycomb))
        XCTAssertTrue(m.pinned.isEmpty, "an arrangement shows no pins")
        m.suspend()
        XCTAssertEqual(LayoutStore.cached(vault.root.path)?.nodes, saved.normalized.nodes, "arranged places are never saved")

        m.setArrangement(.organic)
        waitUntil { m.slots == nil }
        settle(m)
        XCTAssertEqual(m.positions, organic)
        XCTAssertTrue(m.isPinned(m.topology.index["readme.md"]!))
    }

    func testANodeLetGoInAnArrangementSpringsHomeAndPinsNothing() throws {
        let m = GraphModel(graph: vaultGraph(), vault: try vault(), arrangement: .circles)
        m.refreshScope()
        waitUntil { !m.isPreparing && m.topology.count > 0 }
        settle(m)
        let home = arranged(m, .circles)
        XCTAssertEqual(m.positions, home)
        let i = m.topology.index["Work/Q3/file-3.pdf"]!
        m.beginNodeDrag(i)
        m.dragNode(i, toWorld: CGPoint(x: 900, y: -900))
        m.endNodeDrag(i)
        XCTAssertFalse(m.isPinned(i))
        _ = m.advance(to: CACurrentMediaTime() + 0.05, canvasSize: CGSize(width: 800, height: 600))
        XCTAssertNotEqual(m.positions[i], home[i], "on its way, not teleported")
        settle(m)
        XCTAssertEqual(m.positions[i], home[i])
        XCTAssertTrue(m.contextMenu(at: CGPoint(x: -1000, y: -1000))?.items.contains { $0.title == "Reset Layout" } == false)
    }

    func testANewFileLeavesFromItsFolderAndTakesItsPlace() throws {
        let vault = try vault()
        let m = GraphModel(graph: vaultGraph(), vault: vault, arrangement: .radial)
        m.refreshScope()
        waitUntil { !m.isPreparing && m.topology.count > 0 }
        settle(m)
        let folder = m.positions[m.topology.index["Projects/P2/"]!]
        var grown = vaultGraph()
        grown.nodes.append(node("Projects/P2/new.md"))
        grown.edges.append(.init(source: "Projects/P2/", target: "Projects/P2/new.md", kind: .folder))
        m.update(graph: grown)
        waitUntil { m.topology.index["Projects/P2/new.md"] != nil }
        let i = m.topology.index["Projects/P2/new.md"]!
        XCTAssertEqual(m.positions[i], folder, "starts at its folder")
        settle(m)
        XCTAssertEqual(m.positions, arranged(m, .radial))
    }

    func testSwitchingTellsTheHostAndTheContextMenuChecksTheCurrentLayout() throws {
        let m = GraphModel(graph: vaultGraph(), vault: try vault())
        var told: [GraphArrangement] = []
        m.onArrangementChange = { told.append($0) }
        m.setArrangement(.grid)
        m.setArrangement(.grid)
        m.setArrangement(.circles, notify: false)
        XCTAssertEqual(told, [.grid])
        let layout = try XCTUnwrap(m.contextMenu(at: CGPoint(x: -1000, y: -1000))?.items.first { $0.title == "Layout" }?.submenu)
        XCTAssertEqual(layout.items.map(\.title), GraphArrangement.allCases.map(\.title))
        XCTAssertEqual(layout.items.filter { $0.state == .on }.map(\.title), ["Circles"])
    }
}
