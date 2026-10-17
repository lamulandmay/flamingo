import XCTest
import FlamingoCore
@testable import FlamingoCapture

@MainActor
final class InboxTests: XCTestCase {
    func testInboxOnlyReadsUnattachedThoughtsAndFailedAttachKeepsOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-inbox-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = Vault(root: root), inbox = FileRef(relativePath: "_inbox/2026-10-15"), target = FileRef(relativePath: "research.md")
        let store = SidecarStore(vault: vault)
        let origin = CommentProvenance(appName: "Safari", windowTitle: "Research page", sourceURL: "https://example.org")
        try store.append(Comment(text: "Unattached evidence", provenance: origin), to: inbox)
        try store.append(Comment(text: "Already attached"), to: target)
        let model = CaptureInboxModel(vault: vault, files: [target])
        await model.load()
        XCTAssertEqual(model.items.map(\.comment.text), ["Unattached evidence"])
        XCTAssertEqual(model.item?.comment.provenance, origin)
        model.target = target
        await model.attach { _, _, _ in throw CocoaError(.fileWriteNoPermission) }
        XCTAssertEqual(model.items.count, 1)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(try store.comments(for: inbox).count, 1)
        await model.attach { comment, source, destination in
            XCTAssertEqual(source, inbox); XCTAssertEqual(destination, target)
            try store.append(comment, to: destination)
            try store.delete(comment.id, from: source)
        }
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(try store.comments(for: inbox).isEmpty)
        XCTAssertEqual(try store.comments(for: target).last?.provenance, origin)
    }
}
