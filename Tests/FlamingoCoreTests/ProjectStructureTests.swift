import XCTest
@testable import FlamingoCore

final class ProjectStructureTests: XCTestCase {
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

    /// Stands in for `git init` so trees can be compared byte for byte.
    private let fakeGit: ProjectScaffolder.GitInit = { root in
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: false)
    }

    @discardableResult
    private func scaffold(_ t: TempVault, name: String? = nil, description: String = "") throws -> [String] {
        let plan = ProjectScaffolder.plan(root: t.root, name: name, description: description)
        return try ProjectScaffolder.apply(plan, gitInit: fakeGit)
    }

    private func text(_ t: TempVault, _ path: String) throws -> String {
        try String(contentsOf: t.root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Every item under `root` (except `.git`), with its bytes; folders map to nil.
    private func tree(_ root: URL) throws -> [String: Data?] {
        var out: [String: Data?] = [:]
        let base = root.standardizedFileURL.path
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])!
        for case let url as URL in walker {
            let path = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            if path == ".git" { walker.skipDescendants(); continue }
            let isDir = (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory ?? false
            out.updateValue(isDir ? nil : try Data(contentsOf: url), forKey: path)
        }
        return out
    }

    // MARK: The same every time

    func testTwoProjectsHaveTheSameTreeAndFixedBytes() throws {
        let a = try folder("a"), b = try folder("b")
        try scaffold(a, name: "Lamp", description: "A desk lamp.")
        try scaffold(b, name: "Ledger app")
        let ta = try tree(a.root), tb = try tree(b.root)
        XCTAssertEqual(Set(ta.keys), Set(tb.keys))
        XCTAssertEqual(Set(ta.keys), [
            "AGENTS.md", "CLAUDE.md", "README.md", "HANDOVER.md", ".gitignore",
            "plans", "plans/.gitkeep", "docs", "docs/.gitkeep", "scratch",
        ])
        for path in ta.keys where path != "AGENTS.md" && path != "README.md" {
            XCTAssertEqual(ta[path]!, tb[path]!, path)
        }
        // AGENTS.md differs only in the name line, the marker and the description.
        func skeleton(_ t: TempVault) throws -> [String] {
            try text(t, "AGENTS.md").components(separatedBy: "\n")
                .filter { !$0.hasPrefix("# ") && !$0.hasPrefix("<!-- flamingo:") && $0 != "A desk lamp." && !$0.isEmpty }
        }
        XCTAssertEqual(try skeleton(a), try skeleton(b))
        XCTAssertNotEqual(ProjectMarker.find(in: try text(a, "AGENTS.md"))?.project,
                          ProjectMarker.find(in: try text(b, "AGENTS.md"))?.project)
    }

    func testFixedFilesHaveTheirExactBytes() throws {
        let t = try folder()
        try scaffold(t, name: "Lamp")
        XCTAssertEqual(try text(t, "CLAUDE.md"), "@AGENTS.md\n")
        XCTAssertEqual(try text(t, ".gitignore"), """
        # flamingo structure 1: do not edit between these lines
        scratch/
        .flamingo/
        .DS_Store
        # flamingo end

        """)
        XCTAssertEqual(try text(t, "plans/.gitkeep"), "")
        XCTAssertEqual(try text(t, "docs/.gitkeep"), "")
        XCTAssertEqual(try text(t, "README.md"), "# Lamp\n")
        XCTAssertEqual(try text(t, "HANDOVER.md"), "# Handover\n")
        let agents = try text(t, "AGENTS.md")
        XCTAssertTrue(agents.hasPrefix("# Lamp\n<!-- flamingo: {\"project\":\""), agents)
        XCTAssertEqual(ProjectChecker.headings(in: agents), ["Rules", "Commands", "Memory", "Structure"])
        XCTAssertTrue(agents.hasSuffix("## Structure\n\n" + ProjectStructure.structureText))
    }

    func testAFreshProjectHasNoIssues() throws {
        let t = try folder()
        let created = try scaffold(t)
        let report = ProjectChecker.check(root: t.root)
        XCTAssertTrue(report.isStructured)
        XCTAssertEqual(report.issues, [])
        XCTAssertEqual(created.first, ".git")
        // Applying again changes nothing.
        let again = ProjectScaffolder.plan(root: t.root)
        XCTAssertEqual(again.changes, [])
        XCTAssertEqual(again.conflicts, [])
        XCTAssertEqual(again.marker, report.marker)
    }

    func testTheProjectsOwnWritingIsNotChecked() throws {
        let t = try folder()
        try scaffold(t)
        var agents = try text(t, "AGENTS.md")
        agents = agents.replacingOccurrences(of: "## Rules\n", with: "## Rules\n\nNever ship on Friday.\n\n### Swift\n\nNo force unwraps.\n")
        agents = agents.replacingOccurrences(of: "## Memory\n", with: "## Memory\n\n```\n## not a heading\n```\n")
        try agents.write(to: t.root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try t.file("README.md", "# Lamp\n\nAnything at all.\n")
        try t.file("HANDOVER.md", "Whatever stands.\n")
        try t.file("docs/anything/here.txt")
        try t.file("plans/01-auth.md")
        try t.file("plans/120-billing-v2.md")
        try t.file("CHANGELOG.md")
        try t.file("Package.swift")
        try t.file("Sources/App/main.swift")
        XCTAssertEqual(ProjectChecker.check(root: t.root).issues, [])
    }

    // MARK: Every way it breaks

    func testEachBreakIsFoundAndClassified() throws {
        let t = try folder()
        try scaffold(t)
        try t.remove("HANDOVER.md")
        try t.remove("docs")
        try t.file("CLAUDE.md", "@AGENTS.md\n\nUse tabs.\n")
        try t.file(".gitignore", "build/\n# flamingo structure 1: do not edit between these lines\nscratch/\n# flamingo end\n")
        try t.file("NOTES.md")
        try t.file("plans/plan.md")
        try t.folder("plans/old")
        var agents = try text(t, "AGENTS.md")
        agents = agents.replacingOccurrences(of: "## Commands\n", with: "## Architecture\n")
        agents = agents.replacingOccurrences(of: "Read it first.", with: "Skip it.")
        try agents.write(to: t.root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

        let issues = ProjectChecker.check(root: t.root).issues
        XCTAssertEqual(Set(issues), [
            .missingFolder("docs"), .missingFile("HANDOVER.md"), .missingFile("docs/.gitkeep"),
            .claudeChanged, .gitignoreBlockChanged, .headingMissing("Commands"), .extraHeading("Architecture"),
            .structureTextChanged, .strayRootMarkdown("NOTES.md"), .badPlanName("plans/plan.md"), .folderInPlans("plans/old"),
        ])
        XCTAssertEqual(Set(issues.filter(\.isRestorable)), [
            .missingFolder("docs"), .missingFile("HANDOVER.md"), .missingFile("docs/.gitkeep"),
            .claudeChanged, .gitignoreBlockChanged, .headingMissing("Commands"), .structureTextChanged,
        ])
    }

    func testHeadingsOutOfOrder() throws {
        let t = try folder()
        try scaffold(t)
        let agents = try text(t, "AGENTS.md")
            .replacingOccurrences(of: "## Rules\n", with: "## Temp\n")
            .replacingOccurrences(of: "## Memory\n", with: "## Rules\n")
            .replacingOccurrences(of: "## Temp\n", with: "## Memory\n")
        try agents.write(to: t.root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectChecker.check(root: t.root).issues, [.headingsOutOfOrder])
    }

    func testAFileWhereAFolderBelongs() throws {
        let t = try folder()
        try scaffold(t)
        try t.remove("scratch")
        try t.file("scratch", "not a folder")
        XCTAssertEqual(ProjectChecker.check(root: t.root).issues, [.wrongKind("scratch")])
    }

    func testPlanNames() {
        for good in ["01-auth.md", "18-agent-projects.md", "100-x.md", "07-v2-api.md"] {
            XCTAssertTrue(ProjectStructure.isPlanName(good), good)
        }
        for bad in ["1-auth.md", "01_auth.md", "01-Auth.md", "plan.md", "01-.md", "01-auth.markdown", "01--auth.md", "01-auth-.md"] {
            XCTAssertFalse(ProjectStructure.isPlanName(bad), bad)
        }
    }

    // MARK: Converting is a later step; scaffolding never overwrites

    func testExistingReadmeAndGitignoreAreKept() throws {
        let t = try folder()
        try t.file("README.md", "# Mine\n\nKeep me.\n")
        try t.file(".gitignore", "build/\n*.log")
        try scaffold(t)
        XCTAssertEqual(try text(t, "README.md"), "# Mine\n\nKeep me.\n")
        XCTAssertEqual(try text(t, ".gitignore"), "build/\n*.log\n\n" + ProjectStructure.gitignoreBlock)
        XCTAssertEqual(ProjectChecker.check(root: t.root).issues, [])
    }

    func testSomeoneElsesInstructionsBlockScaffolding() throws {
        let t = try folder()
        try t.file("CLAUDE.md", "Use tabs.\n")
        try t.file("PLAN.md")
        let plan = ProjectScaffolder.plan(root: t.root)
        XCTAssertEqual(Set(plan.conflicts), [.claudeChanged, .strayRootMarkdown("PLAN.md")])
        XCTAssertThrowsError(try ProjectScaffolder.apply(plan, gitInit: fakeGit)) { error in
            XCTAssertEqual(error as? ProjectStructureError, .needsConversion(plan.conflicts))
        }
        // Nothing was written.
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: t.root.path)), ["CLAUDE.md", "PLAN.md"])
    }

    func testAnAgentsFileWithoutAMarkerIsAConflict() throws {
        let t = try folder()
        try t.file("AGENTS.md", "# Notes\n\nRun make.\n")
        let plan = ProjectScaffolder.plan(root: t.root)
        XCTAssertTrue(plan.conflicts.contains(.markerMissing))
        XCTAssertFalse(plan.changes.contains { if case .createFile("AGENTS.md", _) = $0 { true } else { false } })
    }

    func testAFileThatAppearsAfterPlanningIsNotOverwritten() throws {
        let t = try folder()
        let plan = ProjectScaffolder.plan(root: t.root)
        try t.file("HANDOVER.md", "Written by an agent meanwhile.\n")
        let created = try ProjectScaffolder.apply(plan, gitInit: fakeGit)
        XCTAssertFalse(created.contains("HANDOVER.md"))
        XCTAssertEqual(try text(t, "HANDOVER.md"), "Written by an agent meanwhile.\n")
    }

    func testANewerStructureIsLeftAlone() throws {
        let t = try folder()
        try t.file("AGENTS.md", "# X\n" + ProjectMarker(project: UUID(), structure: 2).rendered + "\n")
        let report = ProjectChecker.check(root: t.root)
        XCTAssertEqual(report.issues, [.newerStructure(2)])
        XCTAssertThrowsError(try ProjectScaffolder.apply(ProjectScaffolder.plan(root: t.root), gitInit: fakeGit)) { error in
            XCTAssertEqual(error as? ProjectStructureError, .newerStructure(2))
        }
    }

    // MARK: Git

    func testAWorktreeCountsAsARepo() throws {
        let t = try folder()
        try t.file(".git", "gitdir: /somewhere/.git/worktrees/x\n")
        XCTAssertFalse(ProjectScaffolder.plan(root: t.root).changes.contains(.gitInit))
    }

    func testRealGitInitMakesARepo() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"))
        let t = try folder()
        let created = try ProjectScaffolder.apply(ProjectScaffolder.plan(root: t.root))
        XCTAssertEqual(created.first, ".git")
        XCTAssertTrue(FileManager.default.fileExists(atPath: t.root.appendingPathComponent(".git/HEAD").path))
        XCTAssertEqual(ProjectChecker.check(root: t.root).issues, [])
    }

    // MARK: Marker

    func testMarkerRoundTripsAndSkipsJunk() {
        let id = UUID()
        let text = "# A\n<!-- flamingo: not json -->\n" + ProjectMarker(project: id).rendered + "\n"
        XCTAssertEqual(ProjectMarker.find(in: text), ProjectMarker(project: id, structure: 1))
        XCTAssertNil(ProjectMarker.find(in: "# A\n"))
    }
}
