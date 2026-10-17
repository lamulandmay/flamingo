import XCTest
@testable import FlamingoCore

final class CommentProvenanceTests: XCTestCase {
    func testSidecarKeepsProvenanceOutOfThoughtTextAndPreservesItThroughEdit() throws {
        let vault = try TempVault(); defer { vault.destroy() }
        let file = try vault.file("research.md")
        let store = SidecarStore(vault: vault.vault)
        let origin = CommentProvenance(origin: .ai, model: "local-model", appName: "Preview",
                                       windowTitle: "A --> B", sourceURL: "https://example.org/paper", reason: "Saved file")
        try store.append(Comment(text: "Interpretation\nSecond line", provenance: origin), to: file)
        var comment = try XCTUnwrap(store.comments(for: file).first)
        XCTAssertEqual(comment.text, "Interpretation\nSecond line")
        XCTAssertEqual(comment.provenance, origin)
        comment.text = "Revised interpretation"
        try store.update(comment, in: file)
        XCTAssertEqual(try store.comments(for: file).first?.provenance, origin)
        let rendered = try vault.contents(ofSidecarFor: "research.md")
        XCTAssertEqual(SidecarFormat.render(SidecarFormat.parseDocument(rendered)), rendered)
        XCTAssertFalse(rendered.contains("A --> B"), "metadata cannot close its HTML comment")
    }

    func testLegacyCommentsAndMalformedMetadataStayReadable() throws {
        let source = "- [2026-10-15 11:00] Human thought\n  <!-- flamingo: invalid json -->\n"
        let doc = SidecarFormat.parseDocument(source)
        XCTAssertNil(doc.comments.first?.provenance)
        XCTAssertEqual(SidecarFormat.render(doc), source)
        let data = try JSONEncoder().encode(Comment(text: "Old thought"))
        XCTAssertNil(try JSONDecoder().decode(Comment.self, from: data).provenance)
    }

    func testMergeDoesNotConfuseGeneratedAndHumanThoughts() {
        let target = FileRef(relativePath: "file.md"), date = Date(timeIntervalSince1970: 0)
        var human = SidecarDocument(target: target, id: nil, comments: [Comment(timestamp: date, text: "Keep it")])
        human.merge(SidecarDocument(target: target, id: nil, comments: [Comment(timestamp: date, text: "Keep it", provenance: .init(origin: .ai))]))
        XCTAssertEqual(human.comments.count, 2)
        XCTAssertEqual(Set(human.comments.map(\.id)).count, 2)
        XCTAssertEqual(SidecarFormat.parseDocument(SidecarFormat.render(human)).comments, human.comments)
    }
}
