import XCTest
import FlamingoCore
@testable import FlamingoAgents

final class AgentPresenceTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlamingoAgentsTests-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        base = URL(fileURLWithPath: ProjectResolver.canonical(url.path), isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func path(_ relative: String) -> String { base.appendingPathComponent(relative).path }

    private func folder(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
    }

    private func file(_ relative: String, _ text: String, modified: Date? = nil) throws {
        try FileManager.default.createDirectory(atPath: (path(relative) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path(relative), atomically: true, encoding: .utf8)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path(relative)) }
    }

    /// A vault holding a workspace of two repos (one with a worktree), a plain folder and a home.
    private func makeVault() throws -> ProjectResolver {
        try folder("vault/ws/a/.git")
        try folder("vault/ws/a/src")
        try folder("vault/ws/b/.git")
        try file("vault/ws/a/.claude/worktrees/w/.git", "gitdir: \(path("vault/ws/a/.git/worktrees/w"))\n")
        try folder("vault/ws/a/.claude/worktrees/w/Sources")
        try folder("vault/notes/essay")
        try folder("vault/.hidden/x")
        try folder("vault/home/Documents")
        var resolver = ProjectResolver(vaultRoot: base.appendingPathComponent("vault"), home: base.appendingPathComponent("vault/home"))
        resolver.excluded = []
        return resolver
    }

    // MARK: Which folder is the project

    func testTheRepoIsTheProject() throws {
        let r = try makeVault()
        XCTAssertEqual(r.project(for: path("vault/ws/a/src"))?.path, path("vault/ws/a"))
        XCTAssertEqual(r.project(for: path("vault/ws/a"))?.path, path("vault/ws/a"))
    }

    func testAWorktreeBelongsToItsMainRepo() throws {
        let r = try makeVault()
        XCTAssertEqual(r.project(for: path("vault/ws/a/.claude/worktrees/w/Sources"))?.path, path("vault/ws/a"))
    }

    func testAFolderWithoutARepoIsItsOwnProject() throws {
        let r = try makeVault()
        XCTAssertEqual(r.project(for: path("vault/notes/essay"))?.path, path("vault/notes/essay"))
    }

    func testFoldersThatAreNeverOffered() throws {
        let r = try makeVault()
        XCTAssertNil(r.project(for: path("vault/ws")), "a workspace of repos")
        XCTAssertNil(r.project(for: path("vault")), "the vault root")
        XCTAssertNil(r.project(for: path("vault/home")), "home")
        XCTAssertNil(r.project(for: path("vault/home/Documents")), "Documents")
        XCTAssertNil(r.project(for: path("vault/.hidden/x")), "a hidden folder")
        XCTAssertNil(r.project(for: path("elsewhere")), "outside the vault")
        // With the real exclusions, temporary folders (under /private) are never projects.
        XCTAssertNil(ProjectResolver(vaultRoot: URL(fileURLWithPath: "/")).project(for: path("vault/notes/essay")))
    }

    func testSymlinkedPathsResolveToTheSameProject() throws {
        let r = try makeVault()
        try FileManager.default.createSymbolicLink(atPath: path("vault/link"), withDestinationPath: path("vault/ws/a"))
        XCTAssertEqual(r.project(for: path("vault/link/src"))?.path, path("vault/ws/a"))
    }

    // MARK: Logs

    func testClaudeLogGivesTheNewestFolderAndTitlePastLongLines() throws {
        let blob = String(repeating: "x", count: 300_000)
        try file("home/.claude/projects/-p/abc.jsonl", """
        {"type":"user","cwd":"/old/place","sessionId":"abc"}
        {"type":"ai-title","aiTitle":"Fix the lamp","sessionId":"abc"}
        {"type":"assistant","cwd":"/p/proj","sessionId":"abc"}
        {"type":"api-request-blob","data":"\(blob)"}

        """)
        try file("home/.claude/projects/-p/old.jsonl", #"{"cwd":"/p/stale"}"# + "\n", modified: Date(timeIntervalSinceNow: -3600))
        let logs = AgentLogs(home: base.appendingPathComponent("home"))
        let found = logs.recent(since: Date(timeIntervalSinceNow: -900))
        XCTAssertEqual(found.map(\.cwd), ["/p/proj"])
        XCTAssertEqual(found.first?.title, "Fix the lamp")
        XCTAssertEqual(found.first?.id, "abc")
        XCTAssertEqual(found.first?.harness, .claudeCode)
    }

    func testCodexLogsAreReadFromTheirFirstLineAcrossDayFolders() throws {
        let calendar = Calendar(identifier: .gregorian)
        func day(_ back: Int) -> String {
            let c = calendar.dateComponents(in: .current, from: calendar.date(byAdding: .day, value: -back, to: Date())!)
            return String(format: "home/.codex/sessions/%04d/%02d/%02d", c.year!, c.month!, c.day!)
        }
        let instructions = String(repeating: "y", count: 400_000)
        func meta(_ id: String, _ cwd: String) -> String {
            #"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)","base_instructions":{"text":"\#(instructions)"}}}"# + "\n{}\n"
        }
        try file(day(0) + "/rollout-today.jsonl", meta("t", "/p/today"))
        try file(day(3) + "/rollout-old.jsonl", meta("o", "/p/long-running"))
        try file(day(10) + "/rollout-ancient.jsonl", meta("x", "/p/ancient"))
        try file(day(0) + "/rollout-odd.jsonl", #"{"type":"event_msg"}"# + "\n")
        let found = AgentLogs(home: base.appendingPathComponent("home")).recent(since: Date(timeIntervalSinceNow: -900))
        XCTAssertEqual(Set(found.map(\.cwd)), ["/p/today", "/p/long-running"])
        XCTAssertEqual(Set(found.map(\.id)), ["t", "o"])
        XCTAssertTrue(found.allSatisfy { $0.harness == .codex })
    }

    // MARK: Presence and offers

    func testActivityMergesProcessesAndLogsPerProject() throws {
        _ = try makeVault()
        try file("vault/home/.claude/projects/-a/s1.jsonl", #"{"cwd":"\#(path("vault/ws/a/.claude/worktrees/w"))"}"# + "\n" +
                 #"{"type":"ai-title","aiTitle":"Sort menu"}"# + "\n")
        var presence = AgentPresence(vaultRoot: base.appendingPathComponent("vault"), home: base.appendingPathComponent("vault/home"))
        presence.resolver.excluded = []
        let cwd = path("vault/ws/a/src")
        presence.processes = { [AgentProcesses.Found(pid: 42, harness: .claudeCode, cwd: cwd)] }
        let activity = presence.activity()
        XCTAssertEqual(activity.count, 1)
        XCTAssertEqual(activity.first?.project.path, path("vault/ws/a"))
        XCTAssertEqual(activity.first?.isLive, true)
        XCTAssertEqual(activity.first?.session, "s1")
        XCTAssertEqual(activity.first?.title, "Sort menu")
    }

    func testOffersSkipProjectsAndDeclinedFolders() throws {
        _ = try makeVault()
        var presence = AgentPresence(vaultRoot: base.appendingPathComponent("vault"), home: base.appendingPathComponent("vault/home"))
        presence.resolver.excluded = []
        let a = path("vault/ws/a/src"), essay = path("vault/notes/essay"), b = path("vault/ws/b")
        presence.processes = {
            [.init(pid: 1, harness: .claudeCode, cwd: a), .init(pid: 2, harness: .codex, cwd: essay), .init(pid: 3, harness: .claudeCode, cwd: b)]
        }
        try file("vault/notes/essay/AGENTS.md", "# Essay\n" + ProjectMarker(project: UUID()).rendered + "\n")
        let offers = presence.offers(declined: ["ws/b"])
        XCTAssertEqual(offers.map(\.root.path), [path("vault/ws/a")])
    }

    func testDeclinedFoldersPersist() throws {
        try folder("vault2")
        let store = ProjectsStore(vault: Vault(root: base.appendingPathComponent("vault2")))
        XCTAssertEqual(store.declined(), [])
        try store.decline("code/lamp")
        try store.decline("code/ledger")
        try store.forget("code/lamp")
        XCTAssertEqual(ProjectsStore(vault: Vault(root: base.appendingPathComponent("vault2"))).declined(), ["code/ledger"])
    }

    // MARK: A real process

    /// A copy of `sleep` named `claude`, started inside a folder and orphaned so it isn't the
    /// test's own child (Flamingo skips its own children, like Ask's `claude -p`).
    func testALiveClaudeProcessIsFoundWithItsWorkingFolder() throws {
        try folder("bin")
        try folder("work/lamp")
        let claude = path("bin/claude")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: claude)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", #"(cd "$1" && exec "$2" 30) >/dev/null 2>&1 &"#, "sh", path("work/lamp"), claude]
        try shell.run()
        shell.waitUntilExit()

        let scanner = AgentProcesses.Scanner()
        var found: [AgentProcesses.Found] = []
        let deadline = Date(timeIntervalSinceNow: 5)
        var first: TimeInterval?
        repeat {
            let start = Date()
            found = scanner.scan().filter { $0.cwd == path("work/lamp") }
            first = first ?? Date().timeIntervalSince(start)
        } while found.isEmpty && Date() < deadline
        defer { found.forEach { kill($0.pid, SIGTERM) } }

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.harness, .claudeCode)

        var repeats: [TimeInterval] = []
        for _ in 0..<5 {
            let start = Date()
            XCTAssertEqual(scanner.scan().filter { $0.cwd == path("work/lamp") }.count, 1)
            repeats.append(Date().timeIntervalSince(start))
        }
        print("process scan: first \(String(format: "%.1f", (first ?? 0) * 1000)) ms, repeat \(String(format: "%.1f", repeats.min()! * 1000)) ms")
        XCTAssertLessThan(repeats.min()!, 0.02)
    }

    func testHarnessMatching() {
        XCTAssertEqual(AgentProcesses.harness(executable: "/Users/x/.local/share/claude/versions/2.1.302"), .claudeCode)
        XCTAssertEqual(AgentProcesses.harness(executable: "/opt/homebrew/bin/claude"), .claudeCode)
        XCTAssertEqual(AgentProcesses.harness(executable: "/usr/local/bin/codex"), .codex)
        XCTAssertNil(AgentProcesses.harness(executable: "/Applications/Claude.app/Contents/MacOS/Claude"))
        XCTAssertEqual(AgentProcesses.harness(arguments: ["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"]), .claudeCode)
        XCTAssertNil(AgentProcesses.harness(arguments: ["node", "server.js"]))
    }
}
