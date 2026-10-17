import XCTest
@testable import FlamingoCore

final class PathAliasTests: XCTestCase {
    private func store() throws -> PathAliases {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("path-aliases-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return PathAliases(vault: Vault(root: root))
    }

    private func refs(_ paths: String...) -> [FileRef] { paths.map(FileRef.init(relativePath:)) }

    func testRenamesPersistChainsWithoutChangingSourceDocuments() throws {
        let store = try store()
        XCTAssertEqual(try store.all(), [:])
        let note = store.vault.root.appendingPathComponent("note.md")
        let original = Data("See [[Drafts/预算.xlsx#cell Q3!B12|the plan]]".utf8)
        try original.write(to: note)
        try store.reconcile(oldPath: "Drafts/预算.xlsx", newPath: "Review/Model.xlsx")
        try PathAliases(vault: store.vault).reconcile(oldPath: "Review/Model.xlsx", newPath: "Approved/Budget.xlsx")
        let aliases = try store.all()
        XCTAssertEqual(aliases["Drafts/预算.xlsx"], "Review/Model.xlsx")
        XCTAssertEqual(aliases["Review/Model.xlsx"], "Approved/Budget.xlsx")
        XCTAssertEqual(try Data(contentsOf: note), original)
        let file = FileRef(relativePath: "Approved/Budget.xlsx")
        XCTAssertEqual(Wikilink.resolve("Drafts/预算.xlsx#cell Q3!B12|the plan", in: store.vault, candidates: [file]), file)
        XCTAssertEqual(Wikilink.resolve("预算", from: FileRef(relativePath: "note.md"), in: store.vault, candidates: [file]), file)
    }

    func testFolderThenChildRenamePreservesHistoricalPathsAndStems() throws {
        let store = try store()
        try store.reconcile(oldPath: "Project Old", newPath: "Project New")
        try store.reconcile(oldPath: "Project New/report.md", newPath: "Archive/final.md")
        let candidates = refs("Archive/final.md", "Project New/other.md", "Project Older/report.md")
        let resolver = Wikilink.Resolver(candidates: candidates, aliases: try store.all())
        for target in ["Project Old/report.md", "Project Old/report", "Project New/report"] {
            XCTAssertEqual(resolver.resolve(target)?.relativePath, "Archive/final.md", target)
        }
        XCTAssertEqual(resolver.resolve("report")?.relativePath, "Project Older/report.md", "An existing basename wins over a historical basename")
        XCTAssertEqual(resolver.resolve("Project Old/other")?.relativePath, "Project New/other.md")
        XCTAssertEqual(resolver.resolve("Project Older/report")?.relativePath, "Project Older/report.md")
        XCTAssertNil(resolver.resolve("Project Oldest/report"))
    }

    func testExistingExactFilesWinOverHistoricalNamesAndSourceBreaksAliasTies() {
        let candidates = refs("old.md", "renamed.md", "A/final.md", "B/final.md")
        let resolver = Wikilink.Resolver(candidates: candidates, aliases: [
            "old.md": "renamed.md", "A/draft.md": "A/final.md", "B/draft.md": "B/final.md",
        ])
        XCTAssertEqual(resolver.resolve("old.md")?.relativePath, "old.md")
        XCTAssertEqual(resolver.resolve("old")?.relativePath, "old.md")
        let folded = Wikilink.Resolver(candidates: refs("old.md", "renamed.md"), aliases: ["OLD.md": "renamed.md"])
        XCTAssertEqual(folded.resolve("OLD.md")?.relativePath, "old.md")
        XCTAssertEqual(resolver.resolve("draft", from: .init(relativePath: "B/notes.md"))?.relativePath, "B/final.md")
        XCTAssertEqual(resolver.resolve("A/draft")?.relativePath, "A/final.md")
    }

    func testSpecificChildAliasOverridesBroaderFolderAlias() {
        let resolver = Wikilink.Resolver(candidates: refs("New/file.md", "Elsewhere/final.md"), aliases: [
            "Old": "New", "Old/file.md": "Elsewhere/final.md",
        ])
        XCTAssertEqual(resolver.resolve("Old/file.md")?.relativePath, "Elsewhere/final.md")
        XCTAssertEqual(resolver.resolve("Old/file")?.relativePath, "Elsewhere/final.md")
    }

    func testAliasesRespectUnicodeNormalizationAndCaseInsensitiveResolution() throws {
        let store = try store()
        try store.reconcile(oldPath: "cafe\u{301}/Draft.md", newPath: "完成/final.md")
        let resolver = Wikilink.Resolver(candidates: refs("完成/final.md"), aliases: try store.all())
        XCTAssertEqual(resolver.resolve("CAFÉ/DRAFT")?.relativePath, "完成/final.md")
        XCTAssertEqual(resolver.resolve("café/Draft.md#heading Intro|label")?.relativePath, "完成/final.md")
    }

    func testCyclesAndUnsafePathsAreRejectedWithoutChangingSavedAliases() throws {
        let store = try store()
        try store.reconcile(oldPath: "a.md", newPath: "b.md")
        let saved = try Data(contentsOf: store.fileURL)
        XCTAssertThrowsError(try store.reconcile(oldPath: "folder", newPath: "folder/child"))
        for path in ["", "../escape", "/absolute", ".flamingo/notes", "a/../b", "a//b", "a\\b"] {
            XCTAssertThrowsError(try store.reconcile(oldPath: path, newPath: "valid.md"), path)
            XCTAssertThrowsError(try store.reconcile(oldPath: "valid.md", newPath: path), path)
        }
        XCTAssertEqual(try Data(contentsOf: store.fileURL), saved)
    }

    func testRenamingBackRetiresTheDestinationAliasAndPreservesEarlierIncomingLinks() throws {
        let store = try store()
        try store.reconcile(oldPath: "earlier.md", newPath: "a.md")
        try store.reconcile(oldPath: "a.md", newPath: "b.md")
        try store.reconcile(oldPath: "b.md", newPath: "a.md")
        let aliases = try store.all()
        XCTAssertNil(aliases["a.md"])
        XCTAssertEqual(aliases["b.md"], "a.md")
        XCTAssertEqual(aliases["earlier.md"], "a.md")
        let resolver = Wikilink.Resolver(candidates: refs("a.md"), aliases: aliases)
        for path in ["a.md", "b.md", "earlier.md"] {
            XCTAssertEqual(resolver.resolve(path)?.relativePath, "a.md")
        }
    }

    func testFolderRenameBackRetiresReturningChildrenButPreservesMovedOutChild() throws {
        let store = try store()
        try store.reconcile(oldPath: "earlier.md", newPath: "A/returning.md")
        try store.reconcile(oldPath: "A/returning.md", newPath: "B/returning.md")
        try store.reconcile(oldPath: "A/moved-out.md", newPath: "Archive/final.md")
        try store.reconcile(oldPath: "A", newPath: "B")
        try store.reconcile(oldPath: "B", newPath: "A")
        let aliases = try store.all()
        XCTAssertNil(aliases["A"])
        XCTAssertNil(aliases["A/returning.md"])
        XCTAssertEqual(aliases["A/moved-out.md"], "Archive/final.md")
        let resolver = Wikilink.Resolver(candidates: refs("A/returning.md", "Archive/final.md"), aliases: aliases)
        XCTAssertEqual(resolver.resolve("earlier.md")?.relativePath, "A/returning.md")
        XCTAssertEqual(resolver.resolve("B/returning.md")?.relativePath, "A/returning.md")
        XCTAssertEqual(resolver.resolve("A/moved-out.md")?.relativePath, "Archive/final.md")
    }

    func testReusingHistoricalDestinationDoesNotRedirectOlderIncomingLinksToNewFile() throws {
        let store = try store()
        try store.reconcile(oldPath: "earlier.md", newPath: "a.md")
        try store.reconcile(oldPath: "a.md", newPath: "b.md")
        try store.reconcile(oldPath: "unrelated.md", newPath: "a.md")
        let resolver = Wikilink.Resolver(candidates: refs("a.md", "b.md"), aliases: try store.all())
        XCTAssertEqual(resolver.resolve("earlier.md")?.relativePath, "b.md")
        XCTAssertEqual(resolver.resolve("unrelated.md")?.relativePath, "a.md")
        XCTAssertEqual(resolver.resolve("a.md")?.relativePath, "a.md")
    }

    func testMalformedOrCyclicMetadataIsPreserved() throws {
        let store = try store()
        try FileManager.default.createDirectory(at: store.vault.stateDir, withIntermediateDirectories: true)
        for contents in ["{unfinished", "{\"a\":\"b\",\"b\":\"a\"}", "{\"../escape\":\"b\"}"] {
            let bytes = Data(contents.utf8)
            try bytes.write(to: store.fileURL)
            XCTAssertThrowsError(try store.all())
            XCTAssertThrowsError(try store.reconcile(oldPath: "old.md", newPath: "new.md"))
            XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
        }
    }

    func testBadInjectedAliasMapCannotLoopOrDisplaceRealFiles() {
        let resolver = Wikilink.Resolver(candidates: refs("real.md"), aliases: ["a": "a/child"])
        XCTAssertNil(resolver.resolve("a"))
        XCTAssertEqual(resolver.resolve("real")?.relativePath, "real.md")
    }
}
