import XCTest
@testable import FlamingoConnectors

final class ConnectorStoreTests: XCTestCase {
    private var root: URL!
    private var store: ConnectorStore!

    override func setUpWithError() throws {
        root = try Fixtures.tempDirectory()
        store = ConnectorStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func item(_ id: String, _ connector: String, _ kind: ConnectorItem.Kind, _ title: String, _ iso: String) -> ConnectorItem {
        let date = Fixtures.utc(iso)
        return ConnectorItem(id: id, connector: connector, kind: kind, title: title, start: kind == .event ? date : nil,
                             due: kind == .event ? nil : date, fetchedAt: Fixtures.now)
    }

    func testCardRoundTripIsClampedAndSorted() throws {
        var wild = Fixtures.card("zebra", refreshMinutes: 1)
        wild.name = "  Zebra  "
        wild.window = ConnectorWindow(daysBack: -4, daysAhead: 9_999)
        wild.weight = .nan
        wild.include = [" exam ", "Exam", "", "essay"]
        try store.save(wild)
        try store.save(Fixtures.card("apple"))
        let saved = try XCTUnwrap(store.card("zebra"))
        XCTAssertEqual(saved.name, "Zebra")
        XCTAssertEqual(saved.refreshMinutes, 5)
        XCTAssertEqual(saved.window, ConnectorWindow(daysBack: 0, daysAhead: 366))
        XCTAssertEqual(saved.weight, 1)
        XCTAssertEqual(saved.include, ["exam", "essay"])
        XCTAssertEqual(store.cards().map(\.id), ["apple", "zebra"])
    }

    func testUnknownKeysSurviveASave() throws {
        let json = #"{"id":"future","name":"Future","adapter":"ical","source":"https://x.example","colour":"teal","rank":{"a":[1,true,null]}}"#
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: root.appendingPathComponent("future.json"))
        var card = try XCTUnwrap(store.card("future"))
        XCTAssertEqual(card.role, .reference)
        XCTAssertEqual(card.refreshMinutes, 30)
        card.name = "Renamed"
        try store.save(card)
        let text = try String(contentsOf: root.appendingPathComponent("future.json"), encoding: .utf8)
        XCTAssertTrue(text.contains("\"colour\" : \"teal\""))
        XCTAssertTrue(text.contains("\"rank\""))
        XCTAssertEqual(store.card("future")?.name, "Renamed")
    }

    func testBrokenAndMisnamedFilesAreSkipped() throws {
        try store.save(Fixtures.card("good"))
        try Data("{not json".utf8).write(to: root.appendingPathComponent("broken.json"))
        let other = try Data(contentsOf: root.appendingPathComponent("good.json"))
        try other.write(to: root.appendingPathComponent("copy.json"))
        try other.write(to: root.appendingPathComponent("Bad Name.json"))
        XCTAssertEqual(store.cards().map(\.id), ["good"])
        XCTAssertNil(store.card("copy"), "a file whose name isn't its id")
    }

    func testIDsCantLeaveTheRoot() {
        for bad in ["", "../x", "a/b", "-lead", "UPPER", "a b", String(repeating: "a", count: 49), "café"] {
            XCTAssertFalse(ConnectorStore.isValidID(bad), bad)
        }
        XCTAssertTrue(ConnectorStore.isValidID("managebac-2"))
        XCTAssertThrowsError(try store.save(Fixtures.card("../escape"))) { XCTAssertEqual($0 as? ConnectorError, .invalidID) }
        XCTAssertThrowsError(try store.saveItems([], for: "a/b"))
        XCTAssertThrowsError(try store.delete(".."))
        XCTAssertTrue(store.items("../x").isEmpty)
        XCTAssertEqual(store.state("../x"), ConnectorState())
    }

    func testFreshIDCountsUpWithoutTrailingDash() throws {
        try store.save(Fixtures.card("school-calendar"))
        XCTAssertEqual(store.freshID(for: "School Calendar"), "school-calendar-2")
        try store.save(Fixtures.card("school-calendar-2"))
        XCTAssertEqual(store.freshID(for: "School Calendar"), "school-calendar-3")
        XCTAssertEqual(store.freshID(for: "Something else"), "something-else")

        let long = String(repeating: "a", count: 45) + " bcd"
        let base = PurposeCard.slug(long)
        XCTAssertEqual(base, String(repeating: "a", count: 45) + "-bc")
        try store.save(Fixtures.card(base))
        let next = store.freshID(for: long)
        XCTAssertEqual(next, String(repeating: "a", count: 45) + "-2", "the cut stem loses its dash")
        XCTAssertTrue(ConnectorStore.isValidID(next))
    }

    func testDeleteRemovesCardItemsAndState() throws {
        try store.save(Fixtures.card())
        try store.saveItems([item("a", "school", .deadline, "Essay", "2026-10-20T12:00:00Z")], for: "school")
        try store.saveState(ConnectorState(etag: "x", refreshedAt: Fixtures.now), for: "school")
        XCTAssertEqual(store.items("school").count, 1)
        XCTAssertEqual(store.state("school").etag, "x")
        try store.delete("school")
        XCTAssertNil(store.card("school"))
        XCTAssertTrue(store.items("school").isEmpty)
        XCTAssertNil(store.state("school").refreshedAt)
        XCTAssertNoThrow(try store.delete("school"), "deleting twice is fine")
    }

    func testStateToleratesAnErrorFromAnotherVersion() throws {
        try store.saveState(ConnectorState(etag: "v", refreshedAt: Fixtures.now, lastError: .httpStatus(500), failures: 2), for: "a")
        XCTAssertEqual(store.state("a").lastError, .httpStatus(500))
        let json = #"{"etag":"v","refreshedAt":1792324800,"lastError":{"somethingNew":{}},"failures":3}"#
        try Data(json.utf8).write(to: store.stateURL("a"))
        let state = store.state("a")
        XCTAssertEqual(state.etag, "v")
        XCTAssertNil(state.lastError)
        XCTAssertEqual(state.failures, 3)
        XCTAssertEqual(state.refreshedAt, Fixtures.now)
    }

    func testAllItemsDedupesAcrossConnectors() throws {
        try store.save(Fixtures.card("planner", role: .deadlines))
        try store.save(Fixtures.card("calendar", role: .schedule))
        try store.save(Fixtures.card("hidden", enabled: false))
        try store.saveItems([item("p1", "planner", .deadline, "Maths Exam", "2026-10-27T08:00:00Z"),
                             item("p2", "planner", .deadline, "Essay", "2026-10-21T12:00:00Z")], for: "planner")
        try store.saveItems([item("c1", "calendar", .event, "maths exam", "2026-10-27T08:00:00Z"),
                             item("c2", "calendar", .event, "Maths exam", "2026-11-03T08:00:00Z"),
                             item("c3", "calendar", .event, "Café", "2026-10-19T08:00:00Z")], for: "calendar")
        try store.saveItems([item("h1", "hidden", .deadline, "Secret", "2026-10-19T08:00:00Z")], for: "hidden")
        let all = store.allItems()
        XCTAssertEqual(all.map(\.id), ["c3", "p2", "p1", "c2"],
                       "same title at the same time once, the deadline kept; another time stays; disabled cards hidden")
    }

    func testDefaultRootNeverTheRealOneOutsideTheApp() {
        let support = URL(fileURLWithPath: "/tmp/support", isDirectory: true)
        XCTAssertEqual(ConnectorStore.defaultRoot(bundleID: "com.flamingo.app", testing: false, support: support).path,
                       "/tmp/support/Flamingo/Connectors")
        XCTAssertEqual(ConnectorStore.defaultRoot(bundleID: "com.flamingo.app", testing: true, support: support).lastPathComponent,
                       "Connectors-tests-com.flamingo.app")
        XCTAssertEqual(ConnectorStore.defaultRoot(bundleID: "com.flamingo.qa index", testing: false, support: support).lastPathComponent,
                       "Connectors-com.flamingo.qa_index")
        XCTAssertEqual(ConnectorStore.defaultRoot(bundleID: nil, process: "flamingo-cli", testing: false, support: support).lastPathComponent,
                       "Connectors-flamingo-cli")
        XCTAssertNotEqual(ConnectorStore.defaultRoot(support: support).lastPathComponent, "Connectors", "this test run")
    }
}
