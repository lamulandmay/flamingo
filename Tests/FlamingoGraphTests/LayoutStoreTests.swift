import XCTest
import CoreGraphics
import FlamingoCore
@testable import FlamingoGraph

final class LayoutStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("flamingo-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSeededPositionIsStable() {
        let p = LayoutStore.seededPosition(id: "decks/q3.pptx", count: 100)
        // Computed once; must never change, or every saved-less vault reshuffles.
        XCTAssertEqual(p.x, -9.181368066772784, accuracy: 1e-9)
        XCTAssertEqual(p.y, 23.7927570114501, accuracy: 1e-9)
        XCTAssertEqual(LayoutStore.seededPosition(id: "decks/q3.pptx", count: 100), p)

        // Inside the disk, and spread area-uniformly.
        var inner = 0
        for k in 0..<2000 {
            let q = LayoutStore.seededPosition(id: "file\(k).md", count: 2000)
            let r = Double(hypot(q.x, q.y))
            XCTAssertLessThanOrEqual(r, 10 * 2000.0.squareRoot())
            if r < 10 * 2000.0.squareRoot() / 2 { inner += 1 }
        }
        XCTAssertEqual(Double(inner) / 2000, 0.25, accuracy: 0.04)
        XCTAssertNotEqual(LayoutStore.seededPosition(id: "a.md", count: 10), LayoutStore.seededPosition(id: "b.md", count: 10))
    }

    func testSaveLoadRoundTrip() throws {
        let vault = Vault(root: tempDir)
        XCTAssertNil(LayoutStore.load(from: vault))
        let layout = SavedLayout(nodes: ["b/x.pdf": [1.25, -3.04], "a/y.md": [-0.04, 1000.06], "c.key": [2, 3]],
                                 pinned: ["c.key", "a/y.md"])
        try LayoutStore.save(layout, to: vault)

        let url = tempDir.appendingPathComponent(".flamingo/graph-layout.json")
        XCTAssertEqual(LayoutStore.fileURL(in: vault).standardizedFileURL, url.standardizedFileURL)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, #"{"nodes":{"a/y.md":[0,1000.1],"b/x.pdf":[1.3,-3],"c.key":[2,3]},"pinned":["a/y.md","c.key"],"version":1}"#)

        let loaded = try XCTUnwrap(LayoutStore.load(from: vault))
        XCTAssertEqual(loaded, layout.normalized)
        XCTAssertEqual(loaded.pinned, ["a/y.md", "c.key"])

        // Nothing else written anywhere.
        let everything = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: nil)!
            .compactMap { ($0 as? URL)?.standardizedFileURL.path }
        XCTAssertEqual(Set(everything), [tempDir.appendingPathComponent(".flamingo").standardizedFileURL.path, url.standardizedFileURL.path])

        // Overwrite is atomic and replaces the content.
        try LayoutStore.save(SavedLayout(nodes: [:], pinned: []), to: vault)
        XCTAssertEqual(LayoutStore.load(from: vault), SavedLayout(nodes: [:], pinned: []))
    }

    func testLoadIsLenientAndNeverThrows() throws {
        let vault = Vault(root: tempDir)
        try FileManager.default.createDirectory(at: vault.stateDir, withIntermediateDirectories: true)
        let url = LayoutStore.fileURL(in: vault)
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(LayoutStore.load(from: vault))
        try Data(#"{"nodes":{"a":[1,2]}}"#.utf8).write(to: url)
        XCTAssertEqual(LayoutStore.load(from: vault), SavedLayout(nodes: ["a": [1, 2]], pinned: []))
    }

    func testLayoutForTopologyRoundsAndSortsPins() {
        let t = makeTopology(nodes: 4, edges: 3)
        let positions = [CGPoint(x: 1.04, y: -1.06), CGPoint(x: -0.01, y: 3), CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 9.96, y: 0)]
        let layout = LayoutStore.layout(for: t, positions: positions, pinned: [3, 0, 2])
        XCTAssertEqual(layout.nodes[t.ids[0]], [1, -1.1])
        XCTAssertEqual(layout.nodes[t.ids[1]], [0, 3])
        XCTAssertEqual(layout.nodes[t.ids[1]]?[0].sign, .plus)
        XCTAssertNil(layout.nodes[t.ids[2]])
        XCTAssertEqual(layout.nodes[t.ids[3]], [10, 0])
        XCTAssertEqual(layout.pinned, [t.ids[0], t.ids[3]].sorted())
        XCTAssertEqual(layout.version, 1)
    }

    func testInitialPlacement() {
        let t = makeTopology(nodes: 30, edges: 50)

        // Nothing saved: seeded positions, full heat.
        let fresh = LayoutStore.initial(for: t, saved: nil)
        XCTAssertEqual(fresh.alpha, 1)
        XCTAssertEqual(fresh.restored, 0)
        XCTAssertTrue(fresh.pinned.isEmpty)
        for i in 0..<t.count { XCTAssertEqual(fresh.positions[i], LayoutStore.seededPosition(id: t.ids[i], count: t.count)) }

        // Everything saved: exact restore, no heat.
        var positions = fresh.positions.map { CGPoint(x: $0.x * 3, y: $0.y * 3) }
        let saved = LayoutStore.layout(for: t, positions: positions, pinned: [2, 9])
        let restored = LayoutStore.initial(for: t, saved: saved)
        XCTAssertEqual(restored.alpha, 0)
        XCTAssertEqual(restored.restored, t.count)
        XCTAssertEqual(restored.pinned, [2, 9])
        for i in 0..<t.count {
            XCTAssertEqual(Double(restored.positions[i].x), saved.nodes[t.ids[i]]![0])
            XCTAssertEqual(Double(restored.positions[i].y), saved.nodes[t.ids[i]]![1])
        }

        // One node new: it enters near the centroid of its placed neighbors, gentle heat.
        let newNode = (0..<t.count).first { t.degree($0) >= 2 }!
        var partial = saved
        partial.nodes.removeValue(forKey: t.ids[newNode])
        let some = LayoutStore.initial(for: t, saved: partial)
        XCTAssertEqual(some.alpha, 0.3)
        XCTAssertEqual(some.restored, t.count - 1)
        positions = some.positions
        var cx = 0.0, cy = 0.0
        for j in t.neighbors[newNode] { cx += Double(positions[j].x); cy += Double(positions[j].y) }
        cx /= Double(t.degree(newNode)); cy /= Double(t.degree(newNode))
        let offset = hypot(Double(positions[newNode].x) - cx, Double(positions[newNode].y) - cy)
        XCTAssertLessThanOrEqual(offset, ForceSimulation.Parameters().linkDistance / 2 + 1e-9)
        XCTAssertGreaterThan(offset, 0)
        // Deterministic, independent of what else is in the saved file.
        XCTAssertEqual(LayoutStore.initial(for: t, saved: partial).positions, some.positions)

        // A new chain hanging off a known node follows it in rings, not to the seeded disk.
        let chain = GraphTopology(Graph(nodes: ["hub", "a", "b", "c"].map { .init(id: $0, name: $0, ext: "") },
                                        edges: [.init(source: "hub", target: "a", kind: .link),
                                                .init(source: "a", target: "b", kind: .link),
                                                .init(source: "b", target: "c", kind: .trail)]))
        let chained = LayoutStore.initial(for: chain, saved: SavedLayout(nodes: ["hub": [500, 500]], pinned: []))
        XCTAssertEqual(chained.alpha, 0.3)
        for p in chained.positions { XCTAssertLessThan(hypot(p.x - 500, p.y - 500), 3 * 16 + 1e-6) }

        // Empty graph: nothing to do.
        XCTAssertEqual(LayoutStore.initial(for: GraphTopology(Graph()), saved: nil).alpha, 0)
    }

    func testNewUnconnectedNodesEnterOnTheOuterRing() {
        // Restored: a small connected layout. New: an orphan, and a new two-node component.
        let ids = ["a", "b", "c", "d", "new/orphan.md", "new/x.md", "new/y.md"]
        let g = Graph(nodes: ids.map { .init(id: $0, name: $0, ext: "") },
                      edges: [.init(source: "a", target: "b", kind: .link), .init(source: "b", target: "c", kind: .link),
                              .init(source: "c", target: "d", kind: .link), .init(source: "new/x.md", target: "new/y.md", kind: .link)])
        let t = GraphTopology(g)
        let saved = SavedLayout(nodes: ["a": [100, 0], "b": [140, 0], "c": [140, 40], "d": [100, 40]], pinned: [])
        let initial = LayoutStore.initial(for: t, saved: saved)
        XCTAssertEqual(initial.alpha, 0.3)
        XCTAssertEqual(initial.restored, 4)

        let center = CGPoint(x: 120, y: 20)
        let extent = hypot(20.0, 20.0)
        let ring = extent + ForceSimulation.Parameters().linkDistance
        func r(_ id: String) -> Double {
            let p = initial.positions[t.index[id]!]
            return Double(hypot(p.x - center.x, p.y - center.y))
        }
        // The orphan and the new component's anchor (smallest id) sit exactly on the ring.
        XCTAssertEqual(r("new/orphan.md"), ring, accuracy: 1e-9)
        XCTAssertEqual(r("new/x.md"), ring, accuracy: 1e-9)
        // Its neighbor grows from the anchor, outside the restored layout.
        let x = initial.positions[t.index["new/x.md"]!], y = initial.positions[t.index["new/y.md"]!]
        XCTAssertLessThanOrEqual(hypot(x.x - y.x, x.y - y.y), ForceSimulation.Parameters().linkDistance / 2 + 1e-9)
        XCTAssertGreaterThan(r("new/y.md"), extent)
        // Angles come from the id: different ids, different places.
        XCTAssertNotEqual(initial.positions[t.index["new/orphan.md"]!], x)
        // Independent of node order.
        let reversed = GraphTopology(Graph(nodes: g.nodes.reversed(), edges: g.edges.reversed()))
        let again = LayoutStore.initial(for: reversed, saved: saved)
        for id in ids {
            XCTAssertEqual(again.positions[reversed.index[id]!], initial.positions[t.index[id]!], id)
        }
        // Fresh layouts are untouched by this: every node seeded.
        let fresh = LayoutStore.initial(for: t, saved: nil)
        for i in 0..<t.count { XCTAssertEqual(fresh.positions[i], LayoutStore.seededPosition(id: t.ids[i], count: t.count)) }
    }

    func testCache() {
        let key = "/tmp/vault-\(UUID().uuidString)"
        XCTAssertNil(LayoutStore.cached(key))
        let layout = SavedLayout(nodes: ["a": [1, 2]], pinned: ["a"])
        LayoutStore.setCached(layout, for: key)
        XCTAssertEqual(LayoutStore.cached(key), layout)
        DispatchQueue.concurrentPerform(iterations: 200) { k in
            LayoutStore.setCached(SavedLayout(nodes: ["n": [Double(k), 0]], pinned: []), for: key + "-\(k % 7)")
            _ = LayoutStore.cached(key)
        }
        XCTAssertEqual(LayoutStore.cached(key), layout)
    }
}
