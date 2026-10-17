import XCTest
@testable import FlamingoIndex
import FlamingoCore

/// One connection per file pair, explicit before suggested, dismissals hide only suggestions.
final class FileConnectionsTests: IndexTestCase {
    private let me = FileRef(relativePath: "memo.docx")

    private func related(_ items: [RelatedFile], backlinks: [RelatedFile] = []) -> RelatedFilesSnapshot {
        var s = RelatedFilesSnapshot(); s.related = items; s.backlinks = backlinks; return s
    }

    func testEvidenceMergesIntoOneConnectionPerFile() {
        let deck = FileRef(relativePath: "decks/q3.pptx")
        let snapshot = related([
            RelatedFile(file: deck, anchor: FileAnchor(kind: .slide, value: "7"),
                        reasons: [RelatedFileReason(kind: .thoughtLink, connectionLabel: nil)], excerpt: "See [[q3.pptx#slide 7]]"),
        ])
        let edges = [Graph.Edge(source: "memo.docx", target: "decks/q3.pptx", kind: .mention, weight: 2),
                     Graph.Edge(source: "memo.docx", target: "decks/q3.pptx", kind: .trail, weight: 3)]
        let result = FileConnections.merge(for: me, related: snapshot, edges: edges)
        XCTAssertEqual(result.explicit.count, 1)
        XCTAssertTrue(result.suggested.isEmpty, "a linked file is not also a suggestion")
        let c = result.explicit[0]
        XCTAssertEqual(c.file, deck)
        XCTAssertEqual(c.anchor, FileAnchor(kind: .slide, value: "7"))
        XCTAssertEqual(c.reasons, [.linked, .mentioned, .together])
        XCTAssertEqual(c.headline?.excerpt, "See [[q3.pptx#slide 7]]")
        XCTAssertGreaterThan(c.strength, 0.9)
    }

    func testSuggestionsRankAndDismissalHidesOnlySuggestions() {
        let manual = FileRef(relativePath: "a.md")
        let edges = [Graph.Edge(source: "b.md", target: "memo.docx", kind: .mention, weight: 1),
                     Graph.Edge(source: "memo.docx", target: "c.md", kind: .trail, weight: 1),
                     Graph.Edge(source: "memo.docx", target: "d.md", kind: .related, weight: 0.92),
                     Graph.Edge(source: "memo.docx", target: "e/", kind: .folder)]
        let snapshot = related([RelatedFile(file: manual, anchor: nil,
                                            reasons: [RelatedFileReason(kind: .manual, connectionLabel: "same launch")], excerpt: "")])
        var result = FileConnections.merge(for: me, related: snapshot, edges: edges)
        XCTAssertEqual(result.explicit.map(\.file.relativePath), ["a.md"])
        XCTAssertEqual(result.explicit[0].headline?.note, "same launch")
        XCTAssertEqual(result.suggested.map(\.file.relativePath), ["d.md", "b.md", "c.md"], "folders are structure, not connections")
        // `b.md` mentions memo: the evidence lives in b.md.
        XCTAssertEqual(result.suggested[1].evidence.first?.source, FileRef(relativePath: "b.md"))

        let dismissed: Set<String> = [DismissedConnection.key("memo.docx", "b.md"), DismissedConnection.key("a.md", "memo.docx")]
        result = FileConnections.merge(for: me, related: snapshot, edges: edges, dismissed: dismissed)
        XCTAssertEqual(result.suggested.map(\.file.relativePath), ["d.md", "c.md"])
        XCTAssertEqual(result.explicit.map(\.file.relativePath), ["a.md"], "a dismissal never hides a connection someone made")
    }

    func testCopiesAndVersionsJoinExistingConnectionsOrBecomeStrongSuggestions() {
        let edges = [Graph.Edge(source: "memo.docx", target: "old/memo v1.docx", kind: .trail, weight: 1)]
        let base = FileConnections.merge(for: me, related: RelatedFilesSnapshot(), edges: edges)
        let out = FileConnections.adding(versions: [(FileRef(relativePath: "old/memo v1.docx"), false, "same title"),
                                                    (FileRef(relativePath: "export/memo.pdf"), true, ""),
                                                    (FileRef(relativePath: "gone.docx"), true, "")],
                                         to: base, for: me, dismissed: [DismissedConnection.key("memo.docx", "gone.docx")])
        XCTAssertEqual(out.suggested.map(\.file.relativePath), ["export/memo.pdf", "old/memo v1.docx"])
        XCTAssertEqual(out.suggested[0].headline?.note, "Identical copy")
        XCTAssertEqual(out.suggested[1].reasons, [.version, .together])
    }

    func testSimilarPassageFillsAnEdgeThatAlreadySaidSimilar() {
        let edges = [Graph.Edge(source: "memo.docx", target: "board.jpg", kind: .related, weight: 0.4)]
        let out = FileConnections.merge(for: me, related: RelatedFilesSnapshot(), edges: edges,
                                        similar: [(FileRef(relativePath: "board.jpg"), 0.7, "PRICE\tLADDER  Mini $179")])
        XCTAssertEqual(out.suggested.count, 1)
        XCTAssertEqual(out.suggested[0].evidence.count, 1)
        XCTAssertEqual(out.suggested[0].headline?.excerpt, "PRICE LADDER Mini $179")
        XCTAssertEqual(out.suggested[0].evidence[0].weight, 0.7)
    }

    func testStrengthCombinesLikeIndependentSignals() {
        let one = FileConnections.strength(of: [ConnectionEvidence(reason: .together, weight: 1)])
        let two = FileConnections.strength(of: [ConnectionEvidence(reason: .together, weight: 1), ConnectionEvidence(reason: .mentioned, weight: 1)])
        XCTAssertGreaterThan(two, one)
        XCTAssertLessThanOrEqual(two, 1)
        XCTAssertEqual(FileConnections.strength(of: [ConnectionEvidence(reason: .yours)]), 1)
    }

    func testMentionExcerptFindsWhereTheNameIsWritten() throws {
        let model = try write("q3-model-2026.fltest", "numbers")
        let memo = try write("memo.fltest", "Opening line.\nThe board numbers come from q3-model-2026 and nothing else.")
        try store.reindex()
        let found = try XCTUnwrap(try store.mentionExcerpt(in: memo, naming: model))
        XCTAssertTrue(found.text.contains("q3-model-2026"), found.text)
        XCTAssertNil(try store.mentionExcerpt(in: memo, naming: FileRef(relativePath: "x.md")), "a short or generic name is never searched")
    }
}
