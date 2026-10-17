import XCTest
import FlamingoCore
@testable import FlamingoCapture

final class CaptureDraftTests: XCTestCase {
    func vault() throws -> Vault {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-draft-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Vault(root: root)
    }

    func testRecoveryKeepsLatestDraftPerFileAndSourceContext() throws {
        let vault = try vault(), file = FileRef(relativePath: "paper.pdf"), other = FileRef(relativePath: "notes.md")
        let provenance = CommentProvenance(appName: "Preview", windowTitle: "paper.pdf", sourceURL: "file:///paper.pdf")
        try CaptureDraftStore.save(CaptureDraft(file: file, anchor: .init(kind: .page, value: "7"), text: "First", provenance: provenance), in: vault)
        try CaptureDraftStore.save(CaptureDraft(file: other, text: "Other"), in: vault)
        try CaptureDraftStore.save(CaptureDraft(file: file, anchor: .init(kind: .page, value: "7"), text: "Latest", provenance: provenance), in: vault)
        let drafts = CaptureDraftStore.drafts(in: vault)
        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts.last?.text, "Latest")
        XCTAssertEqual(drafts.last?.provenance, provenance)
        try CaptureDraftStore.remove(file, in: vault)
        XCTAssertEqual(CaptureDraftStore.drafts(in: vault).map(\.file), [other])
    }

    func testCorruptRecoveryFileIsNeverOverwrittenByANewDraft() throws {
        let vault = try vault()
        try FileManager.default.createDirectory(at: vault.stateDir, withIntermediateDirectories: true)
        let bytes = Data("recoverable original content".utf8), url = CaptureDraftStore.url(in: vault)
        try bytes.write(to: url)
        XCTAssertThrowsError(try CaptureDraftStore.save(CaptureDraft(file: .init(relativePath: "a.md"), text: "new"), in: vault))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testLateEditCommitCannotClearANewerRecoveryDraft() throws {
        let vault = try vault(), file = FileRef(relativePath: "paper.md")
        var original = Comment(text: "First edit")
        try CommentEditDraftStore.save(original, for: file, in: vault)
        let first = original
        original.text = "Newer edit"
        try CommentEditDraftStore.save(original, for: file, in: vault)
        try CommentEditDraftStore.removeIfMatching(first, for: file, in: vault)
        XCTAssertEqual(try CommentEditDraftStore.draft(for: file, in: vault)?.text, "Newer edit")
        try CommentEditDraftStore.removeIfMatching(original, for: file, in: vault)
        XCTAssertNil(try CommentEditDraftStore.draft(for: file, in: vault))
    }
}
