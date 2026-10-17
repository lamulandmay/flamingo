import XCTest
import FlamingoCore
@testable import FlamingoTrail

final class TrailContinuityTests: TrailStoreTestCase {
    func testRenamePreservesSessionsNamesAndAnchorsWithoutRewritingHistory() throws {
        let store = makeStore()
        let anchor = FileAnchor(kind: .slide, value: "7")
        store.record(ev(.opened, 0, file: "old/deck.pptx", anchor: anchor))
        store.record(ev(.commented, 10, file: "old/deck.pptx", text: "Evidence", anchor: anchor))
        store.flush()
        let before = try XCTUnwrap(store.sessions().first)
        try store.setTitle("Pricing", for: before)
        let raw = try Data(contentsOf: store.fileURL)
        try store.reconcile(oldPath: "old", newPath: "new folder")
        let after = try XCTUnwrap(TrailStore(vault: vault).sessions().first)
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.title, "Pricing")
        XCTAssertEqual(after.locationsToReopen, [.init(file: ref("new folder/deck.pptx"), anchor: anchor)])
        XCTAssertEqual(try Data(contentsOf: store.fileURL), raw)
        store.record(ev(.opened, 30, file: "old/deck.pptx"))
        XCTAssertEqual(try store.events().last?.file, ref("old/deck.pptx"), "Reusing a path is a new file")
        try store.reconcile(oldPath: "new folder/deck.pptx", newPath: "final.pptx")
        XCTAssertEqual(try store.events().first?.file, ref("final.pptx"))
    }

    func testBufferedEventsRelocateAndSaveResumesLastKnownAnchor() throws {
        let store = makeStore(), anchor = FileAnchor(kind: .page, value: "4")
        store.record(ev(.opened, 0, file: "a.pdf", anchor: anchor))
        store.record(ev(.saved, 20, file: "a.pdf"))
        try store.reconcile(oldPath: "a.pdf", newPath: "b.pdf")
        XCTAssertEqual(try store.events().map(\.file), [ref("b.pdf"), ref("b.pdf")])
        store.flush()
        let session = try XCTUnwrap(store.sessions().first)
        XCTAssertEqual(session.locationsToReopen, [.init(file: ref("b.pdf"), anchor: anchor)])
        XCTAssertEqual(session.events.last?.kind, .saved)
    }

    func testWikilinkAliasKeepsActualTargetAndAnchor() {
        let segments = TrailPresentation.linkSegments("Read [[folder/deck.pptx#slide=7|pricing slide]] now")
        XCTAssertEqual(segments[1].text, "pricing slide")
        XCTAssertEqual(segments[1].target, "folder/deck.pptx#slide=7")
        XCTAssertNil(segments[0].target)
    }

    func testAppendFailureVisibleAndBufferedEventsRetry() throws {
        let store = makeStore()
        try Data("not a directory".utf8).write(to: vault.stateDir)
        store.record(ev(.saved, 0, file: "a.md")); store.flush()
        XCTAssertNotNil(store.persistenceError)
        try FileManager.default.removeItem(at: vault.stateDir)
        store.flush()
        XCTAssertNil(store.persistenceError)
        XCTAssertEqual(try store.events().count, 1)
    }

    func testCorruptNamesRemainIntactOnRenameFailure() throws {
        let store = makeStore()
        store.record(ev(.opened, 0, file: "a.md"))
        let session = try XCTUnwrap(store.sessions().first)
        try FileManager.default.createDirectory(at: vault.stateDir, withIntermediateDirectories: true)
        let raw = Data("broken names".utf8); try raw.write(to: store.namesURL)
        XCTAssertThrowsError(try store.setTitle("name", for: session))
        XCTAssertEqual(try Data(contentsOf: store.namesURL), raw)
    }
}

@MainActor
final class TrailGenerationTests: XCTestCase {
    func testDetachInvalidatesPendingLoad() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trail-generation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrailStore(vault: Vault(root: root))
        try FileManager.default.createDirectory(at: store.vault.stateDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(ev(.opened, 0, file: "a.md")).write(to: store.fileURL)
        let live = TrailLiveSessions()
        live.attach(store)
        live.attach(nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(live.sessions, [])
        XCTAssertNil(live.error)
    }
}
