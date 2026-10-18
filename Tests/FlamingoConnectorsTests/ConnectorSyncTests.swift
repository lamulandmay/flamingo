import XCTest
@testable import FlamingoConnectors

/// Answers from a queue and remembers what it was asked. Never touches the network.
actor FakeTransport: FeedTransport {
    var answers: [Result<FeedFetch, ConnectorError>]
    private(set) var calls: [(url: URL, etag: String?, lastModified: String?)] = []
    private(set) var inFlight = 0
    private(set) var maxInFlight = 0
    let delay: UInt64

    init(_ answers: [Result<FeedFetch, ConnectorError>], delay: UInt64 = 0) {
        self.answers = answers; self.delay = delay
    }

    func fetch(_ url: URL, etag: String?, lastModified: String?) async throws -> FeedFetch {
        calls.append((url, etag, lastModified))
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        inFlight -= 1
        let answer = answers.isEmpty ? .failure(.network) : answers.removeFirst()
        return try answer.get()
    }
}

/// A clock the test moves.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date = Fixtures.now) { value = start }
    var now: Date { lock.withLock { value } }
    func advance(minutes: Double) { lock.withLock { value = value.addingTimeInterval(minutes * 60) } }
}

final class ConnectorSyncTests: XCTestCase {
    private var root: URL!
    private var store: ConnectorStore!
    private let clock = TestClock()
    private let address = "https://school.example/feed/abc123.ics?token=SECRET"

    override func setUpWithError() throws {
        root = try Fixtures.tempDirectory()
        store = ConnectorStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func sync(_ transport: FakeTransport, secret: String? = nil, unset: Bool = false) -> ConnectorSync {
        let address = unset ? nil : (secret ?? self.address)
        let clock = self.clock
        return ConnectorSync(store: store, transport: transport, secret: { _ in address },
                             eventKit: { card, _, _ in
                                 [ConnectorItem(id: "ek-1", connector: card.id, kind: .event, title: "Dentist",
                                                start: Fixtures.utc("2026-10-20T14:00:00Z"), fetchedAt: Fixtures.now)]
                             },
                             timeZone: Fixtures.newYork, now: { clock.now })
    }

    func testFirstRefreshStoresItemsAndVersionTag() async throws {
        let card = Fixtures.card()
        try store.save(card)
        let transport = FakeTransport([.success(.fetched(Fixtures.school, etag: "\"v1\"", lastModified: "Sat, 17 Oct 2026 10:00:00 GMT"))])
        let report = await sync(transport).refresh(card)
        XCTAssertEqual(report.outcome, .updated)
        XCTAssertEqual(report.added, 4)
        XCTAssertEqual(store.items("school").count, 4)
        let state = store.state("school")
        XCTAssertEqual(state.etag, "\"v1\"")
        XCTAssertEqual(state.refreshedAt, Fixtures.now)
        XCTAssertNil(state.lastError)
        let calls = await transport.calls
        XCTAssertEqual(calls.first?.url.absoluteString, address, "the address comes from the secret, not the card")
        XCTAssertNil(calls.first?.etag)
    }

    func testNotDueIsSkippedAndTheTagIsSentBack() async throws {
        let card = Fixtures.card(refreshMinutes: 30)
        try store.save(card)
        let transport = FakeTransport([.success(.fetched(Fixtures.school, etag: "\"v1\"", lastModified: nil)), .success(.notModified)])
        let sync = sync(transport)
        _ = await sync.refresh(card)
        clock.advance(minutes: 10)
        let early = await sync.refresh(card)
        XCTAssertEqual(early.outcome, .skipped)
        clock.advance(minutes: 25)
        let later = await sync.refresh(card)
        XCTAssertEqual(later.outcome, .unchanged)
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.last?.etag, "\"v1\"")
    }

    func testForceIgnoresTimerAndTag() async throws {
        let card = Fixtures.card()
        try store.save(card)
        let transport = FakeTransport([.success(.fetched(Fixtures.school, etag: "\"v1\"", lastModified: "x")),
                                       .success(.fetched(Fixtures.school, etag: "\"v2\"", lastModified: nil))])
        let sync = sync(transport)
        _ = await sync.refresh(card)
        let report = await sync.refresh(card, force: true)
        XCTAssertEqual(report.outcome, .unchanged)
        let calls = await transport.calls
        XCTAssertNil(calls.last?.etag)
        XCTAssertNil(calls.last?.lastModified)
        XCTAssertEqual(store.state("school").etag, "\"v2\"")
    }

    func testNotModifiedStillDropsItemsThatLeftTheWindowOrTheFilter() async throws {
        let card = Fixtures.card(exclude: ["band"])
        try store.save(card)
        let stale = ConnectorItem(id: "old", connector: "school", kind: .deadline, title: "Last week's quiz",
                                  due: Fixtures.utc("2026-10-10T12:00:00Z"), fetchedAt: Fixtures.now)
        let band = ConnectorItem(id: "band", connector: "school", kind: .deadline, title: "Band practice",
                                 due: Fixtures.utc("2026-10-19T20:00:00Z"), fetchedAt: Fixtures.now)
        let kept = ConnectorItem(id: "kept", connector: "school", kind: .deadline, title: "Maths exam",
                                 due: Fixtures.utc("2026-10-27T08:00:00Z"), fetchedAt: Fixtures.now)
        try store.saveItems([stale, band, kept], for: "school")
        let report = await sync(FakeTransport([.success(.notModified)])).refresh(card)
        XCTAssertEqual(report.outcome, .updated)
        XCTAssertEqual(report.removed, 2)
        XCTAssertEqual(store.items("school").map(\.id), ["kept"])
    }

    func testMissingSecretFailsWithoutFetching() async throws {
        let card = Fixtures.card()
        try store.save(card)
        let transport = FakeTransport([])
        let report = await sync(transport, unset: true).refresh(card)
        XCTAssertEqual(report.outcome, .failed(.missingSecret))
        let calls = await transport.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(store.state("school").lastError, .missingSecret)
        XCTAssertEqual(store.state("school").failures, 0, "not transient: waits the full interval")
    }

    func testTransientFailuresBackOffAndKeepOldItems() async throws {
        let card = Fixtures.card(refreshMinutes: 60)
        try store.save(card)
        let transport = FakeTransport([.success(.fetched(Fixtures.school, etag: nil, lastModified: nil)),
                                       .failure(.network), .failure(.httpStatus(503)),
                                       .success(.fetched(Fixtures.school, etag: nil, lastModified: nil))])
        let sync = sync(transport)
        _ = await sync.refresh(card)
        clock.advance(minutes: 60)
        let offline = await sync.refresh(card)
        XCTAssertEqual(offline.outcome, .failed(.network))
        XCTAssertEqual(store.items("school").count, 4, "a failure keeps the old items")
        var state = store.state("school")
        XCTAssertEqual(state.failures, 1)
        XCTAssertEqual(state.nextRefresh(for: card), clock.now.addingTimeInterval(120))

        clock.advance(minutes: 1)
        let tooSoon = await sync.refresh(card)
        XCTAssertEqual(tooSoon.outcome, .skipped)
        clock.advance(minutes: 1)
        let busy = await sync.refresh(card)
        XCTAssertEqual(busy.outcome, .failed(.httpStatus(503)))
        state = store.state("school")
        XCTAssertEqual(state.failures, 2)
        XCTAssertEqual(state.nextRefresh(for: card), clock.now.addingTimeInterval(240))

        clock.advance(minutes: 4)
        let back = await sync.refresh(card)
        XCTAssertEqual(back.outcome, .unchanged)
        XCTAssertEqual(store.state("school").failures, 0)
        XCTAssertNil(store.state("school").lastError)
    }

    func testPermanentFailureWaitsTheInterval() async throws {
        let card = Fixtures.card(refreshMinutes: 60)
        try store.save(card)
        let report = await sync(FakeTransport([.failure(.httpStatus(404))])).refresh(card)
        XCTAssertEqual(report.outcome, .failed(.httpStatus(404)))
        let state = store.state("school")
        XCTAssertEqual(state.failures, 0)
        XCTAssertEqual(state.nextRefresh(for: card), Fixtures.now.addingTimeInterval(3_600))
        XCTAssertFalse(ConnectorError.httpStatus(404).message.contains("school.example"))
    }

    func testLoginPageIsNotACalendar() async throws {
        let card = Fixtures.card()
        try store.save(card)
        let page = Data("<html><body>Sign in</body></html>".utf8)
        let report = await sync(FakeTransport([.success(.fetched(page, etag: nil, lastModified: nil))])).refresh(card)
        XCTAssertEqual(report.outcome, .failed(.notCalendar))
    }

    func testBackoffDoublesAndIsCapped() {
        XCTAssertEqual(ConnectorState.backoff(failures: 0, interval: 1_800), 1_800)
        XCTAssertEqual(ConnectorState.backoff(failures: 1, interval: 1_800), 120)
        XCTAssertEqual(ConnectorState.backoff(failures: 3, interval: 1_800), 480)
        XCTAssertEqual(ConnectorState.backoff(failures: 5, interval: 1_800), 1_800)
        XCTAssertEqual(ConnectorState.backoff(failures: 10_000, interval: 3_600), 3_600)
        XCTAssertTrue(ConnectorError.network.isTransient)
        XCTAssertTrue(ConnectorError.httpStatus(429).isTransient)
        XCTAssertFalse(ConnectorError.httpStatus(401).isTransient)
        XCTAssertFalse(ConnectorError.missingSecret.isTransient)
    }

    func testDisabledEventKitAndUnsupported() async throws {
        let off = Fixtures.card("off", enabled: false)
        let calendar = Fixtures.card("apple", adapter: .eventkit, role: .schedule)
        let mail = Fixtures.card("mail", adapter: .imap, role: .inbox)
        for card in [off, calendar, mail] { try store.save(card) }
        let sync = sync(FakeTransport([]))
        let skipped = await sync.refresh(off)
        XCTAssertEqual(skipped.outcome, .skipped)
        let apple = await sync.refresh(calendar)
        XCTAssertEqual(apple.outcome, .updated)
        XCTAssertEqual(store.items("apple").map(\.title), ["Dentist"])
        let imap = await sync.refresh(mail)
        XCTAssertEqual(imap.outcome, .failed(.unsupported(.imap)))
    }

    func testRefreshStaleRunsAtMostFourAtOnceInCardOrder() async throws {
        let ids = (1...7).map { "feed-\($0)" }
        for id in ids { try store.save(Fixtures.card(id)) }
        try store.save(Fixtures.card("feed-off", enabled: false))
        let answers = Array(repeating: Result<FeedFetch, ConnectorError>.success(.fetched(Fixtures.school, etag: nil, lastModified: nil)),
                            count: 7)
        let transport = FakeTransport(answers, delay: 20_000_000)
        let reports = await sync(transport).refreshStale(limit: 9)
        XCTAssertEqual(reports.map(\.id), ids)
        XCTAssertTrue(reports.allSatisfy { $0.outcome == .updated })
        let widest = await transport.maxInFlight
        XCTAssertLessThanOrEqual(widest, 4)
        XCTAssertGreaterThan(widest, 1, "feeds load side by side")
        let again = await sync(transport).refreshStale()
        XCTAssertTrue(again.isEmpty, "nothing is due right after")
    }

    func testDiffCountsAddedRemovedChanged() {
        let a = ConnectorItem(id: "a", connector: "c", kind: .event, title: "A", fetchedAt: Fixtures.now)
        let b = ConnectorItem(id: "b", connector: "c", kind: .event, title: "B", fetchedAt: Fixtures.now)
        var a2 = a
        a2.title = "A2"
        var refetched = b
        refetched.fetchedAt = Fixtures.now.addingTimeInterval(60)
        XCTAssertEqual(ConnectorSync.diff(old: [a, b], new: [a, refetched], id: "c").outcome, .unchanged)
        let report = ConnectorSync.diff(old: [a, b], new: [a2], id: "c")
        XCTAssertEqual(report.outcome, .updated)
        XCTAssertEqual([report.added, report.removed, report.changed], [0, 1, 1])
    }
}
