import XCTest
import FlamingoCore
@testable import FlamingoGraph

final class GraphOverviewLayoutTests: XCTestCase {
    private func node(_ path: String) -> Graph.Node {
        Graph.Node(id: path, name: path, ext: "")
    }

    private func points(_ topology: GraphTopology, _ initial: LayoutStore.Initial) -> [String: CGPoint] {
        Dictionary(uniqueKeysWithValues: topology.ids.enumerated().map { ($0.element, initial.positions[$0.offset]) })
    }

    func testHierarchyIsFiniteDeterministicAndIndependentOfInputOrder() {
        let graph = GraphFolders.addingAncestors(to: Graph(nodes: [node("Work/A/one.txt"), node("Work/B/two.txt"),
                                                                  node("Photos/Trip/image.jpg"), node("_inbox/today")]))
        let topology = GraphTopology(graph)
        let first = GraphOverviewLayout.initial(for: topology, saved: nil)
        var reversed = graph
        reversed.nodes.reverse(); reversed.edges.reverse()
        let reordered = GraphTopology(reversed)
        let second = GraphOverviewLayout.initial(for: reordered, saved: nil)

        XCTAssertEqual(points(topology, first), points(reordered, second))
        XCTAssertEqual(first.alpha, 0)
        XCTAssertEqual(first.restored, 0)
        XCTAssertTrue(first.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    func testSiblingsAndDeepSingleChildChainsHaveSeparateSpace() {
        let graph = GraphFolders.addingAncestors(to: Graph(nodes: (0..<30).map { node("Work/Project-\($0)/file.txt") }
            + [node("One/Two/Three/Four/Five/file.txt")]))
        let topology = GraphTopology(graph)
        let initial = GraphOverviewLayout.initial(for: topology, saved: nil)
        for i in 0..<topology.count {
            for j in (i + 1)..<topology.count {
                let a = initial.positions[i], b = initial.positions[j]
                XCTAssertGreaterThan(Double(hypot(a.x - b.x, a.y - b.y)), topology.radius[i] + topology.radius[j])
            }
        }
    }

    func testSavedPinsStayExactAndNewDescendantsFollowTheirClosestSavedAncestor() {
        let topology = GraphTopology(GraphFolders.addingAncestors(to: Graph(nodes: [node("Work/A/one.txt"),
                                                                                 node("Work/B/two.txt")])))
        let fresh = GraphOverviewLayout.initial(for: topology, saved: nil)
        let before = points(topology, fresh)
        let saved = SavedLayout(nodes: ["Work/": [4_000, -2_000], "Work/A/": [-8_000, 3_000],
                                       "Work/B/two.txt": [.nan, 0]], pinned: ["Work/", "Work/A/", "Work/B/two.txt"])
        let restored = GraphOverviewLayout.initial(for: topology, saved: saved)
        let after = points(topology, restored)

        XCTAssertEqual(after["Work/"], CGPoint(x: 4_000, y: -2_000))
        XCTAssertEqual(after["Work/A/"], CGPoint(x: -8_000, y: 3_000))
        XCTAssertEqual(restored.restored, 2)
        XCTAssertEqual(restored.pinned, Set([topology.index["Work/"]!, topology.index["Work/A/"]!]))
        for (ancestor, descendant) in [("Work/", "Work/B/two.txt"), ("Work/A/", "Work/A/one.txt")] {
            XCTAssertEqual(after[descendant]!.x - after[ancestor]!.x, before[descendant]!.x - before[ancestor]!.x, accuracy: 0.000_001)
            XCTAssertEqual(after[descendant]!.y - after[ancestor]!.y, before[descendant]!.y - before[ancestor]!.y, accuracy: 0.000_001)
        }
        XCTAssertEqual(restored.alpha, 0)
    }

    func testLargeFolderCatalogRetainsEveryPositionWithoutDegenerateOverlap() {
        let files = (0..<20_000).map { node("Group-\($0 / 100)/Folder-\($0)/file.txt") }
        let topology = GraphTopology(GraphFolders.addingAncestors(to: Graph(nodes: files)))
        let initial = GraphOverviewLayout.initial(for: topology, saved: nil)
        XCTAssertGreaterThan(topology.count, GraphOverviewLayout.threshold)
        XCTAssertEqual(initial.positions.count, topology.count)
        XCTAssertTrue(initial.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        let unique = Set(initial.positions.map { "\($0.x),\($0.y)" })
        XCTAssertEqual(unique.count, topology.count)
        XCTAssertEqual(initial.positions, GraphOverviewLayout.initial(for: topology, saved: nil).positions)
    }

    func testEmptyGraphIsAlreadySettled() {
        let initial = GraphOverviewLayout.initial(for: GraphTopology(Graph()), saved: nil)
        XCTAssertTrue(initial.positions.isEmpty)
        XCTAssertTrue(initial.pinned.isEmpty)
        XCTAssertEqual(initial.restored, 0)
        XCTAssertEqual(initial.alpha, 0)
    }

    @MainActor
    func testLiveOverviewZoomDragAndResetNeverStartSimulation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("graph-overview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let vault = Vault(root: root)
        let graph = GraphFolders.addingAncestors(to: Graph(nodes: (0...GraphOverviewLayout.threshold).map {
            node("Catalog/Folder-\($0)/")
        }))
        let workersBefore = LayoutEngine.liveWorkerCount
        let model = GraphModel(graph: graph, vault: vault)
        defer {
            model.suspend()
            // Flush queued layout saves before removing this test's unique vault.
            _ = try? LayoutStore.restore(SavedLayout(nodes: [:], pinned: []), key: root.path, vault: vault)
            try? FileManager.default.removeItem(at: root)
        }
        let canvas = CGSize(width: 1_000, height: 700)
        model.viewResized(to: canvas)

        func awaitPrepared() async throws {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(5)
            while model.isPreparing && clock.now < deadline {
                XCTAssertLessThanOrEqual(LayoutEngine.liveWorkerCount, workersBefore)
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(model.isPreparing, "The overview should finish preparing within the bounded deadline")
            XCTAssertEqual(model.topology.count, graph.nodes.count)
            XCTAssertLessThanOrEqual(LayoutEngine.liveWorkerCount, workersBefore)
        }

        try await awaitPrepared()
        guard !model.isPreparing else { return }
        let initialPositions = model.positions
        model.camera = GraphCamera(center: .zero, zoom: GraphCamera.zoomRange.upperBound)
        _ = model.advance(to: ProcessInfo.processInfo.systemUptime, canvasSize: canvas)
        XCTAssertEqual(model.positions, initialPositions)
        model.camera = GraphCamera(center: .zero, zoom: GraphCamera.zoomRange.lowerBound)
        _ = model.advance(to: ProcessInfo.processInfo.systemUptime, canvasSize: canvas)
        XCTAssertEqual(model.positions, initialPositions)

        let index = try XCTUnwrap(model.topology.index["Catalog/Folder-0/"])
        let moved = CGPoint(x: initialPositions[index].x + 111, y: initialPositions[index].y + 77)
        model.beginNodeDrag(index)
        model.dragNode(index, toWorld: moved)
        XCTAssertTrue(model.isPinned(index))
        XCTAssertEqual(model.positions[index], moved)
        model.endNodeDrag(index)
        model.unpin(index)
        XCTAssertFalse(model.isPinned(index))
        XCTAssertEqual(model.positions[index], moved)
        XCTAssertLessThanOrEqual(LayoutEngine.liveWorkerCount, workersBefore)

        model.resetVisibleLayout()
        model.resume()
        XCTAssertTrue(model.pinned.isEmpty)
        XCTAssertEqual(model.positions, initialPositions)
        // A second asynchronous preparation also gives any incorrectly started worker an
        // opportunity to appear, without assuming an arbitrary delay is long enough.
        model.update(graph: graph)
        try await awaitPrepared()
        _ = model.advance(to: ProcessInfo.processInfo.systemUptime, canvasSize: canvas)
        XCTAssertEqual(model.positions, initialPositions)
        XCTAssertLessThanOrEqual(LayoutEngine.liveWorkerCount, workersBefore)
    }
}
