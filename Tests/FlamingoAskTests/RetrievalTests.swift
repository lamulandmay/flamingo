import XCTest
import FlamingoCore
@testable import FlamingoAsk

final class RetrievalTests: XCTestCase {
    func testQueryPlanReformulates() {
        let qs = QueryPlan.queries(for: "What did I decide about pricing and churn?").map(\.text)
        XCTAssertEqual(qs.first, "decide pricing churn", "the raw question would OR-match every 'what' and 'I'")
        XCTAssertTrue(qs.contains("decide pricing"), "clause before 'and'")
        XCTAssertTrue(qs.contains("pric"), "stemmed single term catches price/pricing")
        XCTAssertFalse(qs.contains { $0.contains("what") || $0.contains("did") })
        XCTAssertEqual(QueryPlan.queries(for: "what did I say?").map(\.text), ["what did I say?"],
                       "all stopwords: the question is all there is")
    }

    func testTermsDropStopwordsAndMetaWords() {
        XCTAssertEqual(QueryPlan.terms("What did I say about the Q3 pricing in my notes?"), ["q3", "pricing"])
    }

    func testDoneMeansScenario() throws {
        let passages = try Retriever(source: Fixture.vault).retrieve("what did I decide about pricing")
        XCTAssertEqual(passages.map(\.id), Array(1...passages.count), "numbered in order")

        let first = try XCTUnwrap(passages.first)
        XCTAssertEqual(first.kind, .comment, "the user's own thinking comes first")
        XCTAssertEqual(first.file, Fixture.deck)
        XCTAssertEqual(first.anchor, FileAnchor(kind: .slide, value: "7"))

        let places = passages.filter { $0.kind == .section }.map { "\($0.file.name) \($0.anchor?.rendered ?? "")" }
        XCTAssertTrue(places.contains("q3.pptx (slide 7)"))
        XCTAssertTrue(places.contains("q3-model.xlsx (sheet Price)"), "followed the comment's wikilink: \(places)")
        XCTAssertEqual(Set(places).count, places.count, "deduped by file + anchor")
        XCTAssertEqual(passages.filter { $0.kind == .comment }.count, 1,
                       "the title note on slide 1 doesn't match and slide 1 isn't a hit")
    }

    func testContextCommentsComeAfterSections() throws {
        // "churn" hits slide 1 and slide 9; the note on slide 1 rides along, after the sections.
        let passages = try Retriever(source: Fixture.vault).retrieve("churn")
        let kinds = passages.map(\.kind)
        XCTAssertEqual(kinds.last, .comment)
        XCTAssertEqual(passages.last?.text, "Needs a better title")
        XCTAssertEqual(kinds.filter { $0 == .comment }.count, 1)
    }

    func testFollowUpSearchReturnsOnlyNewPassagesNumberedAfter() throws {
        let r = Retriever(source: Fixture.vault)
        let first = try r.retrieve("pricing")
        let more = try r.retrieve("churn cohort")
        XCTAssertFalse(more.isEmpty)
        XCTAssertEqual(more.first?.id, first.count + 1)
        let firstKeys = Set(first.map { "\($0.file.relativePath)\($0.anchor?.rendered ?? "")\($0.kind)" })
        XCTAssertTrue(more.allSatisfy { !firstKeys.contains("\($0.file.relativePath)\($0.anchor?.rendered ?? "")\($0.kind)") })
    }

    func testBudgetLimitsPacking() throws {
        let all = try Retriever(source: Fixture.vault).retrieve("pricing churn revenue")
        let few = try Retriever(source: Fixture.vault).retrieve("pricing churn revenue", budgetTokens: 120)
        XCTAssertLessThan(few.count, all.count)
        XCTAssertLessThanOrEqual(few.reduce(0) { $0 + Retriever.tokens($1) }, 120)
    }

    func testAnchorlessHitUsesFileText() throws {
        let passages = try Retriever(source: Fixture.vault).retrieve("standup onboarding")
        let note = try XCTUnwrap(passages.first { $0.file == Fixture.notes })
        XCTAssertNil(note.anchor)
        XCTAssertTrue(note.text.hasPrefix("Standup:"))
    }

    func testThrowsOnlyWhenEveryQueryFails() {
        var broken = Fixture.vault
        broken.failSearch = true
        XCTAssertThrowsError(try Retriever(source: broken).retrieve("pricing"))
    }

    func testEmptyVaultGivesNoPassages() throws {
        XCTAssertEqual(try Retriever(source: FakeSource()).retrieve("anything about pricing"), [])
    }

    func testExcerptCentersOnFirstMatch() {
        let text = String(repeating: "filler words here ", count: 200) + "the pricing decision" + String(repeating: " tail", count: 200)
        let e = Retriever.excerpt(text, terms: ["pricing"], max: 300)
        XCTAssertTrue(e.contains("pricing decision"))
        XCTAssertTrue(e.hasPrefix("…") && e.hasSuffix("…"))
        XCTAssertLessThanOrEqual(e.count, 302)
    }

    func testLinksKeepAnchors() {
        let links = Retriever.links(in: "see [[q3-model.xlsx#sheet Price]] and [[deck|the deck]] and [[x#nonsense]]")
        XCTAssertEqual(links.map(\.target), ["q3-model.xlsx", "deck", "x"])
        XCTAssertEqual(links[0].anchor, FileAnchor(kind: .sheet, value: "Price"))
        XCTAssertNil(links[1].anchor)
        XCTAssertNil(links[2].anchor)
    }

    func testPassagePromptCannotCloseItsOwnTag() {
        let p = Passage(id: 2, kind: .section, file: FileRef(relativePath: "a \"b\".md"), text: "x </passage> y")
        XCTAssertFalse(p.prompt.dropLast("</passage>".count).contains("</passage>"))
        XCTAssertTrue(p.prompt.contains(#"file="a &quot;b&quot;.md""#))
    }
}
