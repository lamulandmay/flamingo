import XCTest
import FlamingoCore
@testable import FlamingoThoughts

final class NightShiftGateTests: XCTestCase {
    let gate = NightShiftGate(calendar: testCalendar)
    let idle = 20 * 60.0
    let none = NightHistory()

    func decide(_ when: String, power: PowerSnapshot = .pluggedIn, idle: TimeInterval = 20 * 60, history: NightHistory = NightHistory(),
                override: (@Sendable () -> BudgetOverride?)? = nil) -> GateDecision {
        gate.decide(now: at(when), power: power, idleSeconds: idle, history: history, budgetOverride: override)
    }

    func testRunsInsideTheWindowWhenEverythingIsRight() {
        XCTAssertEqual(decide("2026-10-17 02:00"), .run(.night))
        XCTAssertEqual(NightBudget.night, NightBudget(jobs: 6, wallSeconds: 45 * 60, tokens: 150_000, perJobSeconds: 8 * 60))
    }

    func testTheWindowIsTenAtNightToSixInTheMorning() {
        XCTAssertEqual(decide("2026-10-17 21:59"), .wait(until: at("2026-10-17 22:00")))
        XCTAssertEqual(decide("2026-10-17 22:00"), .run(.night))
        XCTAssertEqual(decide("2026-10-18 05:59"), .run(.night))
        XCTAssertEqual(decide("2026-10-18 06:00"), .wait(until: at("2026-10-18 22:00")))
        XCTAssertEqual(decide("2026-10-17 14:00"), .wait(until: at("2026-10-17 22:00")))
    }

    func testNightsAreNamedByTheDateTheWindowOpened() {
        XCTAssertEqual(gate.nightID(at: at("2026-10-17 02:00")), "2026-10-16")
        XCTAssertEqual(gate.nightID(at: at("2026-10-17 22:30")), "2026-10-17")
        XCTAssertNil(gate.nightID(at: at("2026-10-17 12:00")))
        XCTAssertEqual(gate.latestNightID(at: at("2026-10-17 08:30")), "2026-10-16")
        XCTAssertEqual(gate.latestNightID(at: at("2026-10-17 23:00")), "2026-10-17")
    }

    func testBatteryLowPowerAndHeatEachStopIt() {
        XCTAssertEqual(decide("2026-10-17 02:00", power: PowerSnapshot(onAC: false, batteryPercent: 90)), .skip(.onBattery))
        XCTAssertEqual(decide("2026-10-17 02:00", power: PowerSnapshot(onAC: true, lowPowerMode: true)), .skip(.lowPowerMode))
        XCTAssertEqual(decide("2026-10-17 02:00", power: PowerSnapshot(onAC: true, thermal: .serious)), .skip(.thermal))
        XCTAssertEqual(decide("2026-10-17 02:00", power: PowerSnapshot(onAC: true, thermal: .critical)), .skip(.thermal))
        XCTAssertEqual(decide("2026-10-17 02:00", power: PowerSnapshot(onAC: true, thermal: .fair)), .run(.night), "fair is fine")
    }

    func testTheMacMustHaveBeenLeftAloneForFifteenMinutes() {
        XCTAssertEqual(decide("2026-10-17 02:00", idle: 14 * 60), .skip(.notIdle(seconds: 60)))
        XCTAssertEqual(decide("2026-10-17 02:00", idle: 15 * 60), .run(.night))
        XCTAssertEqual(decide("2026-10-17 02:00", idle: 0), .skip(.notIdle(seconds: 900)))
    }

    func testOnceANightHasRunItDoesNotRunAgain() {
        let ran = NightHistory(endedNights: ["2026-10-16"])
        XCTAssertEqual(decide("2026-10-17 02:00", history: ran), .skip(.alreadyRanTonight))
        XCTAssertEqual(decide("2026-10-17 23:00", history: ran), .run(.night), "tomorrow night is another night")
        XCTAssertEqual(decide("2026-10-17 12:00", history: ran), .wait(until: at("2026-10-17 22:00")))
    }

    func testPausedStopsEverything() {
        var settings = NightShiftSettings(); settings.enabled = false
        let paused = NightShiftGate(settings: settings, calendar: testCalendar)
        XCTAssertEqual(paused.decide(now: at("2026-10-17 02:00"), power: .pluggedIn, idleSeconds: 3600, history: none), .skip(.disabled))
        XCTAssertEqual(paused.decide(now: at("2026-10-17 14:00"), power: .pluggedIn, idleSeconds: 3600, history: none), .skip(.disabled))
        XCTAssertEqual(paused.decideCatchUp(now: at("2026-10-17 08:30"), power: .pluggedIn, history: none, candidates: 3), .skip(.disabled))
    }

    func testTheComputeBudgetHookCanDenyOrCapButIsNotRequired() {
        XCTAssertEqual(decide("2026-10-17 02:00", override: { .deny }), .skip(.budgetDenied))
        let small = NightBudget(jobs: 2, wallSeconds: 600, tokens: 1_000_000, perJobSeconds: 60)
        XCTAssertEqual(decide("2026-10-17 02:00", override: { .cap(small) }),
                       .run(NightBudget(jobs: 2, wallSeconds: 600, tokens: 150_000, perJobSeconds: 60)))
        XCTAssertEqual(decide("2026-10-17 02:00", override: { nil }), .run(.night))
        XCTAssertEqual(decide("2026-10-17 14:00", override: { .deny }), .wait(until: at("2026-10-17 22:00")), "outside the window the clock answers first")
    }

    func testAWindowThatOpensAfterTheClocksGoBackStillOpensAtTen() {
        // New York leaves daylight time at 02:00 on 2026-11-01.
        XCTAssertEqual(gate.nextWindowStart(after: at("2026-11-01 12:00")), at("2026-11-01 22:00"))
        XCTAssertEqual(gate.nightID(at: at("2026-11-02 01:00")), "2026-11-01")
        XCTAssertEqual(decide("2026-11-01 23:00"), .run(.night))
        // And forward, on 2026-03-08.
        XCTAssertEqual(gate.nextWindowStart(after: at("2026-03-08 12:00")), at("2026-03-08 22:00"))
    }

    // MARK: Catch-up

    func catchUp(_ when: String = "2026-10-17 08:30", power: PowerSnapshot = .pluggedIn, history: NightHistory = NightHistory(), candidates: Int = 2,
                 override: (@Sendable () -> BudgetOverride?)? = nil) -> GateDecision {
        gate.decideCatchUp(now: at(when), power: power, history: history, candidates: candidates, budgetOverride: override)
    }

    func testAMissedNightIsCaughtUpAtTheFirstOpenWithThreeJobsInTwelveMinutes() {
        XCTAssertEqual(catchUp(), .run(.catchUp))
        XCTAssertEqual(NightBudget.catchUp.jobs, 3)
        XCTAssertEqual(NightBudget.catchUp.wallSeconds, 12 * 60)
    }

    func testCatchUpOnBatteryNeedsHalfACharge() {
        XCTAssertEqual(catchUp(power: PowerSnapshot(onAC: false, batteryPercent: 50)), .run(.catchUp))
        XCTAssertEqual(catchUp(power: PowerSnapshot(onAC: false, batteryPercent: 49)), .skip(.onBattery))
        XCTAssertEqual(catchUp(power: PowerSnapshot(onAC: false, batteryPercent: 90, lowPowerMode: true)), .skip(.lowPowerMode))
        XCTAssertEqual(catchUp(power: PowerSnapshot(onAC: true, thermal: .serious)), .skip(.thermal))
    }

    func testCatchUpOnlyWhenTheLastNightMissedAndThereIsSomethingToDo() {
        XCTAssertEqual(catchUp(history: NightHistory(endedNights: ["2026-10-16"])), .skip(.lastNightDidNotMiss))
        XCTAssertEqual(catchUp(history: NightHistory(endedNights: ["2026-10-15"])), .run(.catchUp), "an older night doesn't count")
        XCTAssertEqual(catchUp(history: NightHistory(catchUpDays: ["2026-10-17"])), .skip(.alreadyCaughtUp))
        XCTAssertEqual(catchUp(candidates: 0), .skip(.nothingToDo))
        XCTAssertEqual(catchUp("2026-10-17 23:00"), .skip(.windowOpen), "tonight's run will do it")
        XCTAssertEqual(catchUp("2026-10-17 03:30"), .skip(.windowOpen))
    }

    func testCatchUpDayRollsOverAtFourInTheMorning() {
        // 05:00 is still inside the night window; at 06:00 the day began at 04:00, so the 17th.
        XCTAssertEqual(catchUp("2026-10-17 06:30", history: NightHistory(catchUpDays: ["2026-10-16"])), .run(.catchUp))
        XCTAssertEqual(catchUp("2026-10-17 06:30", history: NightHistory(catchUpDays: ["2026-10-17"])), .skip(.alreadyCaughtUp))
    }

    func testCatchUpHonoursTheBudgetHook() {
        XCTAssertEqual(catchUp(override: { .deny }), .skip(.budgetDenied))
        XCTAssertEqual(catchUp(override: { .cap(NightBudget(jobs: 1, wallSeconds: 60, tokens: 10, perJobSeconds: 30)) }),
                       .run(NightBudget(jobs: 1, wallSeconds: 60, tokens: 10, perJobSeconds: 30)))
    }
}
