import XCTest
import FlamingoCore
import FlamingoAsk
@testable import FlamingoIndex
@testable import FlamingoThoughts

final class NightShiftPlannerTests: ThoughtsTestCase {
    let written = at("2026-10-16 18:40")
    var now: Date { at("2026-10-17 02:00") }
    var planner: NightShiftPlanner { NightShiftPlanner(vault: vault) }
    var review: String { "review conflict between this and [[q3-model.xlsx]] before friday" }

    func plan(_ records: [ThoughtRecord], spent: [String: TimeInterval] = [:], ledger l: WorkLedger? = nil, at when: Date? = nil,
              settings: PlannerSettings = PlannerSettings(), resolve: @escaping (String, FileRef) -> FileRef? = { _, _ in nil },
              asked: ((Date) -> Void)? = nil) -> [PlannedJob] {
        var p = planner; p.settings = settings
        return p.plan(records: records, now: when ?? now, ledger: l ?? ledger(), attention: { files, since in
            asked?(since)
            return Dictionary(files.compactMap { f in spent[f.relativePath].map { (f, $0) } }, uniquingKeysWith: { a, _ in a })
        }, resolve: resolve)
    }

    func testAnUntouchedIntentBecomesAJob() throws {
        let jobs = plan([record(review, at: written)])
        let job = try XCTUnwrap(jobs.first)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(job.uid, "tabc123456")
        XCTAssertEqual(job.recipe, .reviewConflict)
        XCTAssertEqual(job.file, Self.deck)
        XCTAssertEqual(job.objects, ["decks/q3-board-review.pptx#slide 7", "finance/q3-model.xlsx"])
        XCTAssertEqual(job.resume, .fresh)
        XCTAssertEqual(job.attempts, 0)
        XCTAssertEqual(job.id, "tabc123456:review-conflict:" + job.fingerprint)
        XCTAssertEqual(job.fingerprint.count, 8)
        let expected = WorkFingerprint.hash(WorkFingerprint.sources(of: ["decks/q3-board-review.pptx", "finance/q3-model.xlsx"], in: vault))
        XCTAssertEqual(job.fingerprint, expected)
    }

    func testItMustBeSixHoursOld() {
        XCTAssertEqual(plan([record(review, at: now.addingTimeInterval(-5 * 3600 - 59 * 60))]).count, 0)
        XCTAssertEqual(plan([record(review, at: now.addingTimeInterval(-6 * 3600))]).count, 1)
    }

    func testOpeningTheFilesForThreeMinutesIsActingOnIt() {
        XCTAssertEqual(plan([record(review, at: written)], spent: ["decks/q3-board-review.pptx": 400, "finance/q3-model.xlsx": 200]).count, 0,
                       "both opened three minutes or more")
        XCTAssertEqual(plan([record(review, at: written)], spent: ["decks/q3-board-review.pptx": 400, "finance/q3-model.xlsx": 179]).count, 1,
                       "one file still untouched")
        XCTAssertEqual(plan([record(review, at: written)], spent: ["decks/q3-board-review.pptx": 900]).count, 1)
        XCTAssertEqual(plan([record(review, at: written)], spent: ["decks/q3-board-review.pptx": 180, "finance/q3-model.xlsx": 180]).count, 0, "exactly three minutes counts")
    }

    func testAttentionIsCountedFromTheMomentTheThoughtWasWritten() {
        var since: [Date] = []
        _ = plan([record(review, at: written)], asked: { since.append($0) })
        XCTAssertEqual(since, [written])
    }

    func testAReplyFromThePersonSettlesIt() {
        XCTAssertEqual(plan([record(review, at: written, replies: 1, lastHumanReplyAt: now.addingTimeInterval(-3600))]).count, 0)
        XCTAssertEqual(plan([record(review, at: written, replies: 1, lastHumanReplyAt: nil)]).count, 1, "a reply from a model doesn't")
    }

    func testOnlyOpenHumanRootThoughtsQualify() {
        XCTAssertEqual(plan([record(review, at: written, state: .done)]).count, 0)
        XCTAssertEqual(plan([record(review, at: written, state: .dismissed)]).count, 0)
        XCTAssertEqual(plan([record(review, at: written, state: .snoozed)]).count, 0)
        XCTAssertEqual(plan([record(review, at: written, origin: .ai)]).count, 0)
        XCTAssertEqual(plan([record(review, at: written, parent: "tother")]).count, 0)
        XCTAssertEqual(plan([record(review, at: written, uid: nil)]).count, 0, "no uid to address it by")
    }

    func testOnlyThoughtsAskingForWorkQualify() {
        XCTAssertEqual(plan([record("Nice colour", at: written, kind: .idea, action: nil, objects: nil)]).count, 0)
        XCTAssertEqual(plan([record("What time is it?", at: written, kind: .question, action: nil, objects: nil)]).count, 0, "a question no recipe fits")
        XCTAssertEqual(plan([record("Name the two retail buyers", at: written, kind: .todo, action: nil, objects: nil)]).count, 0)
        XCTAssertEqual(plan([record("do the thing", at: written, kind: .intent, action: nil, objects: nil)]).count, 0, "an intent with no recipe")
        XCTAssertEqual(plan([record("remember", at: written, kind: .intent, action: "remind", objects: nil)]).count, 0, "remind isn't work")
    }

    func testAQuestionOrToDoWithARecipeInItsWordsQualifies() throws {
        let q = record("@ai what does [[q3-model.xlsx]] assume for Arc?", at: written, kind: .question, action: nil, objects: nil, kindBy: .rules)
        let t = record("Summarize [[q3-model.xlsx]] for the board", at: written, uid: "tdef123456", kind: .todo, action: nil, objects: nil, kindBy: .rules)
        let jobs = plan([q, t], resolve: { name, _ in name.hasPrefix("q3-model") ? Self.model : nil })
        XCTAssertEqual(Set(jobs.map(\.recipe)), [.answer, .summarize])
        XCTAssertEqual(jobs.first?.objects, ["decks/q3-board-review.pptx#slide 7", "finance/q3-model.xlsx"], "where it was left, then what its words link to")
    }

    func testAJobForTheSameFilesIsNotDoneTwice() throws {
        let l = ledger()
        let job = try XCTUnwrap(plan([record(review, at: written)]).first)
        func log(_ kind: LedgerEvent.Kind, memo: String? = nil, attempt: Int? = nil) {
            try? l.append(LedgerEvent(kind, at: now, job: job.id, uid: job.uid, recipe: "review-conflict", memo: memo, attempt: attempt))
        }
        log(.queued); log(.started, attempt: 1)
        XCTAssertEqual(plan([record(review, at: written)], ledger: l).first?.attempts, 1, "interrupted: runs again")
        log(.finished, memo: "work/2026-10-17/arc.md")
        let resume = try XCTUnwrap(plan([record(review, at: written)], ledger: l).first)
        XCTAssertEqual(resume.resume, .reply(memo: "work/2026-10-17/arc.md"), "memo written, reply missing")
        log(.replied)
        XCTAssertEqual(plan([record(review, at: written)], ledger: l).count, 0, "same fingerprint: done")
    }

    func testTwoFailedTriesEndIt() throws {
        let l = ledger()
        let job = try XCTUnwrap(plan([record(review, at: written)]).first)
        for n in 1...2 {
            try l.append(LedgerEvent(.started, at: now, job: job.id, uid: job.uid, recipe: "review-conflict", attempt: n))
            try l.append(LedgerEvent(.failed, at: now, job: job.id, uid: job.uid, recipe: "review-conflict", attempt: n, error: "bad json"))
            XCTAssertEqual(plan([record(review, at: written)], ledger: l).count, n == 1 ? 1 : 0)
        }
    }

    func testChangedFilesBringItBackOnlyAfterAWeek() throws {
        let l = ledger()
        let old = try XCTUnwrap(plan([record(review, at: written)]).first)
        try l.append(LedgerEvent(.finished, at: at("2026-10-10 02:00"), job: "tabc123456:review-conflict:deadbeef", uid: "tabc123456",
                                 recipe: "review-conflict", memo: "work/2026-10-10/arc.md"))
        XCTAssertEqual(old.fingerprint.count, 8)
        // The memo is from a different fingerprint: the files changed since.
        XCTAssertEqual(plan([record(review, at: written)], ledger: l, at: at("2026-10-16 02:00")).count, 0, "six days: too soon")
        XCTAssertEqual(plan([record(review, at: written)], ledger: l, at: at("2026-10-17 02:00")).count, 1, "seven days: look again")
    }

    func testMissingFilesMeanNoJob() {
        XCTAssertEqual(plan([record(review, file: FileRef(relativePath: "gone/x.pptx"), at: written, objects: ["gone/x.pptx", "gone/y.xlsx"])]).count, 0)
        // A thought in the inbox that names a real file still works.
        let inbox = record(review, file: FileRef(relativePath: "_inbox/2026-10-16"), anchor: nil, at: written, objects: ["finance/q3-model.xlsx"])
        XCTAssertEqual(plan([inbox]).first?.objects, ["finance/q3-model.xlsx"])
    }

    func testOrderIsDueFirstThenOldest() {
        let a = record(review, at: at("2026-10-15 10:00"), uid: "ta00000000")
        let b = record(review, at: at("2026-10-14 10:00"), uid: "tb00000000")
        let c = record(review, at: at("2026-10-16 10:00"), uid: "tc00000000", due: at("2026-10-18"))
        XCTAssertEqual(plan([a, b, c]).map(\.uid), ["tc00000000", "tb00000000", "ta00000000"])
    }

    func testWorkOnOpenThoughtsNowIgnoresAgeAndAttention() {
        let young = record(review, at: now.addingTimeInterval(-600))
        XCTAssertEqual(plan([young], settings: .now).count, 1)
        XCTAssertEqual(plan([record(review, at: written)], spent: ["decks/q3-board-review.pptx": 900, "finance/q3-model.xlsx": 900], settings: .now).count, 1)
        XCTAssertEqual(plan([record(review, at: written, replies: 1, lastHumanReplyAt: now)], settings: .now).count, 0, "a reply still settles it")
    }

    func testTheRecipeComesFromTheModelsReadingFirst() {
        XCTAssertEqual(NightShiftPlanner.recipe(for: record(review, at: written, action: "compare-versions")), .compareVersions)
        XCTAssertEqual(NightShiftPlanner.recipe(for: record(review, at: written, action: nil, objects: nil)), .reviewConflict, "else the words")
    }
}
