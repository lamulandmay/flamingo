import XCTest
import FlamingoCore
import FlamingoAsk
import FlamingoIndex
import FlamingoTrail
@testable import FlamingoThoughts

/// Thoughts never leave this Mac. The night shift, with a real engine, through a network that
/// refuses everything but loopback; and the thought code searched for any way out.
final class NightShiftLocalOnlyTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("night-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Price\nThe deck prices Arc at $249 retail.\n".write(to: root.appendingPathComponent("deck.md"), atomically: true, encoding: .utf8)
        try "# Assumptions\nArc ASP 229 from the August plan.\n".write(to: root.appendingPathComponent("model.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testAWholeNightWithARealEngineReachesOnlyLoopback() async throws {
        let vault = Vault(root: root)
        let index = try IndexStore(vault: vault)
        let store = SidecarStore(vault: vault)
        let deck = FileRef(relativePath: "deck.md")
        try store.append(Comment(timestamp: at("2026-10-16 18:40"), text: "review conflict between this and [[model.md]]",
                                 provenance: CommentProvenance(origin: .human),
                                 meta: ThoughtMeta(uid: "tnight0001", kind: .intent, kindBy: .model,
                                                   intent: ThoughtIntent(action: "review-conflict", objects: ["deck.md", "model.md"]))), to: deck)
        try index.reindex()

        let saved = LocalCompletionRuntime.current
        defer { LocalCompletionRuntime.current = saved; NightStub.reset(nil) }
        var runtime = LocalCompletionRuntime()
        runtime.session = NightStub.session
        runtime.llama = { _, _ in URL(string: "http://127.0.0.1:8081/v1")! }
        runtime.environment = { [:] }
        LocalCompletionRuntime.current = runtime
        NightStub.reset { url, body in
            guard url.path.hasSuffix("/chat/completions") else { return nil }
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            let prompt = ((json?["messages"] as? [[String: Any]])?.last?["content"] as? String) ?? ""
            let reply = #"{"title":"Arc price differs","tldr":"The deck says $249 and the model $229.","verdict":"conflict","conflicts":[{"topic":"Arc price","a":{"passage":"@deck.md","quote":"prices Arc at $249"},"b":{"passage":"@model.md","quote":"Arc ASP 229"},"why":"Different prices."}],"consistent":[],"next":"Align them."}"#
            return NightStub.chat(LocalCompletionRuntime.resolvePassageReferences(in: reply, prompt: prompt))
        }

        let trail = TrailStore(vault: vault)
        let engine = AskEngine(index: index)
        let service = NightShiftService(vault: vault, index: index, store: store, trail: trail, worker: engine, clock: { at("2026-10-17 02:00") })
        service.calendar = testCalendar
        let outcome = await service.runTonight(power: .pluggedIn, idleSeconds: 3600)
        guard case .ran(let summary) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(summary.replied, 1, "\(service.ledger.events().compactMap(\.error))")

        XCTAssertFalse(NightStub.urls.isEmpty)
        XCTAssertEqual(NightStub.violations, [], "nothing but loopback")
        XCTAssertTrue(NightStub.urls.allSatisfy { $0.host == "127.0.0.1" })
        let reply = try XCTUnwrap(store.comments(for: deck).first { $0.meta?.parent == "tnight0001" })
        XCTAssertEqual(reply.provenance?.origin, .ai)
        XCTAssertTrue(reply.text.contains("[[deck.md"), reply.text)
        XCTAssertNotNil(reply.meta?.work)
        let memo = try XCTUnwrap(WorkMemo.read(at: vault.stateDir.appendingPathComponent(try XCTUnwrap(reply.meta?.work))))
        XCTAssertEqual(memo.provider, "llama")
    }

    func testWithNoLocalModelTheNightWaitsAndTriesNothingElse() async throws {
        let vault = Vault(root: root)
        let index = try IndexStore(vault: vault)
        let store = SidecarStore(vault: vault)
        let deck = FileRef(relativePath: "deck.md")
        try store.append(Comment(timestamp: at("2026-10-16 18:40"), text: "review conflict between this and [[model.md]]",
                                 provenance: CommentProvenance(origin: .human),
                                 meta: ThoughtMeta(uid: "tnight0002", kind: .intent, kindBy: .model,
                                                   intent: ThoughtIntent(action: "review-conflict", objects: ["deck.md", "model.md"]))), to: deck)
        try index.reindex()
        let saved = LocalCompletionRuntime.current
        defer { LocalCompletionRuntime.current = saved; NightStub.reset(nil) }
        var runtime = LocalCompletionRuntime()
        runtime.session = NightStub.session
        runtime.llama = { _, _ in throw AskError.unavailable("llama-server isn't installed") }
        runtime.environment = { [:] }
        LocalCompletionRuntime.current = runtime
        NightStub.reset(nil)
        let engine = AskEngine(index: index)
        let service = NightShiftService(vault: vault, index: index, store: store, trail: TrailStore(vault: vault), worker: engine, clock: { at("2026-10-17 02:00") })
        service.calendar = testCalendar
        _ = await service.runTonight(power: .pluggedIn, idleSeconds: 3600)
        XCTAssertEqual(NightStub.violations, [])
        XCTAssertTrue(try store.comments(for: deck).allSatisfy { $0.meta?.parent == nil }, "no reply")
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.workDir.appendingPathComponent("2026-10-17").path), "no memo")
        let events = service.ledger.events()
        XCTAssertTrue(events.contains { $0.event == .failed }, "failed quietly, in the ledger")
    }

    // MARK: Structure

    /// The thought paths have no way to name a remote provider: the identifiers that reach one
    /// do not appear in them.
    func testThoughtCodeNamesNoRemoteProvider() throws {
        let sources = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        var files = try FileManager.default.contentsOfDirectory(at: sources.appendingPathComponent("FlamingoThoughts"), includingPropertiesForKeys: nil)
        for name in ["LocalCompletion", "ThoughtReader", "ThoughtAsk", "WorkRecipes", "WorkReading", "WorkFingerprint", "MultiFileSource"] {
            files.append(sources.appendingPathComponent("FlamingoAsk/\(name).swift"))
        }
        let forbidden = ["MessagesClient", "ClaudeCodeClient", "KeyStore", "keyProvider", "providerChoice", "AskProvider.preferred",
                         "api.anthropic", "ANTHROPIC_API_KEY", "x-api-key", "claudeCode", "runClaude"]
        XCTAssertGreaterThan(files.count, 15)
        for file in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file)
            // Comments may say what is not done; code may not do it.
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for word in forbidden { XCTAssertFalse(code.contains(word), "\(file.lastPathComponent) mentions \(word)") }
            XCTAssertFalse(code.contains("https://"), "\(file.lastPathComponent) names a remote URL")
        }
    }

    func testTheThoughtModuleDependsOnNoRemoteClientEither() throws {
        let package = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Package.swift")
        let text = try String(contentsOf: package)
        XCTAssertTrue(text.contains(#"name: "FlamingoThoughts", dependencies: ["FlamingoCore", "FlamingoIndex", "FlamingoAsk", "FlamingoTrail"]"#))
    }
}
