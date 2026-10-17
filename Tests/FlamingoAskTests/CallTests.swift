import XCTest
import FlamingoCore
import FlamingoIndex
@testable import FlamingoAsk

final class CallTests: XCTestCase {
    // MARK: SSE and accumulation

    func testSSEParserJoinsDataLinesAndSkipsComments() {
        var p = SSEParser()
        XCTAssertNil(p.feed(": keepalive"))
        XCTAssertNil(p.feed("event: content_block_delta"))
        XCTAssertNil(p.feed("data: {\"a\":"))
        XCTAssertNil(p.feed("data:1}"))
        XCTAssertEqual(p.feed(""), SSEParser.Event(name: "content_block_delta", data: "{\"a\":\n1}"))
        XCTAssertNil(p.feed(""), "blank line with nothing pending")
    }

    func testAccumulatorKeepsThinkingSignatureAndToolInput() throws {
        var m = StreamedMessage()
        var shown = ""
        for e in SSE.message(text: ["Kept ", "$49 [1]."], tools: [("toolu_1", #"{"query": "churn"}"#)], stop: "tool_use") {
            if let t = try m.apply(e) { shown += t }
        }
        XCTAssertEqual(shown, "Kept $49 [1].")
        XCTAssertEqual(m.text, "Kept $49 [1].")
        XCTAssertEqual(m.stopReason, "tool_use")
        XCTAssertEqual(m.content[0], ["type": "thinking", "thinking": "", "signature": "sig-abc"],
                       "an empty thinking block keeps its signature so it can be replayed")
        XCTAssertEqual(m.content[2]["input"], ["query": "churn"])
        XCTAssertTrue(m.invalidInputs.isEmpty)
        XCTAssertTrue(m.finished)
    }

    func testAccumulatorFlagsInvalidToolInput() throws {
        var m = StreamedMessage()
        for e in SSE.message(thinking: false, text: [], tools: [("toolu_1", #"{"query": "ch"#)], stop: "tool_use") {
            _ = try m.apply(e)
        }
        XCTAssertEqual(m.invalidInputs[0], #"{"query": "ch"#)
    }

    func testStreamErrorEventThrows() {
        var m = StreamedMessage()
        XCTAssertThrowsError(try m.apply(["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]])) {
            XCTAssertEqual($0 as? AskError, .overloaded)
        }
    }

    // MARK: Request shape

    func testRequestShape() async throws {
        MockAPI.reset([SSE.reply(SSE.message(text: ["ok"]))])
        let body = Prompt.body(model: AskEngine.defaultModel, messages: [Prompt.question("q?", passages: [], today: Date())])
        _ = try await MockAPI.client.send(body, key: "sk-test", betas: Prompt.betas(model: AskEngine.defaultModel)) { _ in }

        let (request, sent) = try XCTUnwrap(MockAPI.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        XCTAssertEqual(sent["model"], "claude-sonnet-5-5")
        XCTAssertEqual(sent["max_tokens"], .int(16000))
        XCTAssertEqual(sent["stream"], true)
        XCTAssertEqual(sent["output_config"], ["effort": "low"])
        XCTAssertEqual(sent["fallbacks"], "default")
        XCTAssertNil(sent["thinking"], "adaptive by default; disabled would be a 400 on this model")
        XCTAssertNil(sent["tool_choice"])
        XCTAssertTrue(String(decoding: try body.encoded(), as: UTF8.self).contains(#""max_tokens":16000"#))
    }

    func testOtherModelsDropFallbacks() {
        let body = Prompt.body(model: "claude-haiku-4-5", messages: [])
        XCTAssertNil(body["fallbacks"])
        XCTAssertNil(body["output_config"])
        XCTAssertNil(Prompt.body(model: "claude-opus-4-1", messages: [])["output_config"], "effort arrived with Opus 4.5")
        XCTAssertNotNil(Prompt.body(model: "claude-opus-5-5", messages: [])["output_config"])
        XCTAssertEqual(Prompt.betas(model: "claude-haiku-4-5"), [])
    }

    // MARK: Errors and retries

    func testRejectedKey() async {
        MockAPI.reset([SSE.error(401, "authentication_error", "invalid x-api-key")])
        do {
            _ = try await MockAPI.client.send([:], key: "bad", betas: []) { _ in }
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? AskError, .keyRejected)
            XCTAssertEqual(MockAPI.requests.count, 1, "not retried")
        }
    }

    func testOverloadIsRetried() async throws {
        MockAPI.reset([SSE.error(529, "overloaded_error", "Overloaded"), SSE.reply(SSE.message(text: ["fine"]))])
        let m = try await MockAPI.client.send([:], key: "k", betas: []) { _ in }
        XCTAssertEqual(m.text, "fine")
        XCTAssertEqual(MockAPI.requests.count, 2)
    }

    func testBadRequestSurfacesFirstLineOfMessage() async {
        MockAPI.reset([SSE.error(400, "invalid_request_error", "messages: bad\nmore detail")])
        do {
            _ = try await MockAPI.client.send([:], key: "k", betas: []) { _ in }
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? AskError, .api(status: 400, message: "messages: bad"))
        }
    }

    // MARK: Citations

    func testCitationNumbers() {
        XCTAssertEqual(CitationParser.numbers(in: "a [1] b [2][3] c [2, 4] d [[5]] e [6](x) f [7,8] g [ 9 ]"), [1, 2, 3, 4, 7, 8, 9])
    }

    func testAnswerDedupesPlacesAndDropsUnknownNumbers() {
        let slide = Citation(file: Fixture.deck, anchor: FileAnchor(kind: .slide, value: "7"))
        let sheet = Citation(file: Fixture.sheet, anchor: FileAnchor(kind: .sheet, value: "Price"))
        let a = CitationParser.answer(text: " Kept $49 [1][2]. The sheet agrees [3]. See [9]. ",
                                      sources: [1: slide, 2: slide, 3: sheet])
        XCTAssertEqual(a.text, "Kept $49 [1][2]. The sheet agrees [3]. See [9].")
        XCTAssertEqual(a.citations, [slide, sheet])
        XCTAssertEqual(a.sources, [1: slide, 2: slide, 3: sheet])
    }

    // MARK: End to end

    func makeEngine(key: String? = "sk-test") throws -> AskEngine {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AskEngine(index: try IndexStore(vault: Vault(root: dir)), source: Fixture.vault,
                         client: MockAPI.client, key: { key })
    }

    func testAskStreamsTextThenAnswerWithCitations() async throws {
        MockAPI.reset([SSE.reply(SSE.message(text: ["You decided to keep **$49** and drop ", "the annual discount [1]. ",
                                                    "The model's Price sheet already shows it [3]."]))])
        let engine = try makeEngine()
        var passages: [Passage] = []
        var streamed = ""
        var answer: Answer?
        for try await delta in engine.askStreaming("what did I decide about pricing") {
            switch delta {
            case .passages(let p): passages += p
            case .text(let t): XCTAssertNil(answer); streamed += t
            case .answer(let a): answer = a
            default: break
            }
        }
        let a = try XCTUnwrap(answer)
        XCTAssertEqual(streamed, a.text)
        XCTAssertEqual(a.sources[1], passages[0].citation)
        XCTAssertEqual(a.citations.count, 2)

        let sent = try XCTUnwrap(MockAPI.requests.first?.body)
        let content = try XCTUnwrap(sent["messages"]?.array?.first?["content"]?.array)
        // Claude is not on this Mac: the deck's comment ("Decided: keep $49…") stays home, so the
        // first passage is a section of a file.
        XCTAssertTrue(content[0]["text"]?.string?.hasPrefix("<passages>\n<passage id=\"1\" kind=\"section\"") ?? false)
        XCTAssertFalse(content[0]["text"]?.string?.contains("kind=\"comment\"") ?? true)
        XCTAssertTrue(content.last?["text"]?.string?.hasSuffix("<question>\nwhat did I decide about pricing\n</question>") ?? false,
                      "the question comes last")
    }

    func testNoKeyFailsBeforeAnyRequest() async throws {
        MockAPI.reset([])
        let engine = try makeEngine(key: nil)
        do { _ = try await engine.ask("pricing"); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? AskError, .noKey) }
        XCTAssertTrue(MockAPI.requests.isEmpty)
    }

    func testRefusalIsAnError() async throws {
        MockAPI.reset([SSE.reply(SSE.message(text: ["partial"], stop: "refusal"))])
        let engine = try makeEngine()
        do { _ = try await engine.ask("pricing"); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? AskError, .refused) }
    }
}
