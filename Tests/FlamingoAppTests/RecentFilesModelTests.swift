import XCTest
import FlamingoCore
import FlamingoTrail
@testable import Flamingo

@MainActor
final class RecentFilesModelTests: XCTestCase {
    private var root: URL!
    private var vault: Vault!
    private var trail: TrailStore!
    private var savedEnabled: Any?

    override func setUpWithError() throws {
        savedEnabled = UserDefaults.standard.object(forKey: TrailStore.enabledDefaultsKey)
        TrailStore.isEnabled = true
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Flamingo-RecentsTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vault = Vault(root: root)
        trail = TrailStore(vault: vault)
        trail.flushDelay = 0.05
    }

    override func tearDown() {
        if let savedEnabled { UserDefaults.standard.set(savedEnabled, forKey: TrailStore.enabledDefaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: TrailStore.enabledDefaultsKey) }
        trail = nil
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ name: String, modified: Date? = nil) throws -> FileRef {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return FileRef(relativePath: name)
    }

    private func model() -> RecentFilesModel {
        let m = RecentFilesModel()
        m.debounce = 0.02
        m.attach(trail: trail, vault: vault)
        return m
    }

    private func wait(_ condition: @autoclosure () -> Bool, _ message: String = "", timeout: TimeInterval = 5) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), message)
    }

    func testDeletedFileDisappearsAfterRefresh() async throws {
        let a = try write("a.md"), b = try write("b.md")
        trail.record(TrailEvent(at: Date().addingTimeInterval(-60), kind: .opened, file: a))
        trail.record(TrailEvent(at: Date().addingTimeInterval(-30), kind: .opened, file: b))
        let m = model()
        await m.refresh()
        XCTAssertEqual(m.items.map(\.id), ["b.md", "a.md"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("b.md"))
        await m.refresh()
        XCTAssertEqual(m.items.map(\.id), ["a.md"])
    }

    func testFileChangedAfterItsLastOpenIsEdited() async throws {
        let opened = Date().addingTimeInterval(-3600)
        let a = try write("a.md", modified: opened.addingTimeInterval(-86_400))
        let b = try write("b.md", modified: opened.addingTimeInterval(-86_400))
        trail.record(TrailEvent(at: opened, kind: .opened, file: a))
        trail.record(TrailEvent(at: opened, kind: .opened, file: b))
        let m = model()
        await m.refresh()
        XCTAssertEqual(m.items.map(\.edited), [false, false])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)],
                                              ofItemAtPath: root.appendingPathComponent("a.md").path)
        await m.refresh()
        let item = try XCTUnwrap(m.items.first { $0.file == a })
        XCTAssertTrue(item.edited)
        XCTAssertGreaterThan(try XCTUnwrap(item.lastTouched), opened, "an outside edit refreshes recency")
        XCTAssertFalse(try XCTUnwrap(m.items.first { $0.file == b }).edited)
        XCTAssertEqual(m.items.first?.file, a, "the edited file rises")
    }

    func testEmptyTrailFallsBackToOpenFilesThenHistoryWithoutTimes() async throws {
        let files = try ["a.md", "b.md", "c.md"].map { try write($0) }
        let m = model()
        m.fallback = { [files[2], files[0], files[1], FileRef(relativePath: "missing.md"), files[2]] }
        await m.refresh()
        XCTAssertEqual(m.items.map(\.id), ["c.md", "a.md", "b.md"], "deduplicated, missing files dropped")
        XCTAssertTrue(m.items.allSatisfy { $0.lastTouched == nil && !$0.edited })
    }

    func testTrailItemsComeFirstAndFallbackFillsTheRest() async throws {
        let a = try write("a.md"), b = try write("b.md")
        trail.record(TrailEvent(at: Date().addingTimeInterval(-60), kind: .opened, file: a))
        let m = model()
        m.fallback = { [b, a] }
        await m.refresh()
        XCTAssertEqual(m.items.map(\.id), ["a.md", "b.md"])
        XCTAssertNotNil(m.items[0].lastTouched)
        XCTAssertNil(m.items[1].lastTouched)
    }

    func testRingExcludesTheActiveFileAndCapsAtEight() async throws {
        let files = try (0..<12).map { try write("f\($0).md") }
        let m = model()
        m.fallback = { files }
        await m.refresh()
        XCTAssertEqual(m.ring(excluding: nil).count, 8)
        XCTAssertFalse(m.ring(excluding: files[0]).contains { $0.file == files[0] })
        XCTAssertEqual(m.ring(excluding: files[0]).first?.file, files[1])
    }

    func testOnlyTheSessionsOwnStoreTriggersARefresh() async throws {
        let a = try write("a.md")
        let m = model()
        await wait(m.refreshCount >= 1, "attach refreshes once")
        try await Task.sleep(nanoseconds: 100_000_000)
        let baseline = m.refreshCount

        // A temporary store on another vault, as capture makes, posts the same notification.
        let other = TrailStore(vault: Vault(root: root.appendingPathComponent("elsewhere")))
        NotificationCenter.default.post(name: TrailStore.didChangeNotification, object: other)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(m.refreshCount, baseline, "a foreign store is ignored")

        trail.record(TrailEvent(kind: .opened, file: a))
        await wait(m.refreshCount == baseline + 1, "the session's own store refreshes once")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(m.refreshCount, baseline + 1)
        XCTAssertEqual(m.items.map(\.id), ["a.md"])
    }
}
