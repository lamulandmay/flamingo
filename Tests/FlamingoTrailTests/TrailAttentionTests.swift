import XCTest
import FlamingoCore
@testable import FlamingoTrail

final class TrailAttentionTests: TrailStoreTestCase {
    func record(_ store: TrailStore, _ events: [TrailEvent]) { events.forEach(store.record) }

    func testTimeOnAFileIsUntilTheNextEvent() throws {
        let store = makeStore()
        record(store, [
            ev(.opened, 0, file: "a.md"), ev(.opened, 120, file: "b.md"), ev(.opened, 150, file: "a.md"),
            ev(.opened, 330, file: "b.md"),
        ])
        let now = trailBase.addingTimeInterval(400)
        let spent = try store.attention(on: [ref("a.md"), ref("b.md"), ref("c.md")], since: trailBase, now: now)
        XCTAssertEqual(spent[ref("a.md")], 120 + 180)
        XCTAssertEqual(spent[ref("b.md")], 30 + 70, "the last open lasts until now")
        XCTAssertNil(spent[ref("c.md")])
    }

    func testAnOpenWindowIsCappedAtTenMinutes() throws {
        let store = makeStore()
        record(store, [ev(.opened, 0, file: "a.md"), ev(.opened, 3 * 3600, file: "b.md")])
        let spent = try store.attention(on: [ref("a.md")], since: trailBase, now: trailBase.addingTimeInterval(4 * 3600))
        XCTAssertEqual(spent[ref("a.md")], TrailStore.attentionCap)
    }

    func testOnlyOpensAtOrAfterSinceCount() throws {
        let store = makeStore()
        record(store, [ev(.opened, 0, file: "a.md"), ev(.opened, 100, file: "b.md"), ev(.opened, 200, file: "a.md"), ev(.opened, 260, file: "b.md")])
        let spent = try store.attention(on: [ref("a.md")], since: trailBase.addingTimeInterval(150), now: trailBase.addingTimeInterval(300))
        XCTAssertEqual(spent[ref("a.md")], 60)
    }

    func testWritingAThoughtIsNotAttention() throws {
        let store = makeStore()
        record(store, [ev(.opened, 0, file: "a.md"), ev(.commented, 30, file: "a.md", text: "a thought"), ev(.opened, 60, file: "b.md")])
        let spent = try store.attention(on: [ref("a.md")], since: trailBase.addingTimeInterval(30), now: trailBase.addingTimeInterval(100))
        XCTAssertNil(spent[ref("a.md")], "the comment itself and the time after it are not an open")
    }

    func testPureVersionMatchesTheStoreAndNeedsNoFile() {
        let events = opens(["a.md", "b.md", "a.md"], step: 60)
        let now = trailBase.addingTimeInterval(300)
        let spent = TrailStore.attention(in: events, on: [ref("a.md")], since: trailBase, now: now)
        XCTAssertEqual(spent[ref("a.md")], 60 + 180)
        XCTAssertTrue(TrailStore.attention(in: events, on: [], since: trailBase, now: now).isEmpty)
    }

    func testLastOpened() throws {
        let store = makeStore()
        record(store, [ev(.opened, 0, file: "a.md"), ev(.opened, 50, file: "b.md"), ev(.opened, 90, file: "a.md"), ev(.commented, 200, file: "b.md", text: "x")])
        XCTAssertEqual(try store.lastOpened(ref("a.md")), trailBase.addingTimeInterval(90))
        XCTAssertEqual(try store.lastOpened(ref("b.md")), trailBase.addingTimeInterval(50), "a comment is not an open")
        XCTAssertNil(try store.lastOpened(ref("c.md")))
        let both = try store.lastOpened(of: [ref("a.md"), ref("b.md"), ref("c.md")])
        XCTAssertEqual(both.count, 2)
        XCTAssertTrue(try store.lastOpened(of: []).isEmpty)
    }
}
