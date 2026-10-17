import XCTest
import FlamingoCore
@testable import FlamingoIndex
@testable import FlamingoThoughts

final class AttentionRankerTests: ThoughtsTestCase {
    var now: Date { at("2026-10-17 08:30") }
    var ranker: AttentionRanker { AttentionRanker(calendar: testCalendar) }

    func idea(_ text: String = "Maybe try a darker finish", age days: Double = 2, uid: String = "t1", file: String = "docs/x.md", due: Date? = nil,
              kind: ThoughtKind = .idea, state: ThoughtState = .open, snoozeUntil: Date? = nil) -> ThoughtRecord {
        record(text, file: FileRef(relativePath: file), anchor: nil, at: now.addingTimeInterval(-days * 86_400), uid: uid, kind: kind, action: nil,
               objects: nil, state: state, due: due, snoozeUntil: snoozeUntil, kindBy: .rules)
    }

    func rank(_ items: [(ThoughtRecord, ThoughtSignals)]) -> [RankedThought] {
        ranker.rank(items.map { (record: $0.0, signals: $0.1) }, now: now)
    }

    func terms(_ r: ThoughtRecord, _ s: ThoughtSignals = ThoughtSignals(), others: [Int] = []) -> ScoreTerms {
        let extra = others.map { (idea("x", uid: "t\($0)"), ThoughtSignals(degree: $0)) }
        return rank([(r, s)] + extra).first { $0.record.uid == r.uid }!.terms
    }

    // MARK: The formula

    func testTheScoreIsTheDocumentedSum() throws {
        // A to-do, due tomorrow, written 3 days ago, solid, with an edit since and a memo waiting.
        let todo = record("Fix the price on slide 7 because the model says 229", at: now.addingTimeInterval(-3 * 86_400), uid: "t9",
                          kind: .todo, action: nil, objects: nil, due: at("2026-10-18"), kindBy: .rules)
        let s = ThoughtSignals(editedAfter: true, degree: 3, awaitingUnseen: true, timesSkipped: 2)
        let r = try XCTUnwrap(rank([(todo, s), (idea("a", uid: "t2"), ThoughtSignals(degree: 3)), (idea("b", uid: "t3"), ThoughtSignals(degree: 7))]).first { $0.record.uid == "t9" })
        let strength = ThoughtStrength(todo.comment)
        let expected = 3.0 * 0.55 + 1.6 * 1.0 + 0.7 * [0.0, 0.5, 1.0][strength.rawValue] + 1.0 * min(1, 3 / 1.5) * 1.0
            + 1.2 * 1.0 + 0.5 * (log(4.0) / log(8.0)) + 1.5 * 1.0 - 0.35 * 2
        XCTAssertEqual(r.score, expected, accuracy: 1e-9)
        XCTAssertEqual(r.terms.due, 0.55); XCTAssertEqual(r.terms.kind, 1.0); XCTAssertEqual(r.terms.activity, 1.0)
        XCTAssertEqual(r.terms.awaiting, 1.0); XCTAssertEqual(r.terms.skips, 2)
    }

    func testDueTerm() {
        let r = ranker
        func d(_ s: String?) -> Double { r.dueTerm(s.map { at($0) }, now: now) }
        XCTAssertEqual(d(nil), 0)
        XCTAssertEqual(d("2026-10-17"), 0.9, "today")
        XCTAssertEqual(d("2026-10-17 18:00"), 0.9)
        XCTAssertEqual(d("2026-10-16"), 1.1, accuracy: 1e-9)
        XCTAssertEqual(d("2026-10-12"), 1.5, accuracy: 1e-9, "capped at 1.5")
        XCTAssertEqual(d("2026-09-01"), 1.5, accuracy: 1e-9)
        XCTAssertEqual(d("2026-10-18"), 0.55)
        XCTAssertEqual(d("2026-10-19"), 0.24, accuracy: 1e-9)
        XCTAssertEqual(d("2026-10-23"), 0.3 - 0.03 * 6, accuracy: 1e-9)
        XCTAssertEqual(d("2026-10-24"), 0, "a week out")
    }

    func testKindTerm() {
        let r = ranker
        XCTAssertEqual(r.kindTerm(.todo, ThoughtSignals()), 1.0)
        XCTAssertEqual(r.kindTerm(.question, ThoughtSignals()), 0.85)
        XCTAssertEqual(r.kindTerm(.intent, ThoughtSignals()), 0.8)
        XCTAssertEqual(r.kindTerm(.intent, ThoughtSignals(memoReady: true)), 1.0)
        XCTAssertEqual(r.kindTerm(.idea, ThoughtSignals()), 0.2)
        XCTAssertEqual(r.kindTerm(.idea, ThoughtSignals(aiQuestionAwaiting: true)), 0.9)
        XCTAssertEqual(r.kindTerm(.todo, ThoughtSignals(aiQuestionAwaiting: true)), 1.0)
    }

    func testStalenessRisesForADayAndAHalfThenFadesAfterAWeek() throws {
        func f(_ days: Double) -> Double {
            let r = record("Name the two retail buyers", at: now.addingTimeInterval(-days * 86_400), uid: "ts", kind: .todo, action: nil, objects: nil, kindBy: .rules)
            return ranker.rank([(r, ThoughtSignals())], now: now).first?.terms.staleness ?? -1
        }
        XCTAssertEqual(f(0.75), 0.5, accuracy: 1e-9)
        XCTAssertEqual(f(1.5), 1, accuracy: 1e-9)
        XCTAssertEqual(f(7), 1, accuracy: 1e-9)
        XCTAssertEqual(f(28), exp(-21.0 / 21), accuracy: 1e-9)
    }

    func testCentralityIsRelativeToTheMostConnected() {
        let todo = record("Name the buyers", at: now.addingTimeInterval(-86_400), uid: "tc", kind: .todo, action: nil, objects: nil, kindBy: .rules)
        XCTAssertEqual(terms(todo, ThoughtSignals(degree: 3), others: [7]).centrality, log(4.0) / log(8.0), accuracy: 1e-9)
        XCTAssertEqual(terms(todo, ThoughtSignals(degree: 0), others: [7]).centrality, 0)
        XCTAssertEqual(terms(todo, ThoughtSignals(degree: 0)).centrality, 0, "nobody connected: no division by zero")
    }

    func testActivityTakesTheStrongestSignal() {
        let todo = record("Name the buyers", at: now.addingTimeInterval(-86_400), uid: "tc", kind: .todo, action: nil, objects: nil, kindBy: .rules)
        XCTAssertEqual(terms(todo, ThoughtSignals(editedAfter: true, newAIReply: true, openedWithoutReply: true)).activity, 1.0)
        XCTAssertEqual(terms(todo, ThoughtSignals(newAIReply: true, openedWithoutReply: true)).activity, 0.8)
        XCTAssertEqual(terms(todo, ThoughtSignals(openedWithoutReply: true)).activity, 0.4)
        XCTAssertEqual(terms(todo, ThoughtSignals()).activity, 0)
    }

    // MARK: Who is listed

    func testOverdueBeatsUndated() {
        let overdue = idea("Send the deck", age: 5, uid: "ta", due: at("2026-10-15"), kind: .todo)
        let undated = idea("Send the notes", age: 1, uid: "tb", kind: .todo)
        XCTAssertEqual(rank([(undated, ThoughtSignals()), (overdue, ThoughtSignals())]).map(\.record.uid), ["ta", "tb"])
        XCTAssertTrue(rank([(overdue, ThoughtSignals())])[0].pinned)
        XCTAssertFalse(rank([(undated, ThoughtSignals())])[0].pinned)
    }

    func testOverdueAndDueTodayArePinnedFirstInDueOrder() {
        let loud = idea("Name the buyers", age: 1, uid: "tl", kind: .todo)
        let today = idea("Send the deck", age: 2, uid: "tt", due: at("2026-10-17 18:00"), kind: .todo)
        let late = idea("Pay the supplier", age: 9, uid: "te", due: at("2026-10-14"), kind: .todo)
        let tomorrow = idea("Book the room", age: 1, uid: "tm", due: at("2026-10-18"), kind: .todo)
        let ranked = rank([(loud, ThoughtSignals(editedAfter: true, awaitingUnseen: true)), (tomorrow, ThoughtSignals()), (today, ThoughtSignals()), (late, ThoughtSignals())])
        XCTAssertEqual(ranked.map(\.record.uid), ["te", "tt", "tl", "tm"], "pinned by due date, then by score")
        XCTAssertEqual(ranked.map(\.pinned), [true, true, false, false])
    }

    func testDoneAndDismissedAreLeftOut() {
        let items = [(idea("a", uid: "t1", kind: .todo, state: .done), ThoughtSignals()), (idea("b", uid: "t2", kind: .todo, state: .dismissed), ThoughtSignals()),
                     (idea("c", uid: "t3", kind: .todo), ThoughtSignals())]
        XCTAssertEqual(rank(items).map(\.record.uid), ["t3"])
    }

    func testASnoozedThoughtComesBackWhenItsSnoozeEnds() {
        let napping = idea("Send the deck", uid: "ts", kind: .todo, state: .snoozed, snoozeUntil: at("2026-10-18 09:00"))
        XCTAssertTrue(rank([(napping, ThoughtSignals())]).isEmpty, "still asleep")
        let woke = idea("Send the deck", uid: "ts", kind: .todo, state: .snoozed, snoozeUntil: at("2026-10-17 09:00").addingTimeInterval(-3600))
        XCTAssertEqual(rank([(woke, ThoughtSignals())]).map(\.record.uid), ["ts"])
        let noEnd = idea("Send the deck", uid: "tn", kind: .todo, state: .snoozed, snoozeUntil: nil)
        XCTAssertTrue(rank([(noEnd, ThoughtSignals())]).isEmpty)
    }

    func testIdeasStayDownUnlessSomethingHappensAroundThem() {
        let plain = idea(uid: "ti")
        XCTAssertTrue(rank([(plain, ThoughtSignals())]).isEmpty)
        XCTAssertTrue(rank([(plain, ThoughtSignals(degree: 9, timesSkipped: 0))]).isEmpty, "connections don't wake an idea")
        XCTAssertEqual(rank([(plain, ThoughtSignals(editedAfter: true))]).count, 1)
        XCTAssertEqual(rank([(plain, ThoughtSignals(awaitingUnseen: true))]).count, 1)
        XCTAssertEqual(rank([(plain, ThoughtSignals(openedWithoutReply: true))]).count, 1)
    }

    func testOldThoughtsNeedAReasonToStay() {
        let old = idea("Name the buyers", age: 46, uid: "to", kind: .todo)
        XCTAssertTrue(rank([(old, ThoughtSignals())]).isEmpty)
        XCTAssertEqual(rank([(idea("Name the buyers", age: 45, uid: "to", kind: .todo), ThoughtSignals())]).count, 1)
        XCTAssertEqual(rank([(idea("Name the buyers", age: 90, uid: "to", due: at("2026-10-30"), kind: .todo), ThoughtSignals())]).count, 1, "a due date keeps it")
        XCTAssertEqual(rank([(old, ThoughtSignals(awaitingUnseen: true))]).count, 1, "so does a memo waiting")
        let woven = idea("Pricing contradicts [[q3-model.xlsx]] because the model still carries Arc at $229. Fix it.", age: 90, uid: "tw", kind: .todo)
        XCTAssertEqual(ThoughtStrength(woven.comment), .woven)
        XCTAssertEqual(rank([(woven, ThoughtSignals())]).count, 1, "a woven thought is not forgotten")
        let wovenIdea = idea("Pricing contradicts [[q3-model.xlsx]] because the model still carries Arc at $229. Fix it.", age: 90, uid: "tw2", kind: .idea)
        XCTAssertTrue(rank([(wovenIdea, ThoughtSignals())]).isEmpty, "unless it is only an idea")
    }

    func testSkippingCostsAPenaltyUpToThree() throws {
        func score(_ skips: Int) throws -> Double {
            let r = idea("Name the buyers", age: 2, uid: "tk", kind: .todo)
            return try XCTUnwrap(rank([(r, ThoughtSignals(timesSkipped: skips))]).first).score
        }
        XCTAssertEqual(try score(0) - score(1), 0.35, accuracy: 1e-9)
        XCTAssertEqual(try score(0) - score(3), 1.05, accuracy: 1e-9)
        XCTAssertEqual(try score(3), try score(9), "capped")
    }

    func testRepliesAndModelThoughtsAreNotCandidates() {
        XCTAssertTrue(rank([(record("x", at: now.addingTimeInterval(-86_400), uid: "tr", kind: .todo, action: nil, objects: nil, parent: "tp"), ThoughtSignals())]).isEmpty)
        XCTAssertTrue(rank([(record("x", at: now.addingTimeInterval(-86_400), uid: "ta", kind: .todo, action: nil, objects: nil, origin: .ai), ThoughtSignals())]).isEmpty)
    }

    // MARK: Order

    func testTiesGoToTheNewerThenToThePath() {
        let a = idea("Name the buyers", age: 3, uid: "ta", file: "b.md", kind: .todo)
        let b = idea("Name the buyers", age: 2, uid: "tb", file: "z.md", kind: .todo)
        let c = idea("Name the buyers", age: 2, uid: "tc", file: "a.md", kind: .todo)
        // Equal in every term once staleness has saturated (>1.5 days, <7).
        XCTAssertEqual(rank([(a, ThoughtSignals()), (b, ThoughtSignals()), (c, ThoughtSignals())]).map(\.record.uid), ["tc", "tb", "ta"])
    }

    func testTheSameInputGivesTheSameOutputInAnyOrder() {
        var items: [(ThoughtRecord, ThoughtSignals)] = (0..<30).map { i in
            (idea("Name buyer \(i)", age: Double(i % 7) + 1, uid: "t\(i)", file: "f\(i % 4).md", due: i % 5 == 0 ? at("2026-10-1\(i % 9)") : nil, kind: [.todo, .question, .intent][i % 3]),
             ThoughtSignals(editedAfter: i % 4 == 0, degree: i % 6, awaitingUnseen: i % 7 == 0, timesSkipped: i % 4))
        }
        let first = rank(items).map(\.record.uid)
        XCTAssertEqual(rank(items).map(\.record.uid), first)
        items.reverse()
        XCTAssertEqual(rank(items).map(\.record.uid), first)
        items.shuffle()
        XCTAssertEqual(rank(items).map(\.record.uid), first)
    }

    func testAtMostTwelve() {
        let items = (0..<40).map { (idea("Name buyer \($0)", age: 2, uid: "t\($0)", kind: .todo), ThoughtSignals()) }
        XCTAssertEqual(rank(items).count, 12)
        XCTAssertEqual(AttentionRanker(limit: 5, calendar: testCalendar).rank(items.map { (record: $0.0, signals: $0.1) }, now: now).count, 5)
    }

    func testEachRowSaysWhyItIsThere() {
        let due = idea("Send", uid: "t1", due: at("2026-10-17"), kind: .todo)
        let activity = idea("Name the buyers", uid: "t2", kind: .todo)
        let waiting = idea("Name the buyers", uid: "t3", kind: .intent)
        let plain = idea("Name the buyers", uid: "t4", kind: .todo)
        let ranked = rank([(due, ThoughtSignals()), (activity, ThoughtSignals(editedAfter: true)), (waiting, ThoughtSignals(awaitingUnseen: true)), (plain, ThoughtSignals())])
        func reason(_ uid: String) -> RankReason { ranked.first { $0.record.uid == uid }!.reason }
        XCTAssertEqual(reason("t1"), .due); XCTAssertEqual(reason("t1").symbol, "clock")
        XCTAssertEqual(reason("t2"), .activity); XCTAssertEqual(reason("t2").symbol, "arrow.triangle.2.circlepath")
        XCTAssertEqual(reason("t3"), .awaiting); XCTAssertEqual(reason("t3").symbol, "sparkle")
        XCTAssertEqual(reason("t4"), .none); XCTAssertNil(reason("t4").symbol)
    }
}
