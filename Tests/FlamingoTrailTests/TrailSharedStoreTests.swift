import XCTest
import FlamingoCore
@testable import FlamingoTrail

/// Stores on the same vault share one buffer, cache and set of change notifications.
final class TrailSharedStoreTests: TrailStoreTestCase {

    func testStoresOnOneVaultSeeEachOthersUnflushedEvents() throws {
        let a = makeStore(), b = makeStore()
        a.recordOpened(ref("a.md"))
        XCTAssertEqual(try b.events().compactMap(\.file), [ref("a.md")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.fileURL.path))
    }

    func testThrowawayStoreFlushesAndNotifiesTheLongLivedOne() throws {
        let shell = makeStore()
        let posted = expectation(forNotification: TrailStore.didChangeNotification, object: shell)
        let comment = Comment(text: "from the capture panel")
        do {
            // What capture does: a store just for one record.
            TrailStore(vault: vault).recordComment(comment, on: ref("deck.pptx"))
        }
        XCTAssertTrue(try fileText(shell).contains(comment.id.uuidString))
        wait(for: [posted], timeout: 2)
        XCTAssertEqual(try shell.events().map(\.id), [comment.id])
    }

    func testSameCommentRecordedTwiceApartIsKeptOnce() throws {
        let store = makeStore()
        let comment = Comment(text: "once")
        store.recordComment(comment, on: ref("a.md"))
        store.recordOpened(ref("b.md"))
        store.recordComment(comment, on: ref("a.md"))
        XCTAssertEqual(try store.events().filter { $0.kind == .commented }.count, 1)
        store.flush()
        XCTAssertEqual(try fileText(store).components(separatedBy: comment.id.uuidString).count - 1, 1)
    }

    func testCommentAlreadyOnDiskIsNotWrittenAgainAfterRelaunch() throws {
        let comment = Comment(text: "survives a relaunch")
        do {
            let first = makeStore()
            first.recordComment(comment, on: ref("a.md"))
            first.flush()
        }
        // All stores are gone, so this is a fresh backend: nothing in memory about `comment`.
        let second = makeStore()
        second.recordComment(comment, on: ref("a.md"))
        XCTAssertEqual(try second.events().map(\.id), [comment.id])
        second.flush()
        XCTAssertEqual(try fileText(second).components(separatedBy: comment.id.uuidString).count - 1, 1)
    }

    func testInPlaceRewriteThatGrowsTheFileIsNoticed() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: vault.stateDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        func lines(_ events: [TrailEvent]) throws -> Data {
            var d = Data()
            for e in events { d.append(try enc.encode(e)); d.append(0x0A) }
            return d
        }
        let before = opens(["a.md", "b.md"])
        try lines(before).write(to: store.fileURL)
        XCTAssertEqual(try store.events().map(\.id), before.map(\.id))

        // Overwrite from offset 0 without truncating or replacing the inode, ending longer.
        let after = opens(["x.md", "y.md", "z.md"], from: 100)
        let h = try FileHandle(forWritingTo: store.fileURL)
        try h.write(contentsOf: try lines(after))
        try h.close()
        XCTAssertEqual(try store.events().map(\.id), after.map(\.id))
    }

    func testStoresOnDifferentVaultsAreIndependent() throws {
        let otherRoot = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let a = makeStore()
        let b = TrailStore(vault: Vault(root: otherRoot))
        a.recordOpened(ref("a.md"))
        XCTAssertEqual(try b.events(), [])
    }
}
