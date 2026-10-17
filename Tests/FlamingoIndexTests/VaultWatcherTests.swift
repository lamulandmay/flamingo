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
        XCTAssertEqual(VaultWatcher.classify(relativePath: ".flamingo/notes/.tmp/a.md", flags: modified)?.ref.relativePath, ".tmp/a")
    }

    func testIgnoredAndHidden() {
        XCTAssertNil(VaultWatcher.classify(relativePath: ".git/HEAD", flags: modified))
        XCTAssertNil(VaultWatcher.classify(relativePath: "node_modules/x/y.js", flags: modified))
        XCTAssertEqual(VaultWatcher.classify(relativePath: "docs/.hidden.txt", flags: modified)?.ref.relativePath, "docs/.hidden.txt")
        XCTAssertNil(VaultWatcher.classify(relativePath: ".DS_Store", flags: modified))
        XCTAssertNil(VaultWatcher.classify(relativePath: "docs/~$6767.pptx", flags: modified))
        XCTAssertEqual(VaultWatcher.classify(relativePath: "docs/~draft.txt", flags: modified)?.ref.relativePath, "docs/~draft.txt")
        XCTAssertEqual(VaultWatcher.classify(relativePath: "docs/a.txt", flags: modified)?.ref.relativePath, "docs/a.txt")
    }

    func testFilesystemRootAndPrefixBoundaries() {
        XCTAssertEqual(VaultWatcher.relativePath("/Users/example/a.txt", roots: ["/"]), "Users/example/a.txt")
        XCTAssertEqual(VaultWatcher.relativePath("/vault/.hidden.txt", roots: ["/vault"]), ".hidden.txt")
        XCTAssertNil(VaultWatcher.relativePath("/vault-other/a", roots: ["/vault"]))
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

    func testReplayDeliversChangesMadeWhileClosedThenHistoryDone() throws {
        let (vault, dir) = try makeVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNotNil(VaultWatcher.historyID(for: dir))
        Thread.sleep(forTimeInterval: 0.3)
        let since = VaultWatcher.currentEventID
        try "made while closed".write(to: dir.appendingPathComponent("offline.txt"), atomically: true, encoding: .utf8)
        Thread.sleep(forTimeInterval: 1.5)   // fseventsd records it
        let w = VaultWatcher(vault: vault)
        let seen = expectation(description: "replayed")
        seen.assertForOverFulfill = false
        let done = expectation(description: "history done")
        w.onChange = { if $0.contains(FileRef(relativePath: "offline.txt")) { seen.fulfill() } }
        w.onHistoryDone = {
            XCTAssertGreaterThan(w.deliveredThrough ?? 0, since, "a finished replay reaches past where it started")
            done.fulfill()
        }
        w.start(since: since); defer { w.stop() }
        wait(for: [seen, done], timeout: 10, enforceOrder: true)
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

    func testIgnoreRulesAndRescans() {
        let rules = PathRules(ignore: IgnoreRules(text: "*.log\nbuild/\n"))
        func c(_ p: String, _ f: FSEventStreamEventFlags) -> VaultWatcher.Classified? {
            VaultWatcher.classify(relativePath: p, flags: f, rules: rules)
        }
        XCTAssertEqual(c(".flamingoignore", modified)?.ref.relativePath, "")
        XCTAssertEqual(c(".flamingo/ignore", modified)?.ref.relativePath, "")
        XCTAssertNil(c("debug.log", modified))
        XCTAssertNil(c("build/out.txt", modified))
        XCTAssertEqual(c("Library/Preferences/x.plist", modified)?.ref.relativePath, "Library/Preferences/x.plist", "whole-Mac vaults index ~/Library")
        XCTAssertEqual(c("proj/Library/notes.txt", modified)?.ref.relativePath, "proj/Library/notes.txt")
        XCTAssertEqual(c("notes.txt", modified)?.ref.relativePath, "notes.txt")
        let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        XCTAssertEqual(c(".flamingo/notes", dropped), .init(ref: VaultWatcher.allNotes, sidecar: true), "lost sidecar events re-read the notes, not the vault")
        XCTAssertEqual(c(".flamingo", dropped)?.ref, VaultWatcher.allNotes)
        XCTAssertNil(c(".flamingo/index.sqlite-wal", dropped), "our own index churn never triggers work")
        XCTAssertEqual(c("", dropped)?.ref.relativePath, "", "events lost at the root still mean a rescan")
    }
}

