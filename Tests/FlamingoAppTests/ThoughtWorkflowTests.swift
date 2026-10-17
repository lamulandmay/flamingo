import XCTest
@testable import Flamingo
import FlamingoCore

final class ThoughtWorkflowTests: XCTestCase {
    func testThoughtLinkRoundTrip() {
        let link = ThoughtLink.make(file: FileRef(relativePath: "finance/q3-model.xlsx"), uid: "t3k9x2m4q")
        XCTAssertEqual(link, "[[finance/q3-model.xlsx#^t3k9x2m4q]]")
        let parsed = ThoughtLink.parse(link)
        XCTAssertEqual(parsed?.target, "finance/q3-model.xlsx")
        XCTAssertEqual(parsed?.uid, "t3k9x2m4q")
    }

    func testThoughtLinkAcceptsBareAndAliasedForms() {
        XCTAssertEqual(ThoughtLink.parse("q3.pptx#^tabc123456")?.uid, "tabc123456")
        XCTAssertEqual(ThoughtLink.parse("#^tabc123456")?.target, "")
        XCTAssertEqual(ThoughtLink.parse("[[q3.pptx#^tabc123456|that thought]]")?.uid, "tabc123456")
    }

    func testOrdinaryLinksAreNotThoughtLinks() {
        XCTAssertNil(ThoughtLink.parse("q3.pptx#slide 2"))
        XCTAssertNil(ThoughtLink.parse("q3.pptx"))
        XCTAssertNil(ThoughtLink.parse("q3.pptx#^"))
        XCTAssertNil(ThoughtLink.parse("q3.pptx#^not a uid"))
    }

    func testMentionsAskTheAssistantButOnlyForPeople() {
        let ask = Comment(text: "@ai what price does the model use?")
        XCTAssertTrue(ThoughtTriggers.asksAssistant(ask))
        XCTAssertEqual(ThoughtTriggers.question(of: ask), "what price does the model use?")
        XCTAssertFalse(ThoughtTriggers.shouldUnderstand(ask))
        let flamingo = Comment(text: "hey @flamingo, summarize this")
        XCTAssertTrue(ThoughtTriggers.asksAssistant(flamingo))
        let answer = Comment(text: "@ai quoted back", provenance: CommentProvenance(origin: .ai))
        XCTAssertFalse(ThoughtTriggers.asksAssistant(answer))
        XCTAssertFalse(ThoughtTriggers.shouldUnderstand(answer))
        XCTAssertFalse(ThoughtTriggers.asksAssistant(Comment(text: "@claude what is this")))
        XCTAssertTrue(ThoughtTriggers.shouldUnderstand(Comment(text: "review conflict with [[q3-model.xlsx]]")))
        XCTAssertFalse(ThoughtTriggers.shouldUnderstand(Comment(text: "   ")))
    }

    func testBackfillBudgetResetsEachDay() {
        let cal = Calendar(identifier: .gregorian)
        let day1 = cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 9))!
        let day2 = cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 9))!
        var budget = DailyBudget(limit: 3)
        XCTAssertEqual(budget.remaining(on: day1, calendar: cal), 3)
        XCTAssertTrue(budget.take(on: day1, calendar: cal))
        XCTAssertTrue(budget.take(on: day1, calendar: cal))
        XCTAssertTrue(budget.take(on: day1, calendar: cal))
        XCTAssertFalse(budget.take(on: day1, calendar: cal))
        XCTAssertEqual(budget.remaining(on: day1, calendar: cal), 0)
        XCTAssertEqual(budget.remaining(on: day2, calendar: cal), 3)
        XCTAssertTrue(budget.take(on: day2, calendar: cal))
        XCTAssertEqual(budget.used, 1)
    }

    func testThreadMembersAndHistory() {
        var root = Comment(timestamp: Date(timeIntervalSince1970: 100), text: "@ai first question").stamped()
        root.meta?.uid = "troot00001"
        var answer = Comment(timestamp: Date(timeIntervalSince1970: 110), text: "first answer", provenance: CommentProvenance(origin: .ai)).stamped()
        answer.meta?.uid = "tanswer001"; answer.meta?.parent = "troot00001"
        var follow = Comment(timestamp: Date(timeIntervalSince1970: 120), text: "@ai and the deck?").stamped()
        follow.meta?.uid = "tfollow001"; follow.meta?.parent = "tanswer001"
        let other = Comment(timestamp: Date(timeIntervalSince1970: 105), text: "unrelated").stamped()

        let members = ThoughtThread.members(of: follow, in: [other, follow, answer, root])
        XCTAssertEqual(members.map(\.text), ["@ai first question", "first answer", "@ai and the deck?"])
        let history = ThoughtThread.history(of: members, before: follow)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].question, "first question")
        XCTAssertEqual(history[0].answer, "first answer")
        XCTAssertTrue(history[0].thoughtDerived)
    }

    func testQAClockParsing() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let d = QAClock.parse("2026-10-17T02:00", calendar: cal)
        XCTAssertEqual(d, cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 2)))
        XCTAssertEqual(QAClock.parse("2026-10-17 08:30", calendar: cal), cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 8, minute: 30)))
        XCTAssertNil(QAClock.parse("tomorrow"))
    }

    func testFirstLineSkipsQuotes() {
        XCTAssertEqual(ThoughtLines.first(of: "> selected text\n\nmy thought"), "my thought")
        XCTAssertEqual(ThoughtLines.first(of: "one\ntwo"), "one")
    }
}
