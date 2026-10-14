import XCTest
import FlamingoCore
@testable import FlamingoAsk

final class RetrievalTests: XCTestCase {
    func testQueryPlanReformulates() {
        let qs = QueryPlan.queries(for: "What did I decide about pricing and churn?").map(\.text)
        XCTAssertEqual(qs.first, "What did I decide about pricing and churn?")
        XCTAssertTrue(qs.contains("decide pricing churn"))
        XCTAssertTrue(qs.contains("decide pricing"), "clause before 'and'")
        XCTAssertTrue(qs.contains("pric"), "stemmed single term catches price/pricing")
        XCTAssertFalse(qs.contains { $0 == "what" || $0 == "did" })
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
        XCTAssertFalse(passages.contains { $0.kind == .section && $0.text.contains("Decided: keep $49") },
                       "a comment hit from the index isn't repeated as a section")
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
