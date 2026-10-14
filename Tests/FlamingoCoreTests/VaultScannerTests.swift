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
        let found = scan()
        XCTAssertEqual(found, ["deck.key", "nested/Model.xcodeproj", "plain/readme.txt", "Tool.app"])
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
        XCTAssertEqual(scan(), ["deck.key", "flat.app", "notes.txt"])
    }

    func testHiddenAndWellKnownJunkIsExcluded() throws {
        try touch("keep.txt")
        try touch(".flamingo/notes/x.md")
        try touch(".flamingo/index.sqlite")
        try touch(".git/config")
        try touch("node_modules/x/y.js")
        try touch("src/node_modules/z.js")
        try touch(".secret")
        try touch("sub/.hidden.txt")
        try touch(".DS_Store")
        try touch("__pycache__/a.pyc")
        try touch("DerivedData/Build/x")
        try touch(".build/debug/x")
        try touch(".Trash/old.txt")
        XCTAssertEqual(scan(), ["keep.txt"])
    }

    func testLibraryIsSkippedOnlyAtTheRoot() throws {
        try touch("Library/Preferences/x.plist")
        try touch("proj/Library/x.swift")
        XCTAssertEqual(scan(), ["proj/Library/x.swift"])
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
        try touch("Library")
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

        XCTAssertEqual(VaultScanner.ignoreRules(in: vault), IgnoreRules(text: "*.tmp\ndrafts/"))
        XCTAssertEqual(scan(), ["keep.md", "notes/drafts", "x/c.md"])
        XCTAssertEqual(paths(VaultScanner.files(in: vault, ignore: .empty)),
                       ["a.tmp", "drafts/d.md", "drafts/deep/e.md", "keep.md", "notes/drafts", "x/b.tmp", "x/c.md"])
        XCTAssertEqual(paths(VaultScanner.files(in: vault, ignore: IgnoreRules(text: "x/"))),
                       ["a.tmp", "drafts/d.md", "drafts/deep/e.md", "keep.md", "notes/drafts"])
    }

    func testIgnoreRulesAreEmptyWhenFileIsAbsent() {
        XCTAssertEqual(VaultScanner.ignoreRules(in: vault), .empty)
        XCTAssertTrue(VaultScanner.ignoreRules(in: vault).isEmpty)
    }

    func testIgnoreRulesCanDropAPackage() throws {
        try touch("deck.key/Index/Slide1.iwa")
        try touch("other.key/Index/Slide1.iwa")
        try touch(IgnoreRules.fileName, "deck.key\n")
        XCTAssertEqual(scan(), ["other.key"])
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
        XCTAssertEqual(tree.map(\.id), ["a", "b.txt", "deck.key"])
        XCTAssertEqual(tree[0].children.map(\.id), ["a/sub", "a/x.txt"])
        XCTAssertEqual(tree.reduce(0) { $0 + $1.fileCount }, 4)

        let unfiltered = VaultScanner.tree(in: vault, ignore: .empty)
        XCTAssertEqual(unfiltered, VaultScanner.tree(from: VaultScanner.files(in: vault, ignore: .empty)))
        XCTAssertEqual(unfiltered.map(\.id), ["a", "drafts", "b.txt", "deck.key", "skip.tmp"])
    }
}
