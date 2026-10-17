import XCTest
import FlamingoCore
import FlamingoAsk
import FlamingoTrail
@testable import FlamingoIndex
@testable import FlamingoThoughts

final class NightShiftServiceTests: ThoughtsTestCase {
    var index: IndexStore!
    var trail: TrailStore!
    var worker = FakeWorker()
    var service: NightShiftService!
    var clockNow = at("2026-10-17 02:00")
    let review = "review conflict between this and [[q3-model.xlsx]] before friday"

    override func setUpWithError() throws {
        try super.setUpWithError()
        index = try IndexStore(vault: vault)
        trail = TrailStore(vault: vault)
        trail.flushDelay = 3600
        worker = FakeWorker()
        try makeService()
        for path in ["decks/q3-board-review.pptx", "finance/q3-model.xlsx", "docs/pricing-memo.docx"] {
            try FileManager.default.setAttributes([.modificationDate: at("2026-10-01 09:00")], ofItemAtPath: root.appendingPathComponent(path).path)
        }
    }

    func makeService() throws {
        let when = clockNow
        service = NightShiftService(vault: vault, index: index, store: store, trail: trail, worker: worker, clock: { when })
        service.calendar = testCalendar
    }

    func setClock(_ text: String) throws { clockNow = at(text); try makeService() }

    /// A thought that asks for work, written at 18:40 the evening before.
    @discardableResult
    func think(_ text: String? = nil, uid: String? = "t8m2k4q9xa", at date: Date = at("2026-10-16 18:40"), intent: Bool = true) throws -> Comment {
        var meta = ThoughtMeta(uid: uid)
        if intent {
            meta.kind = .intent; meta.kindBy = .model
            meta.intent = ThoughtIntent(action: "review-conflict", objects: ["decks/q3-board-review.pptx#slide 7", "finance/q3-model.xlsx"], confidence: 0.9, model: "m")
        }
        try store.append(Comment(timestamp: date, anchor: FileAnchor(kind: .slide, value: "7"), text: text ?? review,
                                 provenance: CommentProvenance(origin: .human), meta: meta), to: Self.deck)
        return try XCTUnwrap(try store.comments(for: Self.deck).last)
    }

    func reindex() throws { try index.reindex() }

    func thread(_ uid: String = "t8m2k4q9xa") throws -> [Comment] { try store.comments(for: Self.deck).filter { $0.meta?.parent == uid } }

    // MARK: Planning

    func testPlanFindsTheOldUnansweredIntent() throws {
        try think(); try reindex()
        let jobs = try service.plan()
        XCTAssertEqual(jobs.map(\.uid), ["t8m2k4q9xa"])
        XCTAssertEqual(jobs.first?.recipe, .reviewConflict)
    }

    func testAThoughtAskingForWorkInPlainWordsGetsAUIDAndAJob() throws {
        try think(uid: nil, intent: false)
        try reindex()
        XCTAssertNil(try store.comments(for: Self.deck).first?.uid)
        let jobs = try service.plan()
        XCTAssertEqual(jobs.count, 1)
        let uid = try XCTUnwrap(jobs.first?.uid)
        XCTAssertEqual(try store.comments(for: Self.deck).first?.uid, uid, "the first time something refers to it, it gets its uid")
        XCTAssertEqual(jobs.first?.recipe, .reviewConflict)
        XCTAssertEqual(jobs.first?.objects, ["decks/q3-board-review.pptx#slide 7", "finance/q3-model.xlsx"], "the link was resolved in the vault")
    }

    func testOtherLegacyThoughtsAreNotGivenUIDs() throws {
        try store.append(Comment(timestamp: at("2026-10-12 09:00"), text: "Coral only"), to: Self.deck)
        try think(); try reindex()
        _ = try service.plan()
        XCTAssertEqual(try store.comments(for: Self.deck).filter { $0.uid == nil }.count, 1, "no mass rewrite of notes")
    }

    func testTimeSpentOnTheFilesTakesTheThoughtOutOfThePlan() throws {
        try think(); try reindex()
        XCTAssertEqual(try service.plan().count, 1)
        trail.record(TrailEvent(at: at("2026-10-16 19:00"), kind: .opened, file: Self.deck))
        trail.record(TrailEvent(at: at("2026-10-16 19:05"), kind: .opened, file: Self.model))
        trail.record(TrailEvent(at: at("2026-10-16 19:10"), kind: .opened, file: Self.memo))
        trail.flush()
        XCTAssertEqual(try service.plan().count, 0, "five minutes on each of the two files")
    }

    // MARK: A night

    func tonight(power: PowerSnapshot = .pluggedIn, idle: TimeInterval = 20 * 60, continuing: @escaping @Sendable () -> Bool = { true }) async -> NightShiftOutcome {
        await service.runTonight(power: power, idleSeconds: idle, shouldContinue: continuing)
    }

    func testANightWorksThenIsDone() async throws {
        try think(); try reindex()
        guard case .ran(let summary) = await tonight() else { return XCTFail("should run") }
        XCTAssertEqual(summary.replied, 1)
        XCTAssertEqual(try thread().count, 1)
        XCTAssertEqual(service.ledger.events().map(\.event), [.nightStart, .queued, .started, .finished, .replied, .nightEnd])
        XCTAssertEqual(service.ledger.events().last?.night, "2026-10-16")
        XCTAssertEqual(service.ledger.history().endedNights, ["2026-10-16"])
        XCTAssertEqual(worker.requests.first?.purpose, .nightShift)

        let again = await tonight()
        XCTAssertEqual(again, .skipped(.alreadyRanTonight))
        XCTAssertEqual(worker.requests.count, 1)
    }

    func testNothingToDoIsNotARunAndDoesNotEndTheNight() async throws {
        // Written at 20:30, it is five and a half hours old at 02:00: not yet.
        try think(at: at("2026-10-16 20:30")); try reindex()
        let outcome = await tonight()
        XCTAssertEqual(outcome, .skipped(.nothingToDo))
        XCTAssertTrue(service.ledger.events().isEmpty)
        // At 03:00 it is six and a half: picked up later in the same night.
        try setClock("2026-10-17 03:00")
        let later = await tonight()
        guard case .ran = later else { return XCTFail("\(later)") }
    }

    func testOutsideTheWindowOnBatteryOrBusyItWaits() async throws {
        try think(); try reindex()
        try setClock("2026-10-17 14:00")
        let day = await tonight()
        XCTAssertEqual(day, .waiting(until: at("2026-10-17 22:00")))
        try setClock("2026-10-17 02:00")
        let battery = await tonight(power: PowerSnapshot(onAC: false, batteryPercent: 80))
        XCTAssertEqual(battery, .skipped(.onBattery))
        let busy = await tonight(idle: 60)
        XCTAssertEqual(busy, .skipped(.notIdle(seconds: 840)))
        XCTAssertTrue(worker.requests.isEmpty)
        XCTAssertTrue(service.ledger.events().isEmpty)
    }

    func testPausedAndDeniedDoNothing() async throws {
        try think(); try reindex()
        service.settings.enabled = false
        let paused = await tonight()
        XCTAssertEqual(paused, .skipped(.disabled))
        service.settings.enabled = true
        service.budgetOverride = { .deny }
        let denied = await tonight()
        XCTAssertEqual(denied, .skipped(.budgetDenied))
        service.budgetOverride = { .cap(NightBudget(jobs: 0, wallSeconds: 60, tokens: 10, perJobSeconds: 10)) }
        guard case .ran(let summary) = await tonight() else { return XCTFail("should run") }
        XCTAssertEqual(summary.attempted, 0, "a cap of no jobs runs none")
        XCTAssertTrue(worker.requests.isEmpty)
    }

    func testAPersonComingBackEndsTheBatchWithoutEndingTheNight() async throws {
        try think(); try think("review conflict again [[q3-model.xlsx]]", uid: "tb00000000", at: at("2026-10-16 18:50")); try reindex()
        let asked = Counter()
        guard case .ran(let summary) = await tonight(continuing: { asked.next() < 2 }) else { return XCTFail("should run") }
        XCTAssertEqual(summary.attempted, 1)
        XCTAssertEqual(summary.stop, .conditionsChanged)
        XCTAssertTrue(service.ledger.history().endedNights.isEmpty, "later tonight it can pick up where it stopped")
        let resumed = await tonight()
        guard case .ran(let rest) = resumed else { return XCTFail("\(resumed)") }
        XCTAssertEqual(rest.replied, 1, "only the job that was left")
        XCTAssertEqual(worker.requests.count, 2)
    }

    // MARK: Catch-up

    func testTheFirstOpenAfterAMissedNightCatchesUpWithAtMostThreeJobs() async throws {
        for i in 0..<5 { try think("review conflict \(i) [[q3-model.xlsx]]", uid: "t\(i)00000000", at: at("2026-10-16 18:4\(i)")) }
        try reindex()
        try setClock("2026-10-17 08:30")
        guard case .ran(let summary) = await service.catchUp(power: PowerSnapshot(onAC: false, batteryPercent: 80)) else { return XCTFail("should run") }
        XCTAssertEqual(summary.attempted, 3)
        XCTAssertEqual(summary.stop, .jobBudget)
        XCTAssertEqual(worker.requests.count, 3)
        XCTAssertEqual(service.ledger.history().catchUpDays, ["2026-10-17"])
        let again = await service.catchUp(power: .pluggedIn)
        XCTAssertEqual(again, .skipped(.alreadyCaughtUp))
    }

    func testCatchUpDeclinesWhenTheNightRanOrOnALowBattery() async throws {
        try think(); try reindex()
        try setClock("2026-10-17 08:30")
        let low = await service.catchUp(power: PowerSnapshot(onAC: false, batteryPercent: 40))
        XCTAssertEqual(low, .skipped(.onBattery))
        try service.ledger.append(LedgerEvent(.nightEnd, at: at("2026-10-17 03:00"), night: "2026-10-16"))
        let ran = await service.catchUp(power: .pluggedIn)
        XCTAssertEqual(ran, .skipped(.lastNightDidNotMiss))
        XCTAssertTrue(worker.requests.isEmpty)
    }

    func testCatchUpWithNothingToDoDoesNotPlanOrRecordAnything() async throws {
        try setClock("2026-10-17 08:30")
        let outcome = await service.catchUp(power: .pluggedIn)
        XCTAssertEqual(outcome, .skipped(.nothingToDo))
        XCTAssertTrue(service.ledger.events().isEmpty)
    }

    // MARK: Work now

    func testWorkOnOpenThoughtsNowIgnoresTheWindowAndAgeAndUsesAnInteractiveModel() async throws {
        try think(at: at("2026-10-17 13:50")); try reindex()  // ten minutes old
        try setClock("2026-10-17 14:00")
        XCTAssertTrue(try service.plan().isEmpty)
        let summary = await service.workNow()
        XCTAssertEqual(summary.replied, 1)
        XCTAssertEqual(worker.requests.first?.purpose, .interactive)
        XCTAssertEqual(try thread().count, 1)
    }

    func testWorkOnOneThoughtWithAChosenRecipe() async throws {
        try think()
        let summary = await service.workNow(thoughtUID: "t8m2k4q9xa", in: Self.deck, recipe: .summarize)
        XCTAssertEqual(summary?.replied, 1)
        XCTAssertEqual(worker.requests.first?.recipe, .summarize)
        XCTAssertEqual(worker.requests.first?.purpose, .interactive)
        let missing = await service.workNow(thoughtUID: "tnope", in: Self.deck, recipe: .summarize)
        XCTAssertNil(missing)
    }
}
