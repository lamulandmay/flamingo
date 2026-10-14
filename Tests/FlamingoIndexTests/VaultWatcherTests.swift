import XCTest
import CoreServices
@testable import FlamingoIndex
import FlamingoCore

final class VaultWatcherTests: XCTestCase {
    private let created = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
    private let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)

    private func classify(_ p: String, _ f: Int, isPackage: @escaping (String) -> Bool = { _ in false }) -> VaultWatcher.Classified? {
        VaultWatcher.classify(relativePath: p, flags: FSEventStreamEventFlags(f), isPackage: isPackage)
    }

    func testSidecarMapsToTarget() {
        let c = VaultWatcher.classify(relativePath: ".flamingo/notes/a/b.pdf.md", flags: modified)
        XCTAssertEqual(c, .init(ref: FileRef(relativePath: "a/b.pdf"), sidecar: true))
    }

    func testStateDirOtherwiseIgnored() {
        XCTAssertNil(VaultWatcher.classify(relativePath: ".flamingo/index.sqlite", flags: modified))
        XCTAssertNil(VaultWatcher.classify(relativePath: ".flamingo/notes/a.pdf.txt", flags: modified))
        XCTAssertNil(VaultWatcher.classify(relativePath: ".flamingo/notes/.a.pdf.md.tmp", flags: modified))
        XCTAssertNil(VaultWatcher.classify(relativePath: ".flamingo/notes/.tmp/a.md", flags: modified))
    }

    func testIgnoredAndHidden() {
        XCTAssertNil(VaultWatcher.classify(relativePath: ".git/HEAD", flags: modified))
        XCTAssertNil(VaultWatcher.classify(relativePath: "node_modules/x/y.js", flags: modified))
        XCTAssertNil(VaultWatcher.classify(relativePath: "docs/.hidden.txt", flags: modified))
        XCTAssertNil(VaultWatcher.classify(relativePath: ".DS_Store", flags: modified))
        XCTAssertEqual(VaultWatcher.classify(relativePath: "docs/a.txt", flags: modified)?.ref.relativePath, "docs/a.txt")
    }

    func testXattrOnlyDropped() {
        XCTAssertNil(classify("a.pdf", kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemIsFile))
        XCTAssertNil(classify("a.pdf", kFSEventStreamEventFlagItemFinderInfoMod | kFSEventStreamEventFlagItemChangeOwner))
        XCTAssertNotNil(classify("a.pdf", kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemModified))
        XCTAssertNotNil(classify("a.pdf", kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemCreated))
    }

    func testPackageMapping() throws {
        XCTAssertEqual(VaultWatcher.classify(relativePath: "talks/Deck.key/Data/x.png", flags: modified)?.ref.relativePath, "talks/Deck.key")
        XCTAssertEqual(VaultWatcher.classify(relativePath: "Tool.app/Contents/Info.plist", flags: modified)?.ref.relativePath, "Tool.app")
        // Real package detection through the injected check.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pkg-\(UUID().uuidString)")
        let pkg = dir.appendingPathComponent("Thing.weird", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = VaultWatcher.classify(relativePath: "Thing.weird/inner.bin", flags: modified) { sub in
            (try? dir.appendingPathComponent(sub).resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        }
        // A plain directory with an odd extension is not a package, so the file reports itself.
        XCTAssertEqual(c?.ref.relativePath, "Thing.weird/inner.bin")
        let c2 = VaultWatcher.classify(relativePath: "Thing.weird/inner.bin", flags: modified) { $0 == "Thing.weird" }
        XCTAssertEqual(c2?.ref.relativePath, "Thing.weird")
    }

    func testDirectoryEvents() {
        let dirMod = kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemModified
        XCTAssertNil(classify("docs", dirMod))
        XCTAssertEqual(classify("docs", kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated)?.ref.relativePath, "docs")
        XCTAssertEqual(classify("docs", kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRemoved)?.ref.relativePath, "docs")
        XCTAssertEqual(classify("docs", kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed)?.ref.relativePath, "docs")
    }

    func testRescanFlags() {
        XCTAssertEqual(classify("", kFSEventStreamEventFlagMustScanSubDirs)?.ref.relativePath, "")
        XCTAssertEqual(classify("docs", kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped)?.ref.relativePath, "docs")
        XCTAssertEqual(classify("docs", kFSEventStreamEventFlagKernelDropped)?.ref.relativePath, "docs")
        XCTAssertEqual(classify("", kFSEventStreamEventFlagRootChanged)?.ref.relativePath, "")
    }

    // MARK: - Integration

    private func makeVault() throws -> (Vault, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".flamingo/notes"), withIntermediateDirectories: true)
        return (Vault(root: dir), dir)
    }

    func testFileWriteReportsChange() throws {
        let (vault, dir) = try makeVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let w = VaultWatcher(vault: vault)
        let exp = expectation(description: "change")
        exp.assertForOverFulfill = false
        w.onChange = { refs in if refs.contains(FileRef(relativePath: "hello.txt")) { exp.fulfill() } }
        w.start(); w.start()
        XCTAssertTrue(w.isRunning)
        defer { w.stop(); XCTAssertFalse(w.isRunning) }
        Thread.sleep(forTimeInterval: 0.3)
        try "hi".write(to: dir.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        wait(for: [exp], timeout: 5)
    }

    func testSidecarReportsTargetInBothCallbacks() throws {
        let (vault, dir) = try makeVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let w = VaultWatcher(vault: vault)
        let both = expectation(description: "both")
        both.expectedFulfillmentCount = 2
        both.assertForOverFulfill = false
        let target = FileRef(relativePath: "a/b.pdf")
        w.onSidecarChange = { if $0.contains(target) { both.fulfill() } }
        w.onChange = { if $0.contains(target) { both.fulfill() } }
        w.start(); defer { w.stop() }
        Thread.sleep(forTimeInterval: 0.3)
        let side = dir.appendingPathComponent(".flamingo/notes/a/b.pdf.md")
        try FileManager.default.createDirectory(at: side.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "- [2026-10-14 10:00] hi".write(to: side, atomically: false, encoding: .utf8)
        wait(for: [both], timeout: 5)
    }

    func testStateFilesAreSilent() throws {
        let (vault, dir) = try makeVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let w = VaultWatcher(vault: vault)
        let none = expectation(description: "none")
        none.isInverted = true
        w.onChange = { _ in none.fulfill() }
        w.start(); defer { w.stop() }
        Thread.sleep(forTimeInterval: 0.3)
        try "x".write(to: dir.appendingPathComponent(".flamingo/index.sqlite"), atomically: true, encoding: .utf8)
        wait(for: [none], timeout: 1.5)
    }
}
