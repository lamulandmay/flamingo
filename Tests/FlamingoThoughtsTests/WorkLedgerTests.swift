import XCTest
import FlamingoCore
@testable import FlamingoThoughts

final class WorkLedgerTests: ThoughtsTestCase {
    let job = "tabc123456:review-conflict:0a1b2c3d"
    let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    func ev(_ kind: LedgerEvent.Kind, _ seconds: Double = 0, job: String? = nil, attempt: Int? = nil, memo: String? = nil, error: String? = nil,
            permanent: Bool? = nil) -> LedgerEvent {
        LedgerEvent(kind, at: t0.addingTimeInterval(seconds), night: "2026-10-16", job: job ?? self.job, uid: "tabc123456",
                    recipe: "review-conflict", file: "decks/q3-board-review.pptx", memo: memo, attempt: attempt, error: error, permanent: permanent)
    }

    func testEventsRoundTripThroughTheFileOneJSONObjectPerLine() throws {
        let l = ledger()
        try l.append(ev(.queued)); try l.append(ev(.started, 1, attempt: 1)); try l.append(ev(.finished, 90, memo: "work/2026-10-17/arc.md"))
        let lines = WorkLedgerFile.lines(in: vault)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("{"))
        XCTAssertTrue(lines[0].contains("\"event\":\"queued\""))
        XCTAssertFalse(lines[0].contains("\n"))
        XCTAssertEqual(l.events().map(\.event), [.queued, .started, .finished])
        XCTAssertEqual(l.events()[2].memo, "work/2026-10-17/arc.md")
        XCTAssertEqual(l.events()[1].at, t0.addingTimeInterval(1))
    }

    func testATornLastLineIsIgnored() throws {
        let l = ledger()
        try l.append(ev(.queued)); try l.append(ev(.started, 1, attempt: 1))
        let handle = try FileHandle(forWritingTo: vault.workLedgerURL)
        handle.seekToEndOfFile()
        handle.write(Data(#"{"at":"2026-10-17T00:00:00Z","event":"finished","job":"tab"#.utf8)) // power cut mid-write
        try handle.close()
        XCTAssertEqual(l.events().map(\.event), [.queued, .started])
        XCTAssertEqual(l.record(for: job)?.phase, .interrupted)
        // And the next append starts on a fresh line, not glued to the torn one.
        try l.append(ev(.failed, 5, attempt: 1, error: "x"))
        XCTAssertEqual(l.events().map(\.event).last, .failed)
    }

    func testAGarbledMiddleLineIsSkippedNotFatal() throws {
        let l = ledger()
        try l.append(ev(.queued))
        try WorkLedgerFile.append("not json at all", in: vault)
        try l.append(ev(.started, 1, attempt: 1))
        XCTAssertEqual(l.events().map(\.event), [.queued, .started])
    }

    func testPhasesFollowTheEvents() throws {
        let l = ledger()
        XCTAssertNil(l.record(for: job))
        try l.append(ev(.queued))
        XCTAssertEqual(l.record(for: job)?.phase, .queued)
        try l.append(ev(.started, 1, attempt: 1))
        XCTAssertEqual(l.record(for: job)?.phase, .interrupted, "started and nothing after it: a crash")
        try l.append(ev(.failed, 2, attempt: 1, error: "bad json"))
        XCTAssertEqual(l.record(for: job)?.phase, .retryable)
        XCTAssertEqual(l.record(for: job)?.lastError, "bad json")
        try l.append(ev(.started, 3, attempt: 2))
        XCTAssertEqual(l.record(for: job)?.phase, .exhausted, "interrupted on the second try: no third")
        XCTAssertEqual(l.record(for: job)?.attempts, 2)
    }

    func testTwoFailuresAreFinalAndAPermanentOneIsFinalAtOnce() throws {
        let l = ledger()
        try l.append(ev(.started, 0, attempt: 1)); try l.append(ev(.failed, 1, attempt: 1))
        try l.append(ev(.started, 2, attempt: 2)); try l.append(ev(.failed, 3, attempt: 2))
        XCTAssertEqual(l.record(for: job)?.phase, .exhausted)
        let other = "tzzz:summarize:11223344"
        try l.append(ev(.failed, 4, job: other, permanent: true))
        XCTAssertEqual(l.record(for: other)?.phase, .exhausted)
    }

    func testAMemoWithoutItsReplyResumesAtTheReply() throws {
        let l = ledger()
        try l.append(ev(.started, 0, attempt: 1)); try l.append(ev(.finished, 60, memo: "work/2026-10-17/arc.md"))
        XCTAssertEqual(l.record(for: job)?.phase, .needsReply)
        XCTAssertEqual(l.record(for: job)?.memo, "work/2026-10-17/arc.md")
        try l.append(ev(.replied, 61))
        XCTAssertEqual(l.record(for: job)?.phase, .done)
    }

    func testReplayingTheSameEventsGivesTheSameJobs() throws {
        let l = ledger()
        let events = [ev(.queued), ev(.started, 1, attempt: 1), ev(.finished, 9, memo: "work/x.md"), ev(.replied, 10)]
        for e in events { try l.append(e) }
        let once = l.jobs()
        XCTAssertEqual(WorkLedger.fold(l.events() + l.events()).values.first?.phase, .done, "twice over is still done")
        XCTAssertEqual(l.jobs(), once, "reading changes nothing")
        XCTAssertEqual(WorkLedger(vault: vault).jobs(), once, "a new instance (a restart) sees the same")
    }

    func testNightsAndCatchUpsAreRemembered() throws {
        let l = ledger()
        try l.append(LedgerEvent(.nightStart, at: t0, night: "2026-10-16"))
        XCTAssertEqual(l.history(), NightHistory())
        try l.append(LedgerEvent(.nightEnd, at: t0, night: "2026-10-16", reason: "finishedAll"))
        try l.append(LedgerEvent(.catchUpEnd, at: t0, night: "2026-10-17"))
        XCTAssertEqual(l.history(), NightHistory(endedNights: ["2026-10-16"], catchUpDays: ["2026-10-17"]))
    }

    func testTheNewestFinishedJobForAThoughtAndRecipe() throws {
        let l = ledger()
        try l.append(ev(.finished, 100, job: "tabc123456:review-conflict:aaaaaaaa", memo: "work/a.md"))
        try l.append(ev(.finished, 500, job: "tabc123456:review-conflict:bbbbbbbb", memo: "work/b.md"))
        XCTAssertEqual(l.lastFinished(uid: "tabc123456", recipe: "review-conflict")?.job, "tabc123456:review-conflict:bbbbbbbb")
        XCTAssertNil(l.lastFinished(uid: "tabc123456", recipe: "summarize"))
        XCTAssertNil(l.lastFinished(uid: "tother", recipe: "review-conflict"))
    }

    func testTwoWritersNeverTearEachOthersLines() async throws {
        let l1 = ledger(), l2 = ledger()
        await withTaskGroup(of: Void.self) { group in
            for n in 0..<40 {
                group.addTask { try? (n % 2 == 0 ? l1 : l2).append(self.ev(.queued, Double(n), job: "tabc123456:summarize:\(String(format: "%08x", n))")) }
            }
        }
        XCTAssertEqual(l1.events().count, 40)
        XCTAssertEqual(l1.jobs().count, 40)
    }

    func testTheLedgerLivesUnderDotFlamingoWork() throws {
        try ledger().append(ev(.queued))
        XCTAssertTrue(vault.workLedgerURL.path.hasSuffix("/.flamingo/work/ledger.jsonl"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.workLedgerURL.path))
    }
}
