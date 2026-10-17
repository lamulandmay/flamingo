import XCTest
import FlamingoCore
import FlamingoAsk
import FlamingoTrail
@testable import FlamingoIndex
@testable import FlamingoThoughts

final class NightShiftSchedulerTests: ThoughtsTestCase {
    var service: NightShiftService!
    var worker = FakeWorker()

    override func setUpWithError() throws {
        try super.setUpWithError()
        let index = try IndexStore(vault: vault)
        try store.append(Comment(timestamp: at("2026-10-16 18:40"), anchor: FileAnchor(kind: .slide, value: "7"), text: "review conflict between this and [[q3-model.xlsx]]",
                                 provenance: CommentProvenance(origin: .human),
                                 meta: ThoughtMeta(uid: "tsched0001", kind: .intent, kindBy: .model,
                                                   intent: ThoughtIntent(action: "review-conflict", objects: ["decks/q3-board-review.pptx#slide 7", "finance/q3-model.xlsx"]))), to: Self.deck)
        for path in ["decks/q3-board-review.pptx", "finance/q3-model.xlsx"] {
            try FileManager.default.setAttributes([.modificationDate: at("2026-10-01 09:00")], ofItemAtPath: root.appendingPathComponent(path).path)
        }
        try index.reindex()
        service = NightShiftService(vault: vault, index: index, store: store, trail: TrailStore(vault: vault), worker: worker, clock: { at("2026-10-17 02:00") })
        service.calendar = testCalendar
    }

    func scheduler(power: PowerSnapshot = .pluggedIn, idle: TimeInterval = 3600, outcomes: Outcomes = Outcomes()) -> NightShiftScheduler {
        NightShiftScheduler(service: { [service] in service }, power: { power }, idle: { idle }, onOutcome: { outcomes.add($0) })
    }

    final class Outcomes: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [NightShiftOutcome] = []
        func add(_ o: NightShiftOutcome) { lock.withLock { all.append(o) } }
        var values: [NightShiftOutcome] { lock.withLock { all } }
    }

    func testStartAndStopAreIdempotent() {
        let s = scheduler()
        XCTAssertFalse(s.isRunning)
        s.start(); s.start()
        XCTAssertTrue(s.isRunning)
        s.stop(); s.stop()
        XCTAssertFalse(s.isRunning)
        s.start(); s.stop()
    }

    func testATickRunsTheNightAndReportsIt() async throws {
        let outcomes = Outcomes()
        let s = scheduler(outcomes: outcomes)
        let outcome = await s.tick()
        guard case .ran(let summary)? = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertEqual(summary.replied, 1)
        XCTAssertEqual(outcomes.values.count, 1)
        XCTAssertFalse(s.isWorking)
        let again = await s.tick()
        XCTAssertEqual(again, .skipped(.alreadyRanTonight))
    }

    func testATickOnBatteryOrWithTheMacInUseDoesNothing() async {
        let onBattery = await scheduler(power: PowerSnapshot(onAC: false, batteryPercent: 90)).tick()
        XCTAssertEqual(onBattery, .skipped(.onBattery))
        let busy = await scheduler(idle: 10).tick()
        guard case .skipped(.notIdle)? = busy else { return XCTFail("\(String(describing: busy))") }
        XCTAssertTrue(worker.requests.isEmpty)
    }

    func testNoVaultMeansNoTick() async {
        let s = NightShiftScheduler(service: { nil })
        let outcome = await s.tick()
        XCTAssertNil(outcome)
    }

    func testTwoTicksAtOnceWorkOnce() async throws {
        worker.behaviour = { _ in try await Task.sleep(nanoseconds: 300_000_000) }
        let s = scheduler()
        async let first = s.tick()
        try await Task.sleep(nanoseconds: 100_000_000)
        let second = await s.tick()
        XCTAssertNil(second, "already working")
        let done = await first
        XCTAssertNotNil(done)
        XCTAssertEqual(worker.requests.count, 1)
    }

    func testThePersonComingBackMidBatchStopsIt() async throws {
        let idle = IdleBox(3600)
        let s = NightShiftScheduler(service: { [service] in service }, power: { .pluggedIn }, idle: { idle.value })
        worker.behaviour = { _ in idle.value = 5 } // the first job is running when they touch the mouse
        try store.append(Comment(timestamp: at("2026-10-16 18:50"), text: "review conflict again [[q3-model.xlsx]]",
                                 provenance: CommentProvenance(origin: .human), meta: ThoughtMeta(uid: "tsched0002", kind: .intent, kindBy: .model,
                                 intent: ThoughtIntent(action: "review-conflict", objects: ["finance/q3-model.xlsx"]))), to: Self.deck)
        try service.index.reindex()
        let outcome = await s.tick()
        guard case .ran(let summary)? = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertEqual(summary.attempted, 1)
        XCTAssertEqual(summary.stop, .conditionsChanged)
    }

    final class IdleBox: @unchecked Sendable {
        private let lock = NSLock(); private var v: TimeInterval
        init(_ v: TimeInterval) { self.v = v }
        var value: TimeInterval { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
    }

    func testPowerSnapshotReadsTheMac() {
        let p = PowerSnapshot.current()
        XCTAssertNotNil(p.thermal)
        XCTAssertGreaterThanOrEqual(UserIdle.seconds(), 0)
        if let pct = p.batteryPercent { XCTAssertTrue((0...100).contains(pct)) }
    }
}
