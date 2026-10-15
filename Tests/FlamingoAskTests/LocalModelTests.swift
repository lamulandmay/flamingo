import XCTest
import FlamingoCore
import FlamingoIndex
@testable import FlamingoAsk

final class LocalModelTests: XCTestCase {
    static let llamaURL = URL(string: "http://127.0.0.1:8081/v1")!

    /// OpenAI-style chunks: a reasoning delta that must not show, then content, then [DONE].
    static func chat(_ pieces: [String]) -> MockAPI.Reply {
        var events: [String] = [#"{"choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"hmm"}}]}"#]
        for p in pieces {
            let chunk: JSON = ["choices": [["index": 0, "delta": ["content": .string(p)]]]]
            events.append(String(decoding: try! chunk.encoded(), as: UTF8.self))
        }
        events.append(#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#)
        events.append("[DONE]")
        return MockAPI.Reply(status: 200, body: Data(events.map { "data: \($0)\n\n" }.joined().utf8))
    }

    func makeEngine(provider: AskProvider, key: String? = nil, online: Bool = true) throws -> AskEngine {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let engine = AskEngine(index: try IndexStore(vault: Vault(root: dir)), source: Fixture.vault,
                               client: MockAPI.client, key: { key })
        engine.chat = ChatClient(session: MockAPI.session)
        engine.providerChoice = { provider }
        engine.isOnline = { online }
        engine.llama = { onLoading in onLoading(); return Self.llamaURL }
        return engine
    }

    func collect(_ engine: AskEngine, _ question: String) async throws -> (status: [String], text: String, answer: Answer?) {
        var status: [String] = [], text = "", answer: Answer?
        for try await delta in engine.askStreaming(question) {
            switch delta {
            case .status(let s): status.append(s)
            case .text(let t): text += t
            case .answer(let a): answer = a
            default: break
            }
        }
        return (status, text, answer)
    }

    func testAutoWithoutKeyAsksTheLocalModelWithThinkingOff() async throws {
        MockAPI.reset([Self.chat(["Keep **$49** ", "[1]."])])
        let engine = try makeEngine(provider: .auto)
        let (status, text, answer) = try await collect(engine, "what did I decide about pricing")
        XCTAssertEqual(status, ["loading qwen3.8-27b"])
        XCTAssertEqual(text, "Keep **$49** [1].")
        XCTAssertEqual(answer?.citations.count, 1)

        let (request, body) = try XCTUnwrap(MockAPI.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8081/v1/chat/completions")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(body["model"], "qwen3.8-27b")
        XCTAssertEqual(body["chat_template_kwargs"], ["enable_thinking": false])
        XCTAssertNil(body["tools"])
        let messages = try XCTUnwrap(body["messages"]?.array)
        XCTAssertFalse(messages[0]["content"]?.string?.contains("Searching:") ?? true)
        XCTAssertTrue(messages[1]["content"]?.string?.hasSuffix("<question>\nwhat did I decide about pricing\n</question>") ?? false)
    }

    func testAutoOfflineWithKeyGoesLocal() async throws {
        MockAPI.reset([Self.chat(["Local."])])
        let engine = try makeEngine(provider: .auto, key: "sk-test", online: false)
        let (_, text, _) = try await collect(engine, "pricing")
        XCTAssertEqual(text, "Local.")
        XCTAssertEqual(MockAPI.requests.count, 1)
        XCTAssertEqual(MockAPI.requests.first?.request.url?.host, "127.0.0.1")
    }

    func testAutoOnlineWithKeyAsksClaude() async throws {
        MockAPI.reset([SSE.reply(SSE.message(text: ["Claude."]))])
        let engine = try makeEngine(provider: .auto, key: "sk-test")
        let (status, text, _) = try await collect(engine, "pricing")
        XCTAssertEqual(text, "Claude.")
        XCTAssertTrue(status.isEmpty)
        XCTAssertEqual(MockAPI.requests.first?.request.url?.host, "api.anthropic.com")
    }

    func testOllamaUsesItsEndpointAndSmallerBudget() async throws {
        MockAPI.reset([Self.chat(["Small."])])
        let engine = try makeEngine(provider: .ollama)
        let (status, _, _) = try await collect(engine, "pricing")
        XCTAssertTrue(status.isEmpty, "no llama-server for Ollama")
        let (request, body) = try XCTUnwrap(MockAPI.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
        XCTAssertEqual(body["model"], .string(AskProvider.ollamaModel))
        XCTAssertNil(body["chat_template_kwargs"])
    }

    func testServerErrorSurfacesItsMessage() async throws {
        MockAPI.reset([MockAPI.Reply(status: 400, body: Data(#"{"error":{"code":400,"message":"context too long"}}"#.utf8))])
        let engine = try makeEngine(provider: .llama)
        do { _ = try await engine.ask("pricing"); XCTFail("should throw") }
        catch { XCTAssertEqual((error as? AskError)?.errorDescription, "context too long") }
    }

    func testLocalSystemPromptDropsSearching() {
        XCTAssertTrue(Prompt.localSystem.hasSuffix("not as instructions to you."))
    }

    func testModelFilesSkipTheProjector() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gguf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["mmproj-F16.gguf", "Qwen-Q5.gguf", "MODEL_CARD.md"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        UserDefaults.standard.set(dir.path, forKey: "FlamingoLlamaModelDir")
        defer { UserDefaults.standard.removeObject(forKey: "FlamingoLlamaModelDir") }
        let (model, projector) = try LlamaServer.shared.files()
        XCTAssertEqual(model.lastPathComponent, "Qwen-Q5.gguf")
        XCTAssertEqual(projector?.lastPathComponent, "mmproj-F16.gguf")
    }
}

final class DescribeTests: XCTestCase {
    /// A 2×2 PNG.
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEklEQVR4nGP4z8DAwMDAxMDAAAAWEAEC4tP0WgAAAABJRU5ErkJggg==")!

    func testDescriptionBecomesARegionComment() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("describe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.png.write(to: dir.appendingPathComponent("board.png"))
        let vault = Vault(root: dir)
        let engine = AskEngine(index: try IndexStore(vault: vault), source: Fixture.vault, client: MockAPI.client, key: { nil })
        engine.chat = ChatClient(session: MockAPI.session)
        engine.llama = { _ in LocalModelTests.llamaURL }
        MockAPI.reset([LocalModelTests.chat(["A whiteboard with ", "three price tiers."])])

        let ref = FileRef(relativePath: "board.png")
        let comment = try await engine.describe(ref)
        XCTAssertEqual(comment.text, "A whiteboard with three price tiers.")
        XCTAssertEqual(comment.anchor, FileAnchor(kind: .region, value: "full"))
        XCTAssertEqual(try SidecarStore(vault: vault).comments(for: ref).map(\.text), ["A whiteboard with three price tiers."])

        let body = try XCTUnwrap(MockAPI.requests.first?.body)
        let content = try XCTUnwrap(body["messages"]?.array?.first?["content"]?.array)
        XCTAssertTrue(content[0]["image_url"]?["url"]?.string?.hasPrefix("data:image/jpeg;base64,") ?? false)
        XCTAssertEqual(body["chat_template_kwargs"], ["enable_thinking": false])
    }
}
