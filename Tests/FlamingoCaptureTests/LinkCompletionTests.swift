import XCTest
import FlamingoCore
@testable import FlamingoCapture

final class LinkCompletionTests: XCTestCase {
    private func query(_ s: String) -> LinkQuery? {
        // `|` marks the cursor.
        let ns = s as NSString
        let cursor = ns.range(of: "|").location
        return LinkQuery.active(in: ns.replacingCharacters(in: NSRange(location: cursor, length: 1), with: "") as NSString,
                                cursor: cursor)
    }

    func testQueryDetection() {
        XCTAssertEqual(query("see [[q3|")?.text, "q3")
        XCTAssertEqual(query("see [[q3|")?.start, 6)
        XCTAssertEqual(query("[[|")?.text, "")
        XCTAssertEqual(query("a [[b]] and [[Q3 R|")?.text, "Q3 R")
        XCTAssertEqual(query("[[q3|]]")?.text, "q3")
        XCTAssertNil(query("see [[q3]] |"))
        XCTAssertNil(query("see q3|"))
        XCTAssertNil(query("[[q3.pptx#sli|"))
        XCTAssertNil(query("[[q3.pptx|al|"))
        XCTAssertNil(query("[[q3\nmore|"))
        XCTAssertNil(query("[[q|3.pptx]]"), "mid-word edits don't complete")
        XCTAssertEqual(query("line one\n[[pl|")?.text, "pl")
        XCTAssertEqual(query("日本語 [[資料|")?.text, "資料")
        XCTAssertEqual(query("😀 [[x|")?.start, ("😀 [[" as NSString).length)
    }

    private func insert(_ s: String, _ name: String, suffix: String? = nil) -> String {
        let ns = s as NSString
        let cursor = ns.range(of: "|").location
        let text = ns.replacingCharacters(in: NSRange(location: cursor, length: 1), with: "") as NSString
        let q = LinkQuery.active(in: text, cursor: cursor)!
        let c = LinkCandidate(ref: FileRef(relativePath: name), insertText: name)
        let edit = LinkInsertion.make(c, query: q, in: text, cursor: cursor, suffix: suffix)
        let out = text.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        return out.replacingCharacters(in: NSRange(location: edit.cursor, length: 0), with: "|")
    }

    func testInsertion() {
        XCTAssertEqual(insert("see [[q3|", "q3.pptx"), "see [[q3.pptx]]|")
        XCTAssertEqual(insert("see [[q3| more", "q3.pptx"), "see [[q3.pptx]]| more")
        XCTAssertEqual(insert("see [[q3|]]", "q3.pptx"), "see [[q3.pptx]]|")
        XCTAssertEqual(insert("see [[q3|", "q3.pptx", suffix: "#"), "see [[q3.pptx#|]]")
        XCTAssertEqual(insert("see [[q3|]]", "q3.pptx", suffix: "|"), "see [[q3.pptx||]]")
        XCTAssertEqual(insert("[[|", "decks/q3.pptx"), "[[decks/q3.pptx]]|")
    }

    private let files = ["decks/q3.pptx", "decks/old/q3.pptx", "models/q3-model.xlsx", "report.pdf",
                         "notes/plan.md", "media/Q3 Review.mov", "code/QuarterlyModel.swift", "notes/planning-2026.md"]
        .map(FileRef.init(relativePath:))

    func testUniqueNamesInsertBasenameDuplicatesInsertPath() {
        let m = LinkMatcher(candidates: files)
        let all = m.matches("q3", limit: 20)
        XCTAssertEqual(all.first { $0.ref.relativePath == "models/q3-model.xlsx" }?.insertText, "q3-model.xlsx")
        XCTAssertEqual(all.first { $0.ref.relativePath == "decks/q3.pptx" }?.insertText, "decks/q3.pptx")
        XCTAssertEqual(all.first { $0.ref.relativePath == "decks/old/q3.pptx" }?.insertText, "decks/old/q3.pptx")
    }

    func testRanking() {
        let m = LinkMatcher(candidates: files)
        XCTAssertEqual(m.matches("q3").first?.ref.relativePath, "decks/q3.pptx", "exact prefix, shallowest path")
        XCTAssertEqual(m.matches("plan").first?.ref.relativePath, "notes/plan.md", "shorter name wins a tie")
        let camel = LinkMatcher(candidates: ["summary.md", "SuperModel.swift", "notes.sm"].map(FileRef.init(relativePath:)))
        XCTAssertEqual(camel.matches("sm").first?.ref.relativePath, "SuperModel.swift",
                       "camelCase word starts beat scattered letters and extension hits")
        XCTAssertEqual(m.matches("rep").first?.ref.relativePath, "report.pdf")
        XCTAssertEqual(m.matches("REVIEW").first?.ref.relativePath, "media/Q3 Review.mov", "case-insensitive")
        XCTAssertTrue(m.matches("zzz").isEmpty)
        XCTAssertEqual(m.matches("old/q3").first?.ref.relativePath, "decks/old/q3.pptx", "a slash matches paths")
        XCTAssertLessThanOrEqual(m.matches("", limit: 3).count, 3)
    }

    func testRecentFilesLeadEmptyQueryAndBreakTies() {
        let recent = [FileRef(relativePath: "report.pdf"), FileRef(relativePath: "notes/planning-2026.md")]
        let m = LinkMatcher(candidates: files, recent: recent)
        XCTAssertEqual(m.matches("").prefix(2).map(\.ref.relativePath), ["report.pdf", "notes/planning-2026.md"])
        XCTAssertEqual(m.matches("plan").first?.ref.relativePath, "notes/planning-2026.md")
    }

    func testSubstringBeatsScattered() {
        let a = FuzzyMatch.score(FuzzyMatch.fold("model"), FuzzyMatch.fold("q3-model.xlsx"), original: Array("q3-model.xlsx"))!
        let b = FuzzyMatch.score(FuzzyMatch.fold("model"), FuzzyMatch.fold("my-old-elephant"), original: Array("my-old-elephant"))
        XCTAssertNotNil(b)
        XCTAssertGreaterThan(a, b!)
        XCTAssertNil(FuzzyMatch.score(FuzzyMatch.fold("xyz"), FuzzyMatch.fold("abc"), original: Array("abc")))
    }

    func testWikilinkRanges() {
        let s = "see [[a.pptx#slide 2]] and [[b|bee]] not [[c"
        let ranges = WikilinkRanges.find(in: s).map { (s as NSString).substring(with: $0) }
        XCTAssertEqual(ranges, ["[[a.pptx#slide 2]]", "[[b|bee]]"])
    }

    func testInboxTarget() {
        let v = Vault(root: URL(fileURLWithPath: "/tmp/v"))
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 14; c.hour = 9
        let t = CaptureController.Target.inbox(in: v, on: Calendar.current.date(from: c)!)
        XCTAssertEqual(t.file.relativePath, "_inbox/2026-10-14")
        XCTAssertEqual(SidecarStore(vault: v).sidecarURL(for: t.file).path, "/tmp/v/.flamingo/notes/_inbox/2026-10-14.md")
    }

    @MainActor
    func testFooterNamesFileAndAnchor() {
        let p = CommentPanel(target: FileRef(relativePath: "decks/q3.pptx"), anchor: FileAnchor(kind: .slide, value: "7"),
                             onSubmit: { _ in }, onCancel: {})
        XCTAssertEqual(p.footer, "q3.pptx · slide 7")
        XCTAssertEqual(CommentPanel(target: FileRef(relativePath: "a.md"), onSubmit: { _ in }, onCancel: {}).footer, "a.md")
    }
}
