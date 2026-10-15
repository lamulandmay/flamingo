import XCTest
@testable import FlamingoCore

final class VaultScannerTests: XCTestCase {
    private var root: URL = URL(fileURLWithPath: "/dev/null")
    private var vault: Vault { Vault(root: root) }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("VaultScannerTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    // MARK: Helpers

    private func url(_ rel: String) -> URL { root.appendingPathComponent(rel) }

    @discardableResult
    private func touch(_ rel: String, _ contents: String = "x") throws -> URL {
        let u = url(rel)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    private func mkdir(_ rel: String) throws {
        try fm.createDirectory(at: url(rel), withIntermediateDirectories: true)
    }

    private func paths(_ refs: [FileRef]) -> [String] { refs.map(\.relativePath) }

    private func scan() -> [String] { paths(VaultScanner.files(in: vault)) }

    // MARK: files(in:)

    func testEmptyVaultHasNoFiles() {
        XCTAssertEqual(scan(), [])
    }

    func testMissingRootYieldsNoFilesAndDoesNotCrash() {
        let missing = Vault(root: root.appendingPathComponent("does-not-exist"))
        XCTAssertEqual(VaultScanner.files(in: missing), [])
        XCTAssertEqual(VaultScanner.tree(in: missing), [])
    }

    func testFilesAreSortedInFinderOrder() throws {
        for name in ["file10.txt", "file2.txt", "file1.txt", "b.md", "a.md"] { try touch(name) }
        XCTAssertEqual(scan(), ["a.md", "b.md", "file1.txt", "file2.txt", "file10.txt"])
    }

    func testNestedFoldersAreWalked() throws {
        try touch("top.txt")
        try touch("docs/a.md")
        try touch("docs/sub/deeper/b.md")
        try mkdir("empty")
        XCTAssertEqual(scan(), ["docs/a.md", "docs/sub/deeper/b.md", "top.txt"])
    }

    func testPackagesAreSingleFilesAndNotDescendedInto() throws {
        try touch("deck.key/Index/Slide1.iwa")
        try touch("deck.key/preview.jpg")
        try touch("Tool.app/Contents/Info.plist")
        try touch("nested/Model.xcodeproj/project.pbxproj")
        try touch("plain/readme.txt")
        let found = paths(VaultScanner.files(in: vault, ignore: .empty))
        XCTAssertEqual(found, ["deck.key", "nested/Model.xcodeproj", "plain/readme.txt", "Tool.app"])
        XCTAssertEqual(scan(), ["deck.key", "nested/Model.xcodeproj", "plain/readme.txt"], "*.app is a default exclusion")
        XCTAssertFalse(found.contains { $0.hasPrefix("deck.key/") })
    }

    func testIsPackage() throws {
        try touch("deck.key/Index/Slide1.iwa")
        try touch("notes.txt")
        try mkdir("folder")
        try touch("flat.app")   // a regular file with a package extension is still a file
        XCTAssertTrue(VaultScanner.isPackage(url("deck.key")))
        XCTAssertFalse(VaultScanner.isPackage(url("notes.txt")))
        XCTAssertFalse(VaultScanner.isPackage(url("folder")))
        XCTAssertFalse(VaultScanner.isPackage(url("flat.app")))
        XCTAssertFalse(VaultScanner.isPackage(url("missing.key")))
        XCTAssertEqual(paths(VaultScanner.files(in: vault, ignore: .empty)), ["deck.key", "flat.app", "notes.txt"])
    }

    func testHiddenFilesAreListedAndDefaultJunkIsExcluded() throws {
        try touch("keep.txt")
        try touch(".flamingo/notes/x.md")
        try touch(".flamingo/index.sqlite")
        try touch(".git/config")
        try touch("node_modules/x/y.js")
        try touch("src/node_modules/z.js")
        try touch(".secret")
        try touch("sub/.hidden.txt")
        try touch(".config/fish/config.fish")
        try touch(".DS_Store")
        try touch("__pycache__/a.pyc")
        try touch("DerivedData/Build/x")
        try touch(".build/debug/x")
        try touch(".Trash/old.txt")
        try touch(".cache/pip/x")
        try touch(".cargo/registry/index/x")
        try touch(".cargo/config.toml")
        try touch("Downloads/big.dmg")
        try touch("Downloads/notes.txt")
        try touch("Applications/Thing.app/Contents/Info.plist")
        XCTAssertEqual(scan(), [".cargo/config.toml", ".config/fish/config.fish", ".secret", "Downloads/notes.txt",
                                "keep.txt", "sub/.hidden.txt"])
    }

    func testLibraryIsIndexedExceptItsCaches() throws {
        try touch("Library/Preferences/x.plist")
        try touch("Library/Caches/com.x/blob")
        try touch("Library/Containers/com.x/Data/y")
        try touch("Library/Developer/Xcode/z")
        try touch("Library/Application Support/Google/Chrome/Default/History")
        try touch("Library/Application Support/Notes/n.txt")
        try touch("proj/Library/x.swift")
        XCTAssertEqual(scan(), ["Library/Application Support/Notes/n.txt", "Library/Preferences/x.plist", "proj/Library/x.swift"])
    }

    func testDefaultIgnoreFileIsWrittenOnceAndThenEditable() throws {
        try touch("a.log")
        try touch(".cache/m.js")
        XCTAssertTrue(VaultScanner.writeDefaultIgnoreFile(in: vault))
        XCTAssertEqual(try String(contentsOf: vault.ignoreURL, encoding: .utf8), IgnoreRules.defaultText)
        XCTAssertFalse(VaultScanner.writeDefaultIgnoreFile(in: vault))
        XCTAssertEqual(scan(), ["a.log"])
        try "*.log\n".write(to: vault.ignoreURL, atomically: true, encoding: .utf8)
        XCTAssertFalse(VaultScanner.writeDefaultIgnoreFile(in: vault), "never overwrites the user's edits")
        XCTAssertEqual(scan(), [".cache/m.js"])
    }

    func testAdmitsMatchesTheScanner() throws {
        let rules = VaultScanner.ignoreRules(in: vault)
        XCTAssertTrue(VaultScanner.admits("", isDirectory: true, ignore: rules))
        XCTAssertTrue(VaultScanner.admits(".config/fish/config.fish", isDirectory: false, ignore: rules))
        XCTAssertTrue(VaultScanner.admits("Library/Preferences", isDirectory: true, ignore: rules))
        XCTAssertFalse(VaultScanner.admits(".flamingo/notes/a.md", isDirectory: false, ignore: rules))
        XCTAssertFalse(VaultScanner.admits("a/.DS_Store", isDirectory: false, ignore: rules))
        XCTAssertFalse(VaultScanner.admits("p/node_modules/x/y.js", isDirectory: false, ignore: rules))
        XCTAssertFalse(VaultScanner.admits("Library/Caches/x", isDirectory: false, ignore: rules))
        XCTAssertFalse(VaultScanner.admits("Users/me/Library/Caches", isDirectory: true, ignore: rules))
        XCTAssertFalse(VaultScanner.admits("/Library/Caches/", isDirectory: true, ignore: rules))
        XCTAssertFalse(VaultScanner.admits("Downloads/x.dmg", isDirectory: false, ignore: rules))
        XCTAssertTrue(VaultScanner.admits("Documents/x.dmg", isDirectory: false, ignore: rules))
    }

    func testScanStreamsStopsAndRestrictsToAFolder() throws {
        for i in 0..<20 { try touch("a/f\(i).txt") }
        try touch("b/node_modules/x.js")
        try touch("b/y.txt")
        var seen = 0
        VaultScanner.scan(in: vault, ignore: .empty) { _ in seen += 1; return seen < 5 }
        XCTAssertEqual(seen, 5)
        XCTAssertEqual(paths(VaultScanner.files(in: vault, under: "b")), ["b/y.txt"])
        XCTAssertEqual(paths(VaultScanner.files(in: vault, under: "/b/")), ["b/y.txt"])
        XCTAssertEqual(paths(VaultScanner.files(in: vault, under: "b/node_modules")), [], "an ignored folder has nothing")
        XCTAssertEqual(VaultScanner.files(in: vault, under: "missing"), [])
        XCTAssertEqual(VaultScanner.files(in: vault, under: "").count, 21)
    }

    func testAsyncStreamYieldsEverythingAndCanBeAbandoned() async throws {
        for i in 0..<50 { try touch("d\(i % 5)/f\(i).txt") }
        var all: [String] = []
        for await ref in VaultScanner.stream(in: vault) { all.append(ref.relativePath) }
        XCTAssertEqual(all.sorted(), scan().sorted())
        var some = 0
        for await _ in VaultScanner.stream(in: vault) { some += 1; if some == 3 { break } }
        XCTAssertEqual(some, 3)
    }

    func testChildrenListsOneLevelFoldersFirst() throws {
        try touch("top.txt")
        try touch(".zshrc")
        try touch("b/inner.txt")
        try touch("a10/x.txt")
        try touch("a2/x.txt")
        try touch("node_modules/x.js")
        try touch("deck.key/Index/Slide1.iwa")
        try touch(".DS_Store")
        try fm.createSymbolicLink(at: url("link"), withDestinationURL: url("b"))
        let kids = VaultScanner.children(of: "", in: vault)
        XCTAssertEqual(kids.map(\.id), ["a2", "a10", "b", ".zshrc", "deck.key", "top.txt"])
        XCTAssertEqual(kids.map(\.isFolder), [true, true, true, false, false, false])
        XCTAssertEqual(kids[0].children, [])
        XCTAssertEqual(kids[0].fileCount, 0)
        XCTAssertEqual(kids[4].ref, FileRef(relativePath: "deck.key"))
        XCTAssertEqual(VaultScanner.children(of: "b", in: vault).map(\.id), ["b/inner.txt"])
        XCTAssertEqual(VaultScanner.children(of: "nope", in: vault), [])
    }

    func testLimitsAllowExtractionUpTo50MB() throws {
        XCTAssertEqual(VaultScanner.limits.maxExtractableBytes, 50 * 1024 * 1024)
        XCTAssertTrue(VaultScanner.limits.allowsExtraction(ofSize: 50 * 1024 * 1024))
        XCTAssertFalse(VaultScanner.limits.allowsExtraction(ofSize: 50 * 1024 * 1024 + 1))
        let small = try touch("small.txt")
        let big = url("big.bin")
        XCTAssertTrue(fm.createFile(atPath: big.path, contents: nil))
        let h = try FileHandle(forWritingTo: big)
        try h.truncate(atOffset: UInt64(VaultScanner.limits.maxExtractableBytes + 1))   // sparse
        try h.close()
        try touch("deck.key/Index/Slide1.iwa")
        XCTAssertTrue(VaultScanner.limits.allowsExtraction(of: small))
        XCTAssertFalse(VaultScanner.limits.allowsExtraction(of: big))
        XCTAssertTrue(VaultScanner.limits.allowsExtraction(of: url("deck.key")))
        XCTAssertFalse(VaultScanner.limits.allowsExtraction(of: url("missing.txt")))
    }

    func testSymlinksAreNeitherListedNorFollowed() throws {
        try touch("real.txt")
        try touch("realdir/inner.txt")
        try fm.createSymbolicLink(at: url("link-to-file"), withDestinationURL: url("real.txt"))
        try fm.createSymbolicLink(at: url("link-to-dir"), withDestinationURL: url("realdir"))
        try fm.createSymbolicLink(at: url("dangling"), withDestinationURL: url("nowhere"))
        XCTAssertEqual(scan(), ["real.txt", "realdir/inner.txt"])
    }

    func testPlainFileWithIgnoredNameDoesNotSwallowASiblingFolder() throws {
        // skipDescendants() is sticky on the enumerator; a non-directory hit must never trigger it.
        try touch("DerivedData")
        try touch("node_modules")
        try touch("zdir/inner.txt")
        try touch("adir/inner.txt")
        XCTAssertEqual(scan(), ["adir/inner.txt", "zdir/inner.txt"])
    }

    func testUnreadableDirectoryIsSkippedWithoutThrowing() throws {
        try touch("ok/a.txt")
        try touch("locked/secret.txt")
        try touch("zz.txt")
        let locked = url("locked")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let found = scan()
        XCTAssertTrue(found.contains("ok/a.txt"))
        XCTAssertTrue(found.contains("zz.txt"))
        XCTAssertFalse(found.contains("locked/secret.txt"), "unreadable unless running as root")
    }

    func testFlamingoignoreIsHonored() throws {
        try touch("keep.md")
        try touch("a.tmp")
        try touch("x/b.tmp")
        try touch("x/c.md")
        try touch("drafts/d.md")
        try touch("drafts/deep/e.md")
        try touch("notes/drafts")   // a file named drafts is not a directory, so "drafts/" leaves it alone
        try touch(IgnoreRules.fileName, "# scratch\n*.tmp\ndrafts/\n")

        XCTAssertEqual(VaultScanner.ignoreRules(in: vault), IgnoreRules(text: IgnoreRules.defaultText + "\n*.tmp\ndrafts/"))
        XCTAssertEqual(scan(), [".flamingoignore", "keep.md", "notes/drafts", "x/c.md"])
        XCTAssertEqual(paths(VaultScanner.files(in: vault, ignore: .empty)),
                       [".flamingoignore", "a.tmp", "drafts/d.md", "drafts/deep/e.md", "keep.md", "notes/drafts", "x/b.tmp", "x/c.md"])
        XCTAssertEqual(paths(VaultScanner.files(in: vault, ignore: IgnoreRules(text: "x/"))),
                       [".flamingoignore", "a.tmp", "drafts/d.md", "drafts/deep/e.md", "keep.md", "notes/drafts"])
    }

    func testIgnoreRulesAreTheDefaultsWhenNoFileExists() {
        XCTAssertEqual(VaultScanner.ignoreRules(in: vault), IgnoreRules(text: IgnoreRules.defaultText))
        XCTAssertFalse(VaultScanner.ignoreRules(in: vault).isEmpty)
    }

    func testIgnoreRulesCanDropAPackage() throws {
        try touch("deck.key/Index/Slide1.iwa")
        try touch("other.key/Index/Slide1.iwa")
        try touch(IgnoreRules.fileName, "deck.key\n")
        XCTAssertEqual(scan(), [".flamingoignore", "other.key"])
    }

    // MARK: tree(from:)

    func testTreeFromRefsNestsFoldersFirstThenFiles() {
        let refs = ["b.txt", "a/x.txt", "a/sub/y.txt", "a/z.txt", "c/w.txt", "file10.txt", "file2.txt"]
            .map(FileRef.init(relativePath:))
        let tree = VaultScanner.tree(from: refs)

        XCTAssertEqual(tree.map(\.id), ["a", "c", "b.txt", "file2.txt", "file10.txt"])
        XCTAssertEqual(tree.map(\.isFolder), [true, true, false, false, false])
        XCTAssertEqual(tree.map(\.fileCount), [3, 1, 1, 1, 1])

        let a = tree[0]
        XCTAssertEqual(a.name, "a")
        XCTAssertNil(a.ref)
        XCTAssertEqual(a.children.map(\.id), ["a/sub", "a/x.txt", "a/z.txt"])
        XCTAssertEqual(a.children.map(\.name), ["sub", "x.txt", "z.txt"])
        XCTAssertEqual(a.children[0].children.map(\.id), ["a/sub/y.txt"])
        XCTAssertEqual(a.children[0].fileCount, 1)
        XCTAssertEqual(a.children[1].ref, FileRef(relativePath: "a/x.txt"))
        XCTAssertEqual(a.children[1].children, [])

        let b = tree[2]
        XCTAssertEqual(b.name, "b.txt")
        XCTAssertEqual(b.ref, FileRef(relativePath: "b.txt"))
        XCTAssertFalse(b.isFolder)
    }

    func testTreeFromRefsIsIndependentOfInputOrderAndDropsDuplicatesAndEmpties() {
        let a = VaultScanner.tree(from: ["z/1.txt", "a.txt", "z/0.txt"].map(FileRef.init(relativePath:)))
        let b = VaultScanner.tree(from: ["z/0.txt", "a.txt", "z/1.txt", "z/0.txt", ""].map(FileRef.init(relativePath:)))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.map(\.id), ["z", "a.txt"])
        XCTAssertEqual(a[0].fileCount, 2)
        XCTAssertEqual(VaultScanner.tree(from: []), [])
    }

    func testTreeNodeFileCountFollowsChildren() {
        var folder = TreeNode(id: "f", name: "f", ref: nil, isFolder: true, children: [
            TreeNode(id: "f/a", name: "a", ref: FileRef(relativePath: "f/a"), isFolder: false),
            TreeNode(id: "f/b", name: "b", ref: FileRef(relativePath: "f/b"), isFolder: false),
        ])
        XCTAssertEqual(folder.fileCount, 2)
        folder.children.removeLast()
        XCTAssertEqual(folder.fileCount, 1)
        XCTAssertEqual(TreeNode(id: "empty", name: "empty", ref: nil, isFolder: true).fileCount, 0)
        XCTAssertEqual(TreeNode(id: "x", name: "x", ref: FileRef(relativePath: "x"), isFolder: false).fileCount, 1)
    }

    // MARK: tree(in:)

    func testTreeInVaultMatchesTreeFromFiles() throws {
        try touch("b.txt")
        try touch("a/x.txt")
        try touch("a/sub/y.txt")
        try touch("deck.key/Index/Slide1.iwa")
        try touch("drafts/skip.md")
        try touch("skip.tmp")
        try touch(IgnoreRules.fileName, "*.tmp\ndrafts/\n")

        let tree = VaultScanner.tree(in: vault)
        XCTAssertEqual(tree, VaultScanner.tree(from: VaultScanner.files(in: vault)))
        XCTAssertEqual(tree.map(\.id), ["a", ".flamingoignore", "b.txt", "deck.key"])
        XCTAssertEqual(tree[0].children.map(\.id), ["a/sub", "a/x.txt"])
        XCTAssertEqual(tree.reduce(0) { $0 + $1.fileCount }, 5)

        let unfiltered = VaultScanner.tree(in: vault, ignore: .empty)
        XCTAssertEqual(unfiltered, VaultScanner.tree(from: VaultScanner.files(in: vault, ignore: .empty)))
        XCTAssertEqual(unfiltered.map(\.id), ["a", "drafts", ".flamingoignore", "b.txt", "deck.key", "skip.tmp"])
    }
}

/// Opt-in: `FLAMINGO_SCAN_HOME=1 scripts/test.sh --filter ScanHomeBenchmark` times a full scan of `~`.
final class ScanHomeBenchmark: XCTestCase {
    func testScanHome() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FLAMINGO_SCAN_HOME"] != nil)
        let vault = Vault(root: FileManager.default.homeDirectoryForCurrentUser)
        let rules = VaultScanner.ignoreRules(in: vault)
        let started = Date()
        var count = 0, firstAt = 0.0
        var top: [String: Int] = [:]
        VaultScanner.scan(in: vault, ignore: rules) { ref in
            if count == 0 { firstAt = Date().timeIntervalSince(started) }
            count += 1
            top[ref.components.prefix(ref.components.first == "Library" ? 3 : 1).joined(separator: "/"), default: 0] += 1
            return true
        }
        let s = Date().timeIntervalSince(started)
        print("scan ~: \(count) files in \(String(format: "%.1f", s))s, first after \(String(format: "%.3f", firstAt))s")
        for (k, v) in top.sorted(by: { $0.value > $1.value }).prefix(25) { print("  \(v)\t\(k)") }
    }
}
