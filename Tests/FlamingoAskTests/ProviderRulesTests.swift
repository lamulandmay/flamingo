import XCTest
import FlamingoCore
import FlamingoIndex
@testable import FlamingoAsk

/// The pure parts of the providers: model capability rules, Claude Code's argv, where the
/// local model and server are looked for, and a local answer the length limit cut off.
final class ProviderRulesTests: XCTestCase {
    func testModelIDsParseFamilyAndVersion() {
        let cases: [(String, String, [Int])] = [
            ("claude-opus-5-5", "opus", [5, 5]), ("claude-opus-5", "opus", [5]),
            ("claude-opus-4-20250514", "opus", [4]), ("claude-sonnet-5-5[1m]", "sonnet", [5, 5]),
        ]
        for (id, family, version) in cases {
            XCTAssertEqual(ModelID(id)?.family, family, id)
            XCTAssertEqual(ModelID(id)?.version, version, id)
        }
        XCTAssertNil(ModelID("sonnet"))
        XCTAssertNil(ModelID("qwen3.8-27b"))
    }

    func testCapabilitiesFollowFamilies() {
        for model in ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"] {
            XCTAssertTrue(Prompt.supportsEffort(model), model)
        }
        for model in ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5", "claude-opus-6"] {
            XCTAssertTrue(Prompt.supportsFallbacks(model), model)
        }
        // Haiku takes effort but has no server-side fallback; older Sonnets have neither rule.
        XCTAssertFalse(Prompt.supportsFallbacks("claude-haiku-5-5"))
        XCTAssertFalse(Prompt.supportsFallbacks("claude-sonnet-5"))
        XCTAssertFalse(Prompt.supportsEffort("claude-sonnet-4-5"))
        XCTAssertFalse(Prompt.supportsEffort("claude-haiku-4-5"))
        XCTAssertTrue(Prompt.supportsEffort("claude-opus-4-5-20251101"))
        XCTAssertEqual(Prompt.betas(model: "claude-haiku-5-5"), [])
    }

    func testClaudeCodeGetsTheModelAndAPromptFileNotThePrompt() {
        let args = ClaudeCodeClient.arguments(model: "claude-opus-5-5", systemPromptFile: "/tmp/p.txt")
        XCTAssertEqual(args[args.firstIndex(of: "--model")! + 1], "claude-opus-5-5")
        XCTAssertEqual(args[args.firstIndex(of: "--system-prompt-file")! + 1], "/tmp/p.txt")
        XCTAssertFalse(args.contains("--system-prompt"))
        XCTAssertFalse(ClaudeCodeClient.arguments(model: "", systemPromptFile: "/tmp/p.txt").contains("--model"))
    }

    func testLlamaServerIsLookedForOnHomebrewThenPath() {
        let binaries = LlamaServer.binaries
        XCTAssertEqual(Array(binaries.prefix(2)), ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"])
        XCTAssertEqual(Set(binaries).count, binaries.count)
        XCTAssertTrue(binaries.allSatisfy { $0.hasSuffix("/llama-server") })
    }

    func testStandardModelFolderIsFlamingosOwnWhenNoneHoldsAModel() throws {
        UserDefaults.standard.removeObject(forKey: "FlamingoLlamaModelDir")
        guard ProcessInfo.processInfo.environment["FLAMINGO_LLAMA_MODEL_DIR"] == nil else { throw XCTSkip("env overrides") }
        let first = try XCTUnwrap(LlamaServer.standardDirectories.first)
        XCTAssertTrue(first.path.hasSuffix("Flamingo/Models/\(LlamaServer.modelName)"))
        let expected = LlamaServer.standardDirectories.first(where: LlamaServer.holdsModel) ?? first
        XCTAssertEqual(LlamaServer.shared.modelDirectory, expected)
        XCTAssertEqual(LlamaServer.shared.modelAlias, LlamaServer.modelName)
    }

    func testLengthFinishKeepsTheAnswerMarkedTruncated() async throws {
        let events = [#"{"choices":[{"index":0,"delta":{"content":"Keep $49 [1] and"}}]}"#,
                      #"{"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#, "[DONE]"]
        MockAPI.reset([MockAPI.Reply(status: 200, body: Data(events.map { "data: \($0)\n\n" }.joined().utf8))])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let engine = AskEngine(index: try IndexStore(vault: Vault(root: dir)), source: Fixture.vault,
                               client: MockAPI.client, key: { nil })
        engine.chat = ChatClient(session: MockAPI.session)
        engine.providerChoice = { .llama }
        engine.llama = { _ in LocalModelTests.llamaURL }
        let answer = try await engine.ask("pricing")
        XCTAssertTrue(answer.text.hasPrefix("Keep $49"))
        XCTAssertTrue(answer.truncated)
    }

    func testLengthFinishStillThrowsForWholeOutputCallers() async throws {
        let events = [#"{"choices":[{"index":0,"delta":{"content":"{\"a\":"}}]}"#,
                      #"{"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#, "[DONE]"]
        MockAPI.reset([MockAPI.Reply(status: 200, body: Data(events.map { "data: \($0)\n\n" }.joined().utf8))])
        let endpoint = ChatEndpoint(baseURL: LocalModelTests.llamaURL, model: "m", kind: .llama)
        do { _ = try await ChatClient(session: MockAPI.session).send(["model": "m"], to: endpoint) { _ in }; XCTFail("should throw") }
        catch { XCTAssertNotNil(error as? AskError) }
    }
}
