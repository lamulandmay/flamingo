import XCTest
@testable import FlamingoCapture
import FlamingoCore
import FlamingoDesign

final class RailThreadsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private func thought(_ text: String, uid: String? = nil, parent: String? = nil, at minutes: Double) -> Comment {
        var c = Comment(timestamp: t0.addingTimeInterval(minutes * 60), text: text)
        if uid != nil || parent != nil { c.meta = ThoughtMeta(uid: uid, parent: parent) }
        return c
    }

    private func texts(_ comments: [Comment]) -> [String] { comments.map(\.text) }

    func testRootsInTimeOrderEachFollowedByItsReplies() {
        let a = thought("a", uid: "ta", at: 0)
        let b = thought("b", uid: "tb", at: 5)
        let a1 = thought("a1", uid: "ta1", parent: "ta", at: 10)
        let b1 = thought("b1", parent: "tb", at: 11)
        let a2 = thought("a2", parent: "ta", at: 20)
        let threads = RailThreads.build([a2, b1, b, a1, a])
        XCTAssertEqual(threads.map { $0.root.text }, ["a", "b"])
        XCTAssertEqual(texts(threads[0].replies), ["a1", "a2"])
        XCTAssertEqual(texts(threads[1].replies), ["b1"])
        XCTAssertEqual(texts(RailThreads.order([a2, b1, b, a1, a])), ["a", "a1", "a2", "b", "b1"])
    }

    func testRepliesDeeperThanTwoLevelsFlattenUnderTheRoot() {
        let root = thought("root", uid: "t1", at: 0)
        let r1 = thought("r1", uid: "t2", parent: "t1", at: 1)
        let r2 = thought("r2", uid: "t3", parent: "t2", at: 2)
        let r3 = thought("r3", parent: "t3", at: 3)
        let other = thought("other", at: 1.5)
        let threads = RailThreads.build([r3, r2, other, r1, root])
        XCTAssertEqual(threads.map { $0.root.text }, ["root", "other"])
        XCTAssertEqual(texts(threads[0].replies), ["r1", "r2", "r3"])
        XCTAssertTrue(threads[1].replies.isEmpty)
    }

    func testOrphanReplyShowsAsARootAndKeepsItsOwnReplies() {
        let orphan = thought("orphan", uid: "t2", parent: "tgone", at: 5)
        let child = thought("child", parent: "t2", at: 6)
        let plain = thought("plain", at: 1)
        let threads = RailThreads.build([child, orphan, plain])
        XCTAssertEqual(threads.map { $0.root.text }, ["plain", "orphan"])
        XCTAssertEqual(texts(threads[1].replies), ["child"])
    }

    func testEqualTimestampsKeepGivenOrderAndNothingIsLost() {
        let a = thought("a", at: 0), b = thought("b", at: 0), c = thought("c", at: 0)
        XCTAssertEqual(texts(RailThreads.order([b, c, a])), ["b", "c", "a"])
    }

    func testAnswerLoopDoesNotHideThoughts() {
        let a = thought("a", uid: "ta", parent: "tb", at: 0)
        let b = thought("b", uid: "tb", parent: "ta", at: 1)
        let selfish = thought("self", uid: "ts", parent: "ts", at: 2)
        let out = RailThreads.order([a, b, selfish])
        XCTAssertEqual(Set(texts(out)), ["a", "b", "self"])
        XCTAssertEqual(out.count, 3)
    }

    func testPendingReplyJoinsTheThreadOfTheThoughtItAnswers() {
        let root = thought("root", uid: "t1", at: 0)
        let reply = thought("reply", uid: "t2", parent: "t1", at: 1)
        let lone = thought("lone", uid: "t3", at: 2)
        let threads = RailThreads.build([root, reply, lone], pending: ["t2": "Thinking", "t3": "", "tgone": "x"])
        XCTAssertEqual(threads[0].pending.map(\.parentUID), ["t2"])
        XCTAssertEqual(threads[0].pending.first?.text, "Thinking")
        XCTAssertEqual(threads[1].pending.map(\.parentUID), ["t3"])
    }
}

final class RailReadingTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 10))!
    }

    func testDueLabelIsAWeekdayWithinAWeekAndADateBeyond() {
        let wed = date(2026, 10, 14)
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(RailReading.dueLabel(date(2026, 10, 16), now: wed, calendar: calendar, locale: us), "fri")
        XCTAssertEqual(RailReading.dueLabel(date(2026, 10, 23), now: wed, calendar: calendar, locale: us), "Oct 23")
        XCTAssertEqual(RailReading.dueLabel(date(2026, 10, 10), now: wed, calendar: calendar, locale: us), "Oct 10")
    }

    func testStoredKindWinsOverTheWords() {
        var c = Comment(text: "Why is the margin different in the deck?")
        XCTAssertEqual(RailReading.of(c).kind, .question)
        c.meta = ThoughtMeta(kind: .todo, kindBy: .user)
        XCTAssertEqual(RailReading.of(c).kind, .todo)
    }

    func testAIRepliesShowOnlyStoredDecisions() {
        var c = Comment(text: "Is this right?", provenance: CommentProvenance(origin: .ai))
        XCTAssertEqual(RailReading.of(c).kind, .idea)
        c.meta = ThoughtMeta(kind: .question)
        XCTAssertEqual(RailReading.of(c).kind, .question)
    }

    func testDueComesFromTheWordsOrTheStoredDate() {
        let wrote = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 9))!
        var c = Comment(timestamp: wrote, text: "Send the deck by friday")
        let read = RailReading.of(c, calendar: calendar)
        XCTAssertEqual(read.kind, .todo)
        XCTAssertEqual(read.due.map { calendar.component(.weekday, from: $0) }, 6)
        c.meta = ThoughtMeta(due: "2026-10-23")
        XCTAssertEqual(RailReading.of(c, calendar: calendar).due, calendar.date(from: DateComponents(year: 2026, month: 10, day: 23)))
    }

    func testSnoozeDates() {
        let wed = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 22, minute: 30))!
        let tomorrow = RailSnooze.tomorrow.date(from: wed, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.month, .day, .hour, .minute], from: tomorrow), DateComponents(month: 10, day: 15, hour: 9, minute: 0))
        let next = RailSnooze.nextWeek.date(from: wed, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.month, .day, .hour, .weekday], from: next), DateComponents(month: 10, day: 19, hour: 9, weekday: 2))
    }

    func testStateAndKindEditsStampTheThought() {
        let c = Comment(text: "Cite the source")
        let done = c.settingState(.done)
        XCTAssertNotNil(done.uid)
        XCTAssertEqual(done.state, .done)
        XCTAssertNotNil(done.meta?.stateAt)
        let snoozed = done.settingState(.snoozed, snoozeUntil: calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 9))!)
        XCTAssertEqual(snoozed.state, .snoozed)
        XCTAssertEqual(snoozed.uid, done.uid)
        XCTAssertNotNil(snoozed.meta?.snoozeUntil)
        let reopened = snoozed.settingState(.open)
        XCTAssertEqual(reopened.state, .open)
        XCTAssertNil(reopened.meta?.snoozeUntil)
        let kinded = c.settingKind(.question)
        XCTAssertEqual(kinded.meta?.kind, .question)
        XCTAssertEqual(kinded.meta?.kindBy, .user)
        XCTAssertEqual(c.replying(toUID: "tabc").meta?.parent, "tabc")
    }

    func testKindGlyphSymbols() {
        XCTAssertNil(KindGlyph.symbol(kind: .idea, state: .open))
        XCTAssertEqual(KindGlyph.symbol(kind: .question, state: .open), "questionmark.circle")
        XCTAssertEqual(KindGlyph.symbol(kind: .todo, state: .open), "circle")
        XCTAssertEqual(KindGlyph.symbol(kind: .todo, state: .done), "checkmark.circle")
        XCTAssertEqual(KindGlyph.symbol(kind: .intent, state: .done), "arrow.triangle.turn.up.right.circle")
        // Core kinds map one to one.
        for kind in ThoughtKind.allCases { XCTAssertNotNil(KindGlyph.Kind(rawValue: kind.rawValue)) }
        for state in ThoughtState.allCases { XCTAssertNotNil(KindGlyph.State(rawValue: state.rawValue)) }
    }

    func testNewTokens() {
        XCTAssertEqual(Theme.NS.display.pointSize, 26)
        XCTAssertEqual(Theme.Motion.staggerSeconds, 0.04, accuracy: 0.0001)
        XCTAssertEqual(Theme.Size.thumbnail, 44)
        XCTAssertEqual(Theme.Size.tile, CGSize(width: 96, height: 64))
    }
}
