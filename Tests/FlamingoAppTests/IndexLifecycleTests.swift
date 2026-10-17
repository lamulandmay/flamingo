import XCTest
import FlamingoCore
@testable import FlamingoIndex
@testable import Flamingo

final class IndexLifecycleTests: XCTestCase {
    private func temporaryVault() throws -> Vault {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flamingo-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Vault(root: root)
    }

    @MainActor
    func testFailedScanPreservesIndexAndReportsErrorUntilSuccessfulRetry() async throws {
        let vault = try temporaryVault()
        let moved = vault.root.appendingPathExtension("temporarily-moved")
        defer { try? FileManager.default.removeItem(at: vault.root); try? FileManager.default.removeItem(at: moved) }
        let file = FileRef(relativePath: "brief.txt")
        try Data("remembered words".utf8).write(to: vault.url(for: file))
        let session = VaultSession(vault: vault)
        defer { session.stop() }
        let updated = await session.update([file])
        XCTAssertTrue(updated)
        try FileManager.default.moveItem(at: vault.root, to: moved)
        let failed = await session.reindex { _ in XCTFail("A failed empty scan must not report completed progress") }
        guard case .failed = failed else { return XCTFail("Expected a visible indexing failure") }
        XCTAssertNotNil(session.indexingError)
        try FileManager.default.moveItem(at: moved, to: vault.root)
        XCTAssertEqual(try session.index?.indexedFiles(), [file])
        let retry = await session.reindex { _ in }
        XCTAssertEqual(retry, .completed)
        XCTAssertNil(session.indexingError)
    }

    @MainActor
    func testCombinedSearchHonorsFinalLimitAndIncludesAdmittedDotFile() async throws {
        let vault = try temporaryVault()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        let session = VaultSession(vault: vault)
        defer { session.stop() }
        let files = [".flamingo-notes.txt", "needle.txt", "another.txt"].map(FileRef.init(relativePath:))
        for file in files { try Data("needle content".utf8).write(to: vault.url(for: file)) }
        _ = await session.update(files)
        try await session.append(Comment(text: "needle thought"), to: files[0])
        _ = await session.update([files[0]])
        let hits = try await session.searchAll("needle", limit: 2)
        XCTAssertEqual(hits.count, 2)
        XCTAssertTrue(try session.index!.indexedFiles().contains(files[0]))
        let empty = try await session.searchAll("needle", limit: 0)
        XCTAssertEqual(empty, [])
    }

    @MainActor
    func testWatcherEventsBeforeFirstListingAreReplayedBeforePublishing() async throws {
        let vault = try temporaryVault()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        let old = FileRef(relativePath: "old.txt"), new = FileRef(relativePath: "new.txt")
        try Data().write(to: vault.url(for: old))
        let visited = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        let session = VaultSession(vault: vault, fileScanner: { _, _, visit in
            _ = visit(old)
            visited.signal()
            _ = proceed.wait(timeout: .now() + 5)
        })
        defer { proceed.signal(); session.stop() }
        let scan = Task { await session.listFiles() }
        let reached = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: visited.wait(timeout: .now() + 5) == .success)
            }
        }
        XCTAssertTrue(reached)
        try FileManager.default.removeItem(at: vault.url(for: old))
        try Data().write(to: vault.url(for: new))
        let early = await session.applyDiskChanges([old, new])
        XCTAssertNil(early)
        proceed.signal()
        let result = await scan.value
        XCTAssertEqual(result.1, [new])
        XCTAssertEqual(result.0, [new])
    }

    @MainActor
    func testFolderEventRemovesDeletedChildrenWithoutDuplicateAdditions() async throws {
        let vault = try temporaryVault()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        try FileManager.default.createDirectory(at: vault.root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        let old = FileRef(relativePath: "docs/old.txt"), new = FileRef(relativePath: "docs/new.txt")
        try Data().write(to: vault.url(for: old))
        let session = VaultSession(vault: vault)
        defer { session.stop() }
        _ = await session.listFiles()
        try FileManager.default.removeItem(at: vault.url(for: old))
        try Data().write(to: vault.url(for: new))
        let result = await session.applyDiskChanges([FileRef(relativePath: "docs"), new])
        XCTAssertEqual(result?.0, [new])
        XCTAssertEqual(result?.1, [new])
    }
    @MainActor
    func testCompletedWalkLetsTheNextOpenReplayInsteadOfWalking() async throws {
        let vault = try temporaryVault()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        try Data("first words".utf8).write(to: vault.root.appendingPathComponent("first.txt"))
        let first = VaultSession(vault: vault)
        XCTAssertFalse(first.startWatching(), "a new index has nothing to resume from")
        let walked = await first.reindex { _ in }
        XCTAssertEqual(walked, .completed)
        XCTAssertNotNil(first.checkpoint)
        first.stop()

        // An extractor update while closed leaves rows stale; reopening replays and re-reads
        // just those, without a walk.
        let index = try IndexStore(vault: vault)
        try index.writer.run("UPDATE files SET size = -1")
        let second = VaultSession(vault: vault)
        defer { second.stop() }
        XCTAssertTrue(second.startWatching(), "the walk left a checkpoint to replay from")
        var last: VaultSession.IndexStatus?
        let outcome = await second.refreshStale(through: nil) { last = $0 }
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(last?.phase, .refreshing)
        XCTAssertEqual(last?.read, 1)
        XCTAssertEqual(try second.index?.staleFiles(), [])
    }

    @MainActor
    func testLostEventsMeanTheNextOpenWalks() async throws {
        let vault = try temporaryVault()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        let first = VaultSession(vault: vault)
        _ = first.startWatching()
        _ = await first.reindex { _ in }
        first.distrustCheckpoint()
        _ = await first.update([FileRef(relativePath: "absent.txt")])   // drains the index queue
        first.stop()
        let second = VaultSession(vault: vault)
        defer { second.stop() }
        XCTAssertFalse(second.startWatching())
    }

    @MainActor
    func testCancellationAfterCommittedBatchDoesNotPruneUnseenRows() async throws {
        let vault = try temporaryVault()
        defer { try? FileManager.default.removeItem(at: vault.root) }
        let session = VaultSession(vault: vault)
        defer { session.stop() }
        let old = FileRef(relativePath: "previous.txt")
        try Data("previous indexed source".utf8).write(to: vault.url(for: old))
        _ = await session.update([old])
        try FileManager.default.removeItem(at: vault.url(for: old))
        for n in 0..<600 {
            try Data("new text".utf8).write(to: vault.root.appendingPathComponent("new-\(n).txt"))
        }
        let outcome = await session.reindex { status in
            if status.files >= VaultSession.reindexBatch { session.cancelIndexing() }
        }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(try session.index!.indexedFiles().contains(old))
        XCTAssertNil(session.indexingError)
    }

}
