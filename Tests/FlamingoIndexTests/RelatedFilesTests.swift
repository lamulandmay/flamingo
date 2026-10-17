import XCTest
@testable import FlamingoIndex
import FlamingoCore

final class RelatedFilesTests: IndexTestCase {
    func testThoughtLinksKeepDestinationAnchorAndContextExcerpt() throws {
        let source = try write("notes.fltest", "notes")
        let target = try write("deck.fltest", deck)
        try store.reindex()
        let text = String(repeating: "Unrelated opening. ", count: 30) + "Pricing is supported by [[deck.fltest#slide 7|evidence]]. Check the margin."
        try store.replaceAllComments([source: [Comment(anchor: FileAnchor(kind: .page, value: "2"), text: text)]])
        let result = try store.relatedFiles(to: source)
        XCTAssertEqual(result.related.count, 1)
        XCTAssertEqual(result.related[0].file, target)
        XCTAssertEqual(result.related[0].anchor, FileAnchor(kind: .slide, value: "7"))
        XCTAssertEqual(result.related[0].reasons.map(\.kind), [.thoughtLink])
        XCTAssertTrue(result.related[0].excerpt.contains("Pricing is supported"))
        XCTAssertTrue(result.related[0].excerpt.contains("[[deck.fltest#slide 7|evidence]]"))
        XCTAssertLessThanOrEqual(result.related[0].excerpt.count, 262)
    }

    func testThoughtBacklinkUsesSourceAnchorAndDeduplicatesRepeatedLinks() throws {
        let source = try write("source.fltest", "source")
        let target = try write("target.fltest", "target")
        try store.reindex()
        try store.replaceAllComments([source: [
            Comment(anchor: FileAnchor(kind: .page, value: "3"), text: "See [[target.fltest#slide 9]] and [[target.fltest#slide 10]]."),
            Comment(anchor: FileAnchor(kind: .page, value: "4"), text: "Another point: [[target.fltest]].")
        ]])
        let result = try store.relatedFiles(to: target)
        XCTAssertEqual(result.backlinks.map(\.file), [source, source])
        XCTAssertEqual(result.backlinks.map(\.anchor?.value), ["3", "4"])
        XCTAssertTrue(result.backlinks.allSatisfy { $0.reasons.map(\.kind) == [.thoughtBacklink] })
    }

    func testMarkdownLinksAndBacklinksRetainLineEvidenceAndIgnoreCode() throws {
        let source = try write("notes.md", "== line 10: Review\nFirst line\nSee [[deck.fltest#slide 7]] twice [[deck.fltest#slide 7]].\n`[[ignored.fltest]]`\nAnother [[deck.fltest#slide 9]].")
        let target = try write("deck.fltest", deck)
        try write("ignored.fltest", "ignored")
        try store.reindex()
        let outgoing = try store.relatedFiles(to: source)
        XCTAssertEqual(outgoing.related.map(\.file), [target, target])
        XCTAssertEqual(outgoing.related.map(\.anchor?.value), ["7", "9"])
        let incoming = try store.relatedFiles(to: target)
        XCTAssertEqual(incoming.backlinks.map(\.anchor?.value), ["11", "13"])
        XCTAssertEqual(incoming.backlinks.first?.reasons.first?.kind, .documentBacklink)
    }

    func testMarkdownHeadingDestinationResolvesToIndexedLine() throws {
        let source = try write("source.md", "[[target.md#Costs]]")
        let target = try write("target.md", "== line 12: Costs\nDetailed evidence")
        try store.reindex()
        let result = try store.relatedFiles(to: source)
        XCTAssertEqual(result.related.first?.file, target)
        XCTAssertEqual(result.related.first?.anchor, FileAnchor(kind: .line, value: "12"))
    }

    func testAliasesAndDuplicateBasenamesFollowExistingResolver() throws {
        let source = try write("project/source.md", "[[report.fltest#page 2]] and [[old/report.fltest#page 3]]")
        let sameFolder = try write("project/report.fltest", "local")
        try write("elsewhere/report.fltest", "other")
        let moved = try write("new/report.fltest", "renamed")
        try PathAliases(vault: vault).reconcile(oldPath: "old", newPath: "new")
        try store.reindex()
        let result = try store.relatedFiles(to: source)
        XCTAssertEqual(Set(result.related.map(\.file)), [sameFolder, moved])
        XCTAssertEqual(result.related.first(where: { $0.file == moved })?.anchor?.value, "3")
        XCTAssertEqual(try store.relatedFiles(to: moved).backlinks.first?.file, source)
    }

    func testManualLabelMergesWithLinkAndPreservesSourceContent() throws {
        let source = try write("source.md", "[[target.fltest]] [[target.fltest]]")
        let target = try write("target.fltest", "target")
        try store.reindex()
        let connection = ManualConnection(source: source.relativePath, target: target.relativePath, label: "  Supporting data  ")
        let result = try store.relatedFiles(to: source, connections: [connection])
        XCTAssertEqual(result.related.count, 1)
        XCTAssertEqual(result.related[0].reasons.map(\.kind), [.manual, .documentLink])
        XCTAssertEqual(result.related[0].reasons[0].label, "Connected · Supporting data")
        XCTAssertFalse(result.related[0].excerpt.isEmpty)
        let reverse = try store.relatedFiles(to: target, connections: [connection])
        XCTAssertEqual(reverse.related.first?.file, source)
        XCTAssertEqual(reverse.backlinks.first?.file, source)
        XCTAssertEqual(try String(contentsOf: vault.url(for: source)), "[[target.fltest]] [[target.fltest]]")
    }

    func testDeletedEndpointsAreExcludedWithoutBasenameSubstitution() throws {
        let source = try write("source.md", "[[gone/report.fltest]]")
        let deleted = try write("gone/report.fltest", "deleted")
        try write("elsewhere/report.fltest", "surviving twin")
        try store.reindex()
        try FileManager.default.removeItem(at: vault.url(for: deleted))
        let connection = ManualConnection(source: source.relativePath, target: deleted.relativePath)
        XCTAssertTrue(try store.relatedFiles(to: source, connections: [connection]).related.isEmpty)
    }

    func testBoundsPrioritizeOutboundAndCancellationPropagates() throws {
        let source = try write("source.md", "[[target.fltest]]")
        let target = try write("target.fltest", "target")
        let back = try write("back.fltest", "back")
        try store.reindex()
        try store.replaceAllComments([back: [Comment(text: "[[source.md]]")]])
        let result = try store.relatedFiles(to: source, limit: 1)
        XCTAssertEqual(result.related.map(\.file), [target])
        XCTAssertTrue(result.backlinks.isEmpty)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(try store.relatedFiles(to: source, limit: 0), RelatedFilesSnapshot())
        XCTAssertThrowsError(try store.relatedFiles(to: source, checkCancellation: { throw CancellationError() })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testCandidateFilteringKeepsSiblingBasenameCompetitors() throws {
        let chosen = try write("a/report.fltest", "selected report")
        let sibling = try write("b/report.fltest", "other report")
        let localNote = try write("a/note.md", "[[report.fltest]]")
        let siblingNote = try write("b/note.md", "[[report.fltest]]")
        let explicit = try write("explicit.md", "[[a/report.fltest]]")
        let alternateSpelling = try write("legacy\\report.fltest", "normalized separator")
        let separatorLink = try write("separator.md", "[[legacy/report.fltest]]")
        for i in 0..<80 { try write("unrelated/folder\(i)/archive-\(i).fltest", "irrelevant") }
        try store.reindex()
        XCTAssertEqual(Set(try store.relatedFiles(to: chosen).backlinks.map(\.file)), [localNote, explicit])
        XCTAssertEqual(try store.relatedFiles(to: sibling).backlinks.map(\.file), [siblingNote])
        XCTAssertEqual(try store.relatedFiles(to: siblingNote).related.map(\.file), [sibling])
        XCTAssertEqual(try store.relatedFiles(to: separatorLink).related.map(\.file), [alternateSpelling])
    }

    func testCandidateFilteringPreservesCurrentNamesOverHistoricalAliases() throws {
        let moved = try write("new/current.fltest", "renamed")
        let currentName = try write("report.fltest", "new report at old name")
        let historicalLink = try write("historical.md", "[[old/report.fltest#page 4]]")
        let basenameLink = try write("basename.md", "[[report.fltest]]")
        try PathAliases(vault: vault).reconcile(oldPath: "old/report.fltest", newPath: moved.relativePath)
        for i in 0..<40 { try write("unrelated/data-\(i).fltest", "irrelevant") }
        try store.reindex()
        XCTAssertEqual(try store.relatedFiles(to: moved).backlinks.map(\.file), [historicalLink])
        XCTAssertEqual(try store.relatedFiles(to: currentName).backlinks.map(\.file), [basenameLink])
        let destination = try store.relatedFiles(to: historicalLink).related.first
        XCTAssertEqual(destination?.file, moved)
        XCTAssertEqual(destination?.anchor, FileAnchor(kind: .page, value: "4"))
    }
}
