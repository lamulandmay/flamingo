import XCTest
@testable import FlamingoCore

final class DismissedConnectionsTests: XCTestCase {
    private func store() throws -> DismissedConnectionStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dismissed-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return DismissedConnectionStore(vault: Vault(root: root))
    }

    func testDismissIsUndirectedIdempotentAndRestorable() throws {
        let s = try store()
        try s.dismiss("b.md", "a.md")
        try s.dismiss("a.md", "b.md")
        XCTAssertEqual(try s.all().count, 1)
        XCTAssertEqual(s.keys(), [DismissedConnection.key("a.md", "b.md")])
        XCTAssertEqual(DismissedConnection.key("a.md", "b.md"), DismissedConnection.key("b.md", "a.md"))
        try s.restore("b.md", "a.md")
        XCTAssertTrue(s.keys().isEmpty)
        try s.dismiss("a.md", "a.md")
        XCTAssertTrue(s.keys().isEmpty, "a file is never dismissed from itself")
    }

    func testDismissalsFollowRenames() throws {
        let s = try store()
        try s.dismiss("old/a.md", "z.md")
        try s.reconcile(oldPath: "old", newPath: "new")
        XCTAssertEqual(s.keys(), [DismissedConnection.key("new/a.md", "z.md")])
    }
}
