import XCTest
import FlamingoCore
@testable import FlamingoGraph

@MainActor
final class GraphUndoTests: XCTestCase {
    private func fixture() throws -> (Vault, GraphModel, ActionHistory) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("graph-undo-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let vault = Vault(root: root)
        for path in ["a.md", "b.md"] { try Data("unchanged".utf8).write(to: root.appendingPathComponent(path)) }
        try LayoutStore.save(SavedLayout(nodes: ["a.md": [10, 20], "b.md": [80, 90], "hidden.md": [4, 5]],
                                        pinned: ["a.md", "b.md", "hidden.md"]), to: vault)
        let graph = Graph(nodes: ["a.md", "b.md"].map { .init(id: $0, name: $0, ext: "md") })
        let model = GraphModel(graph: graph, vault: vault), history = ActionHistory()
        model.actionHistory = history
        return (vault, model, history)
    }

    func testDragUnpinAndResetRestorePinsPositionsAndInvisibleLayout() throws {
        let (vault, model, history) = try fixture()
        model.beginNodeDrag(0)
        model.dragNode(0, toWorld: CGPoint(x: 300, y: 400))
        model.endNodeDrag(0)
        model.suspend()
        XCTAssertEqual(history.undoActionName, "Move graph node")
        XCTAssertTrue(try history.undo())
        XCTAssertEqual(model.positions[0], CGPoint(x: 10, y: 20))
        XCTAssertTrue(model.isPinned(0))
        XCTAssertTrue(try history.redo())
        XCTAssertEqual(model.positions[0], CGPoint(x: 300, y: 400))
        model.unpin(0); model.suspend()
        XCTAssertFalse(model.isPinned(0))
        XCTAssertTrue(try history.undo())
        XCTAssertTrue(model.isPinned(0))
        XCTAssertEqual(model.positions[0], CGPoint(x: 300, y: 400))
        model.resetVisibleLayout(); model.suspend()
        XCTAssertTrue(model.pinned.isEmpty)
        XCTAssertTrue(try history.undo())
        XCTAssertEqual(model.positions[0], CGPoint(x: 300, y: 400))
        XCTAssertEqual(model.pinned, [0, 1])
        let saved = try XCTUnwrap(LayoutStore.load(from: vault))
        XCTAssertEqual(saved.nodes["hidden.md"], [4, 5])
        XCTAssertTrue(saved.pinned.contains("hidden.md"))
        XCTAssertEqual(try String(contentsOf: vault.root.appendingPathComponent("a.md"), encoding: .utf8), "unchanged")
    }

    func testCameraGestureIsImmediatelyUndoableAndCoalescesUpdates() throws {
        let (_, model, history) = try fixture()
        let before = model.camera
        model.userMovedCamera()
        model.camera.pan(by: CGSize(width: 10, height: 20))
        model.userMovedCamera()
        model.camera.pan(by: CGSize(width: 30, height: 40))
        let after = model.camera
        XCTAssertTrue(try history.undo())
        XCTAssertEqual(model.camera, before)
        XCTAssertFalse(history.canUndo)
        XCTAssertTrue(try history.redo())
        XCTAssertEqual(model.camera, after)
        model.suspend()
    }

    func testConnectionUndoRestoresRemovedMetadataAndRejectsNewerEdits() async throws {
        let (vault, model, history) = try fixture()
        let store = ConnectionStore(vault: vault)
        _ = try store.setConnections(between: [FileRef(relativePath: "a.md"), FileRef(relativePath: "b.md")],
                                     connected: true, label: "Original explanation")
        let original = try store.all()
        model.click(0); model.click(1, additive: true); model.setConnectionMode(.remove)
        model.applyConnections()
        for _ in 0..<100 where model.connectionBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.connectionError)
        XCTAssertEqual(try store.all(), [])
        XCTAssertTrue(try history.undo())
        XCTAssertEqual(try store.all(), original)
        XCTAssertTrue(try history.redo())
        _ = try store.setConnections(between: [FileRef(relativePath: "a.md"), FileRef(relativePath: "b.md")],
                                     connected: true, label: "Changed elsewhere")
        let external = try store.all()
        XCTAssertThrowsError(try history.undo())
        XCTAssertEqual(try store.all(), external)
        XCTAssertTrue(history.canUndo)
        model.suspend()
    }

    func testPendingConnectionWriteCannotRegisterIntoClearedHistory() async throws {
        let (vault, model, history) = try fixture()
        var callbacks = 0
        model.onConnectionsChanged = { callbacks += 1 }
        model.click(0); model.click(1, additive: true); model.setConnectionMode(.add)
        model.applyConnections()
        history.clear()
        for _ in 0..<100 where model.connectionBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(try ConnectionStore(vault: vault).all().count, 1)
        XCTAssertFalse(history.canUndo)
        XCTAssertEqual(callbacks, 0)
        model.suspend()
    }
}
