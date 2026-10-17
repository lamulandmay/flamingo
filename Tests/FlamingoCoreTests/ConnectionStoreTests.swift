import XCTest
@testable import FlamingoCore

final class ConnectionStoreTests: XCTestCase {
    private func vault() throws -> Vault {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("connections-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Vault(root: root)
    }

    func testPairsPersistDeduplicateAndRemoveWithoutTouchingSources() throws {
        let v = try vault(), store = ConnectionStore(vault: v)
        let files = ["A one.md", "B.md", "子/C.pdf"].map { FileRef(relativePath: $0) }
        try write(files, in: v)
        let saved = try store.setConnections(between: files + [files[0]], connected: true, label: "same question")
        XCTAssertEqual(saved.count, 3)
        XCTAssertTrue(saved.allSatisfy { $0.label == "same question" && $0.origin == "Graph" })
        XCTAssertEqual(try ConnectionStore(vault: v).all(), saved)
        XCTAssertTrue(try store.edges().allSatisfy { $0.kind == .manual })
        XCTAssertEqual(try store.setConnections(between: files, connected: true), saved)
        XCTAssertEqual(try store.setConnections(between: [files[0], files[1]], connected: false).count, 2)
        for file in files {
            XCTAssertEqual(try String(contentsOf: v.url(for: file), encoding: .utf8), "Original source bytes")
            XCTAssertNotNil(try FileIdentity.existingID(for: v.url(for: file)))
        }
    }

    func testFolderRelocationKeepsMetadataAndRejectsUnsafePaths() throws {
        let store = ConnectionStore(vault: try vault())
        let files = [FileRef(relativePath: "old/a.md"), FileRef(relativePath: "z.md")]
        try write(files, in: store.vault)
        let before = try store.setConnections(between: files, connected: true)
        try store.reconcile(oldPath: "old", newPath: "new folder")
        let after = try store.all()
        XCTAssertEqual(after.first?.source, "new folder/a.md")
        XCTAssertEqual(after.first?.createdAt, before.first?.createdAt)
        XCTAssertThrowsError(try store.setConnections(between: [.init(relativePath: "../escape")], connected: true))
        XCTAssertThrowsError(try store.reconcile(oldPath: "new folder", newPath: ".flamingo"))
    }

    func testCorruptStoreIsNotSilentlyOverwritten() throws {
        let store = ConnectionStore(vault: try vault())
        try FileManager.default.createDirectory(at: store.vault.stateDir, withIntermediateDirectories: true)
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: store.fileURL)
        XCTAssertThrowsError(try store.setConnections(between: [.init(relativePath: "a"), .init(relativePath: "b")], connected: true))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), corrupt)
    }

    func testMissingEndpointPreventsSavingAndRemovedFilesCanStillBeDisconnected() throws {
        let v = try vault(), store = ConnectionStore(vault: v)
        let files = [FileRef(relativePath: "a.md"), FileRef(relativePath: "b.md")]
        try write([files[0]], in: v)
        XCTAssertThrowsError(try store.setConnections(between: files, connected: true))
        XCTAssertTrue(try store.all().isEmpty)
        try write([files[1]], in: v)
        try store.setConnections(between: files, connected: true)
        try FileManager.default.removeItem(at: v.url(for: files[1]))
        XCTAssertTrue(try store.setConnections(between: files, connected: false).isEmpty)
    }

    func testSnapshotReplacementPreservesMetadataAndRejectsNewerChanges() throws {
        let v = try vault(), store = ConnectionStore(vault: v)
        let files = ["a.md", "b.md", "c.md"].map { FileRef(relativePath: $0) }
        try write(files, in: v)
        let first = try store.setConnections(between: Array(files.prefix(2)), connected: true, label: "keep this label")
        try store.replaceConnections([], expecting: first)
        XCTAssertTrue(try store.all().isEmpty)
        try store.replaceConnections(first, expecting: [])
        XCTAssertEqual(try store.all(), first)
        let newer = try ConnectionStore(vault: v).setConnections(between: Array(files.suffix(2)), connected: true)
        XCTAssertThrowsError(try store.replaceConnections([], expecting: first))
        XCTAssertEqual(try store.all(), newer)
    }

    func testUndoableConnectionChangeCapturesExactBeforeAndAfter() throws {
        let v = try vault(), store = ConnectionStore(vault: v)
        let files = ["a.md", "b.md", "c.md"].map { FileRef(relativePath: $0) }
        try write(files, in: v)
        let existing = try store.setConnections(between: Array(files.prefix(2)), connected: true, label: "existing")
        let change = try store.setConnectionsUndoably(between: Array(files.suffix(2)), connected: true, label: "new")
        XCTAssertEqual(change.before, existing)
        XCTAssertEqual(change.after, try store.all())
        try store.replaceConnections(change.before, expecting: change.after)
        XCTAssertEqual(try store.all(), existing)
    }

    func testSnapshotReplacementRejectsInvalidPathsAndCorruptCurrentState() throws {
        let store = ConnectionStore(vault: try vault())
        let invalid = ManualConnection(source: "../escape", target: "b.md")
        XCTAssertThrowsError(try store.replaceConnections([invalid], expecting: []))
        XCTAssertTrue(try store.all().isEmpty)
        try FileManager.default.createDirectory(at: store.vault.stateDir, withIntermediateDirectories: true)
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: store.fileURL)
        XCTAssertThrowsError(try store.replaceConnections([], expecting: []))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), corrupt)
    }

    private func write(_ files: [FileRef], in vault: Vault) throws {
        for file in files {
            let url = vault.url(for: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Original source bytes".utf8).write(to: url)
        }
    }
}
