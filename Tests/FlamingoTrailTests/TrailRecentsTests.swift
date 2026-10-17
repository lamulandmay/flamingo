import XCTest
import FlamingoCore
@testable import FlamingoTrail

final class TrailRecentsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ev(_ kind: TrailEvent.Kind, ago: TimeInterval, _ file: String?, anchor: FileAnchor? = nil) -> TrailEvent {
        TrailEvent(at: now.addingTimeInterval(-ago), kind: kind, file: file.map { FileRef(relativePath: $0) }, anchor: anchor,
                   text: kind == .commented ? "t" : (kind == .searched ? "q" : (kind == .linked ? "x" : nil)))
    }
    private func order(_ events: [TrailEvent], limit: Int = 24) -> [String] {
        TrailRecents.rank(events, now: now, limit: limit).map(\.id)
    }
    private let minute = 60.0, hour = 3600.0, day = 86_400.0

    func testOneRecentOpenBeatsManyOldOnes() {
        var events = [ev(.opened, ago: 10 * minute, "new.md")]
        for d in 1...5 { events.append(ev(.opened, ago: 6 * day + Double(d) * hour * 2, "old.md")) }
        XCTAssertEqual(order(events), ["new.md", "old.md"])
    }

    func testSavedBeatsCommentedBeatsOpenedAtEqualTimes() {
        let events = [ev(.opened, ago: hour, "o.md"), ev(.commented, ago: hour, "c.md"), ev(.saved, ago: hour, "s.md")]
        // Commented outweighs saved in frequency (2.5 vs 2), and both outrank opened.
        let ranked = order(events)
        XCTAssertEqual(ranked.last, "o.md")
        XCTAssertEqual(Set(ranked.prefix(2)), ["s.md", "c.md"])
        let scores = Dictionary(uniqueKeysWithValues: TrailRecents.rank(events, now: now, limit: 9).map { ($0.id, $0.score) })
        XCTAssertGreaterThan(scores["s.md"]!, scores["o.md"]!)
        XCTAssertGreaterThan(scores["c.md"]!, scores["s.md"]!)
    }

    func testBurstOfOpensCountsOnce() {
        let burst = (0..<30).map { ev(.opened, ago: 10 * minute - Double($0) * 10, "a.md") }
        let single = [ev(.opened, ago: 10 * minute - 290, "a.md")]
        let a = TrailRecents.rank(burst, now: now, limit: 1)[0].score
        let b = TrailRecents.rank(single, now: now, limit: 1)[0].score
        XCTAssertEqual(a, b, accuracy: 1e-9)
        // Opens an hour apart are separate bursts.
        let spaced = [ev(.opened, ago: hour, "a.md"), ev(.opened, ago: 2 * hour, "a.md")]
        XCTAssertGreaterThan(TrailRecents.rank(spaced, now: now, limit: 1)[0].score,
                             TrailRecents.rank([spaced[0]], now: now, limit: 1)[0].score)
    }

    func testIgnoredEvents() {
        let events = [ev(.searched, ago: minute, nil), ev(.searched, ago: minute, "s.md"),
                      ev(.opened, ago: minute, ".flamingo/notes/a.md"), ev(.opened, ago: minute, nil),
                      ev(.opened, ago: minute, "real.md")]
        XCTAssertEqual(order(events), ["real.md"])
    }

    func testAnchorsAndEditedAndThoughts() {
        let slide = FileAnchor(kind: .slide, value: "7"), page = FileAnchor(kind: .page, value: "2")
        let events = [ev(.opened, ago: 5 * hour, "d.pptx", anchor: page),
                      ev(.commented, ago: 3 * hour, "d.pptx", anchor: slide),
                      ev(.opened, ago: hour, "d.pptx")]
        let r = TrailRecents.rank(events, now: now, limit: 1)[0]
        XCTAssertEqual(r.lastAnchor, slide, "latest event that has an anchor")
        XCTAssertEqual(r.lastTouched, now.addingTimeInterval(-hour))
        XCTAssertEqual(r.lastOpened, now.addingTimeInterval(-hour))
        XCTAssertEqual(r.lastEdited, now.addingTimeInterval(-3 * hour))
        XCTAssertEqual(r.thoughts, 1)
        XCTAssertNil(TrailRecents.rank([ev(.opened, ago: hour, "x.md")], now: now, limit: 1)[0].lastEdited)
    }

    func testWindowLimitTiesAndUnsortedInput() {
        let events = [ev(.opened, ago: 40 * day, "ancient.md"), ev(.opened, ago: hour, "b.md"), ev(.opened, ago: hour, "a.md"),
                      ev(.opened, ago: 2 * hour, "c.md")]
        XCTAssertEqual(order(events), ["a.md", "b.md", "c.md"], "ancient dropped, ties break by path")
        XCTAssertEqual(order(events, limit: 2), ["a.md", "b.md"])
        XCTAssertEqual(order(events.reversed(), limit: 3), ["a.md", "b.md", "c.md"])
        XCTAssertTrue(order(events, limit: 0).isEmpty)
    }

    func testPerformanceOnHundredThousandEvents() {
        var events: [TrailEvent] = []
        events.reserveCapacity(100_000)
        for i in 0..<100_000 {
            events.append(TrailEvent(at: now.addingTimeInterval(-Double(i % 20_000) * 60), kind: i % 3 == 0 ? .saved : .opened,
                                     file: FileRef(relativePath: "dir\(i % 50)/file\(i % 4_000).md")))
        }
        let start = Date()
        let ranked = TrailRecents.rank(events, now: now, limit: 24)
        XCTAssertEqual(ranked.count, 24)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
    }

    func testStoreRecentFilesFiltersByDate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recents-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TrailStore(vault: Vault(root: dir))
        store.record(TrailEvent(at: Date().addingTimeInterval(-60), kind: .opened, file: FileRef(relativePath: "a.md")))
        store.record(TrailEvent(at: Date().addingTimeInterval(-90 * 86_400), kind: .opened, file: FileRef(relativePath: "old.md")))
        XCTAssertEqual(try store.recentFiles().map(\.id), ["a.md"])
    }
}
