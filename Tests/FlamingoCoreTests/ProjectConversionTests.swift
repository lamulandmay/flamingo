import XCTest
@testable import FlamingoCore

final class ProjectConversionTests: XCTestCase {
    private var temps: [TempVault] = []

    override func tearDown() {
        temps.forEach { $0.destroy() }
        temps = []
        super.tearDown()
    }

    private func folder(_ name: String = #function) throws -> TempVault {
        let t = try TempVault(name)
        temps.append(t)
        return t
    }

    private let fakeGit: ProjectScaffolder.GitInit = { root in
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: false)
        try "ref: refs/heads/main\n".write(to: root.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
    }

    private func text(_ t: TempVault, _ path: String) throws -> String {
        try String(contentsOf: t.root.appendingPathComponent(path), encoding: .utf8)
    }

    private func tree(_ root: URL) throws -> [String: Data?] {
        var out: [String: Data?] = [:]
        let base = root.standardizedFileURL.path
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])!
        for case let url as URL in walker {
            let path = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            let isDir = (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory ?? false
            out.updateValue(isDir ? nil : try Data(contentsOf: url), forKey: path)
        }
        return out
    }

    /// A folder an agent has been working in: someone's CLAUDE.md, loose Markdown, a doc/
    /// folder, a badly named plan, and links between them.
    private func messy(_ t: TempVault) throws {
        try t.file("CLAUDE.md", "# Lamp\n\nUse tabs.\n\n## Build\n\nmake run\n")
        try t.file("README.md", "# Lamp\n\nSee [notes](NOTES.md), [[DESIGN-REVIEW]] and PLAN.md.\n")
        try t.file("NOTES.md", "Back to [the readme](README.md).\n")
        try t.file("PLAN.md", "1. Ship\n")
        try t.file("doc/guide.md", "Guide\n")
        try t.file("plans/DESIGN-REVIEW.md", "Review\n")
        try t.file("Package.swift", "// swift-tools-version:5.9\n")
        try t.file("Sources/App/main.swift", "print(1)\n")
    }

    func testAMessyFolderBecomesACleanProject() throws {
        let t = try folder()
        try messy(t)
        let plan = ProjectConverter.plan(root: t.root)
        XCTAssertEqual(plan.blocked, [])
        XCTAssertEqual(plan.moves, [
            "plans/DESIGN-REVIEW.md": "plans/01-design-review.md",
            "PLAN.md": "plans/02-plan.md",
            "NOTES.md": "docs/NOTES.md",
            "doc/guide.md": "docs/guide.md",
        ])
        XCTAssertEqual(plan.mentions.map(\.name), ["PLAN.md"])
        try ProjectConverter.apply(plan, gitInit: fakeGit)

        XCTAssertEqual(ProjectChecker.check(root: t.root).issues, [])
        XCTAssertEqual(try text(t, "CLAUDE.md"), "@AGENTS.md\n")
        let agents = try text(t, "AGENTS.md")
        XCTAssertEqual(ProjectChecker.headings(in: agents), ["Rules", "Commands", "Memory", "Structure"])
        XCTAssertTrue(agents.contains("## Rules\n\n### Lamp\n\nUse tabs.\n\n#### Build\n\nmake run\n"), agents)
        XCTAssertEqual(try text(t, "README.md"), "# Lamp\n\nSee [notes](docs/NOTES.md), [[01-design-review]] and PLAN.md.\n")
        XCTAssertEqual(try text(t, "docs/NOTES.md"), "Back to [the readme](../README.md).\n")
        XCTAssertEqual(try text(t, "plans/02-plan.md"), "1. Ship\n")
        XCTAssertEqual(try text(t, "docs/guide.md"), "Guide\n")
        XCTAssertEqual(try text(t, "Sources/App/main.swift"), "print(1)\n")
    }

    func testUndoPutsEverythingBackByteForByte() throws {
        let t = try folder()
        try messy(t)
        let before = try tree(t.root)
        let journal = try ProjectConverter.apply(ProjectConverter.plan(root: t.root), gitInit: fakeGit)
        XCTAssertNotEqual(try tree(t.root), before)
        try journal.undo()
        XCTAssertEqual(try tree(t.root), before)
    }

    func testUndoRefusesOnceSomethingChanged() throws {
        let t = try folder()
        try messy(t)
        let journal = try ProjectConverter.apply(ProjectConverter.plan(root: t.root), gitInit: fakeGit)
        try (try text(t, "AGENTS.md") + "\nAn agent wrote this.\n").write(to: t.root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let during = try tree(t.root)
        XCTAssertThrowsError(try journal.undo()) { error in
            XCTAssertEqual(error as? ProjectStructureError, .changed("AGENTS.md"))
        }
        XCTAssertEqual(try tree(t.root), during)
    }

    func testAGitRepoWithCommitsIsNeverTakenBack() throws {
        let t = try folder()
        let journal = try ProjectConverter.apply(ProjectConverter.plan(root: t.root), gitInit: fakeGit)
        try t.file(".git/refs/heads/main", "abc\n")
        try journal.undo()
        XCTAssertTrue(FileManager.default.fileExists(atPath: t.root.appendingPathComponent(".git").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.root.appendingPathComponent("AGENTS.md").path))
    }

    func testAnUnmarkedAgentsFileKeepsEveryWordUnderRules() throws {
        let t = try folder()
        try t.file("AGENTS.md", "# Notes for agents\n\nRun `make test`.\n\n## Style\n\n```\n## not a heading\n```\n")
        try ProjectConverter.apply(ProjectConverter.plan(root: t.root, name: "ledger"), gitInit: fakeGit)
        let agents = try text(t, "AGENTS.md")
        XCTAssertTrue(agents.hasPrefix("# ledger\n<!-- flamingo: "), agents)
        XCTAssertTrue(agents.contains("## Rules\n\n### Notes for agents\n\nRun `make test`.\n\n#### Style\n\n```\n## not a heading\n```\n"), agents)
        XCTAssertEqual(ProjectChecker.check(root: t.root).issues, [])
    }

    func testCollisionsGetASuffixAndNothingIsOverwritten() throws {
        let t = try folder()
        try t.file("docs/NOTES.md", "already here\n")
        try t.file("NOTES.md", "from the root\n")
        try ProjectConverter.apply(ProjectConverter.plan(root: t.root), gitInit: fakeGit)
        XCTAssertEqual(try text(t, "docs/NOTES.md"), "already here\n")
        XCTAssertEqual(try text(t, "docs/NOTES 2.md"), "from the root\n")
    }

    func testAFileWhereAStructureFolderBelongsBlocks() throws {
        let t = try folder()
        try t.file("docs", "a file named docs")
        let plan = ProjectConverter.plan(root: t.root)
        XCTAssertEqual(plan.blocked, [.wrongKind("docs")])
        XCTAssertThrowsError(try ProjectConverter.apply(plan, gitInit: fakeGit))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: t.root.path)), ["docs"])
    }

    /// Converting an empty folder gives exactly what scaffolding one does: one structure.
    func testConvertingAnEmptyFolderMatchesScaffolding() throws {
        let a = try folder("a"), b = try folder("b")
        let id = UUID()
        try ProjectConverter.apply(ProjectConverter.plan(root: a.root, name: "x", project: id), gitInit: fakeGit)
        try ProjectScaffolder.apply(ProjectScaffolder.plan(root: b.root, name: "x", project: id), gitInit: fakeGit)
        XCTAssertEqual(try tree(a.root), try tree(b.root))
    }

    func testDemoteAndSlug() {
        XCTAssertEqual(ProjectConverter.demote("# A\n## B\n###### F\nnot#a heading\n#hashtag"), "### A\n#### B\n###### F\nnot#a heading\n#hashtag")
        XCTAssertEqual(ProjectConverter.slug("DESIGN-REVIEW"), "design-review")
        XCTAssertEqual(ProjectConverter.slug("3 Big Plan!"), "big-plan")
        XCTAssertEqual(ProjectConverter.slug("---"), "plan")
        XCTAssertEqual(ProjectConverter.relativePath(from: "docs", to: "README.md"), "../README.md")
        XCTAssertEqual(ProjectConverter.relativePath(from: "", to: "docs/a.md"), "docs/a.md")
        XCTAssertEqual(ProjectConverter.relativePath(from: "docs/x", to: "docs/y/a.md"), "../y/a.md")
    }
}
