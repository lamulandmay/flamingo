import XCTest
import SwiftUI
import FlamingoCore
@testable import FlamingoGraph

@MainActor
final class GraphWorkflowTests: XCTestCase {
    private func vault() throws -> Vault {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("graph-workflow-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Vault(root: root)
    }
    private func node(_ path: String) -> Graph.Node { .init(id: path, name: (path as NSString).lastPathComponent, ext: "md") }

    func testFolderBudgetKeepsSelectionAndReportsOverflow() throws {
        let v = try vault()
        for i in 0..<20 { try Data().write(to: v.root.appendingPathComponent("folder/file-\(i).md")) }
        let result = GraphModel.scopedResult(Graph(), to: "folder", in: v, budget: 4,
                                            including: ["folder/file-19.md"])
        XCTAssertTrue(result.truncated)
        XCTAssertTrue(result.graph.nodes.contains { $0.id == "folder/file-19.md" })
        XCTAssertTrue(result.graph.nodes.contains { $0.id == "folder/" })
    }

    func testScopeDoesNotExpandTransitivelyOrDependOnEdgeOrder() throws {
        let v = try vault()
        try Data().write(to: v.root.appendingPathComponent("folder/a.md"))
        let edges: [Graph.Edge] = [.init(source: "folder/a.md", target: "b.md", kind: .link),
                                   .init(source: "b.md", target: "c.md", kind: .link)]
        let g = Graph(nodes: [node("folder/a.md"), node("b.md"), node("c.md")], edges: edges)
        let scoped = GraphModel.scoped(g, to: "folder", in: v, budget: 10)
        let reversed = GraphModel.scoped(Graph(nodes: g.nodes, edges: edges.reversed()), to: "folder", in: v, budget: 10)
        XCTAssertEqual(scoped, reversed)
        XCTAssertFalse(scoped.nodes.contains { $0.id == "c.md" })
    }

    func testSelectionScopeAndActivationAreSeparateAndConnectionPickingStaysPut() {
        let g = Graph(nodes: [node("a.md"), node("b.md"), .init(id: "folder/", name: "folder", ext: "")])
        let model = GraphModel(fixedGraph: g, positions: [.zero, .init(x: 40, y: 0), .init(x: 80, y: 0)])
        var selected: [String] = [], opened: [String] = [], scopes: [String?] = []
        model.onSelectionChange = { if let path = $0?.relativePath { selected.append(path) } }
        model.onSelect = { opened.append($0.relativePath) }
        model.onScopeChange = { scopes.append($0) }
        model.click(0)
        XCTAssertEqual(selected, ["a.md"]); XCTAssertTrue(opened.isEmpty)
        model.click(1, additive: true)
        XCTAssertEqual(model.chosenIDs, ["a.md", "b.md"])
        XCTAssertEqual(selected, ["a.md"])
        model.setConnectionMode(.add)
        model.activate(1)
        XCTAssertTrue(opened.isEmpty)
        model.clearConnectionsSelection()
        var cleared = false
        model.onSelectionChange = { cleared = $0 == nil }
        model.click(2)
        XCTAssertTrue(cleared)
        model.select(nil)
        XCTAssertEqual(model.selectionPath, "folder/")
        model.activate(2)
        XCTAssertEqual(scopes, ["folder"])
        model.activate(0)
        XCTAssertEqual(opened, ["a.md"])
    }

    func testScopeSnapshotsPreserveInvisiblePinsAndUnpinOnlyVisibleNode() {
        let original = SavedLayout(nodes: ["a": [1, 2], "b": [3, 4]], pinned: ["a", "b"])
        let merged = LayoutStore.merging(.init(nodes: ["a": [8, 9]], pinned: []), into: original)
        XCTAssertEqual(merged.nodes["b"], [3, 4])
        XCTAssertEqual(merged.pinned, ["b"])
        XCTAssertEqual(merged.nodes["a"], [8, 9])
    }

    func testConnectionActionsPersistPairsAndKeepSelection() async throws {
        let v = try vault()
        for path in ["a.md", "b.md"] { try Data("Source content".utf8).write(to: v.root.appendingPathComponent(path)) }
        let model = GraphModel(graph: Graph(nodes: [node("a.md"), node("b.md")]), vault: v)
        model.suspend()
        model.click(0); model.click(1, additive: true); model.setConnectionMode(.add)
        model.applyConnections(label: "related evidence")
        for _ in 0..<100 where model.connectionBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.connectionError)
        XCTAssertEqual(try ConnectionStore(vault: v).all().count, 1)
        XCTAssertEqual(model.chosenIDs, ["a.md", "b.md"])
        XCTAssertEqual(model.connectionMode, .add)
        model.setConnectionMode(.remove); model.applyConnections()
        for _ in 0..<100 where model.connectionBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(try ConnectionStore(vault: v).all(), [])
        model.suspend()
    }

    func testFolderCenterRemainsHollowWhenSelectedHoveredDraggedOrNeighbor() throws {
        let graph = Graph(nodes: [.init(id: "folder/", name: "folder", ext: ""), node("a.md")],
                          edges: [.init(source: "folder/", target: "a.md", kind: .folder)])
        let topology = GraphTopology(graph)
        for state in 0..<4 {
            let frame = GraphFrame(topology: topology, positions: [.zero, .init(x: 30, y: 0)],
                                   camera: .init(center: .zero, zoom: 4), selected: state == 0 ? 0 : state == 3 ? 1 : nil,
                                   hovered: state == 1 ? 0 : nil, hoverAmount: 1, filterMask: nil,
                                   labelAmount: 0, pinned: [], dragging: state == 2 ? 0 : nil)
            let renderer = GraphRenderer()
            let canvas = Canvas { context, size in renderer.draw(frame, in: &context, size: size) }
                .frame(width: 160, height: 160).environment(\.colorScheme, .dark)
            let image = try XCTUnwrap(ImageRenderer(content: canvas).cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let center = try XCTUnwrap(bitmap.colorAt(x: 80, y: 80)?.usingColorSpace(.deviceRGB))
            let background = try XCTUnwrap(bitmap.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB))
            // A containment line can cross the center; compare a point just above it too.
            let inside = try XCTUnwrap(bitmap.colorAt(x: 80, y: 78)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(inside.redComponent, background.redComponent, accuracy: 0.01, "state \(state)")
            XCTAssertLessThan(abs(center.redComponent - background.redComponent), 0.4)
        }
    }
}
