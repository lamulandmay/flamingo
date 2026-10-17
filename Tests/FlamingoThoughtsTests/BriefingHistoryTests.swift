import XCTest
import FlamingoCore
@testable import FlamingoThoughts

final class BriefingHistoryTests: ThoughtsTestCase {
    let now = at("2026-10-17 08:30")

    func testNothingRememberedAtFirst() {
        let h = BriefingHistory(vault: vault)
        XCTAssertEqual(h.timesSkipped("t1", now: now, calendar: testCalendar), 0)
        XCTAssertFalse(h.hasSeenMemo("work/x.md")); XCTAssertFalse(h.hasSeenReply("t2")); XCTAssertFalse(h.hasSeenPair("a", "b"))
        XCTAssertTrue(BriefingHistory.url(in: vault).path.hasSuffix("/.flamingo/briefing.json"))
    }

    func testShownCountsAreOncePerDayAndCoverTheLastSevenDays() {
        let h = BriefingHistory(vault: vault)
        h.recordShown(["t1"], day: "2026-10-16"); h.recordShown(["t1"], day: "2026-10-16")
        XCTAssertEqual(h.timesSkipped("t1", now: now, calendar: testCalendar), 1, "twice on one day is once")
        h.recordShown(["t1", "t2"], day: "2026-10-15"); h.recordShown(["t1"], day: "2026-10-11"); h.recordShown(["t1"], day: "2026-10-09")
        XCTAssertEqual(h.timesSkipped("t1", now: now, calendar: testCalendar), 3, "the 10th and before are older than a week")
        XCTAssertEqual(h.timesSkipped("t2", now: now, calendar: testCalendar), 1)
    }

    func testDoingSomethingClearsTheSkips() {
        let h = BriefingHistory(vault: vault)
        h.recordShown(["t1"], day: "2026-10-16")
        h.recordAction("t1")
        XCTAssertEqual(h.timesSkipped("t1", now: now, calendar: testCalendar), 0)
    }

    func testItSurvivesARestartAsPlainJSON() throws {
        let h = BriefingHistory(vault: vault)
        h.recordShown(["t1"], day: "2026-10-16"); h.markMemoSeen("work/2026-10-17/arc.md"); h.markReplySeen("tr1"); h.markPairSeen("b.md", "a.md")
        try h.save(now: now, calendar: testCalendar)
        let text = try String(contentsOf: h.url)
        XCTAssertTrue(text.contains("\"seenMemos\""))
        XCTAssertTrue(text.contains("work/2026-10-17/arc.md"))
        XCTAssertFalse(text.contains("\\/"), "slashes aren't escaped")
        let again = BriefingHistory(vault: vault)
        XCTAssertTrue(again.hasSeenMemo("work/2026-10-17/arc.md"))
        XCTAssertTrue(again.hasSeenReply("tr1"))
        XCTAssertTrue(again.hasSeenPair("a.md", "b.md"), "a pair is the same either way round")
        XCTAssertEqual(again.timesSkipped("t1", now: now, calendar: testCalendar), 1)
    }

    func testOldShownDaysAreDroppedOnSave() throws {
        let h = BriefingHistory(vault: vault)
        h.recordShown(["t1"], day: "2026-09-01"); h.recordShown(["t2"], day: "2026-10-16")
        try h.save(now: now, calendar: testCalendar)
        let text = try String(contentsOf: h.url)
        XCTAssertFalse(text.contains("2026-09-01"))
        XCTAssertTrue(text.contains("2026-10-16"))
    }

    func testAnUnreadableFileIsAnEmptyHistoryNotACrash() throws {
        try FileManager.default.createDirectory(at: vault.stateDir, withIntermediateDirectories: true)
        try "not json".write(to: BriefingHistory.url(in: vault), atomically: true, encoding: .utf8)
        XCTAssertFalse(BriefingHistory(vault: vault).hasSeenMemo("x"))
    }

    func testItHoldsNoThoughtText() throws {
        let h = BriefingHistory(vault: vault)
        h.recordShown(["tabc123456"], day: "2026-10-16"); h.markMemoSeen("work/2026-10-17/arc.md")
        try h.save(now: now, calendar: testCalendar)
        let text = try String(contentsOf: h.url)
        XCTAssertFalse(text.contains("Name the two"))
    }
}
