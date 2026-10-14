import XCTest
import FlamingoCore
import FlamingoIndex
@testable import FlamingoAsk

final class SearchLoopTests: XCTestCase {
    func makeEngine() throws -> AskEngine {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AskEngine(index: try IndexStore(vault: Vault(root: dir)), source: Fixture.vault,
                         client: MockAPI.client, key: { "sk-test" })
    }

    func collect(_ engine: AskEngine, _ question: String) async throws -> [Delta] {
        var out: [Delta] = []
        for try await d in engine.askStreaming(question) { out.append(d) }
        return out
    }

    func testTwoHopQuestionSearchesThenAnswers() async throws {
        // The first retrieval for this question yields the comment and slide 7; churn arrives via search.
        let firstCount = try Retriever(source: Fixture.vault).retrieve("what did I say about the slide that mentions pricing").count
        let churnID = firstCount + 1
        MockAPI.reset([
            SSE.reply(SSE.message(text: ["Let me look."], tools: [("toolu_1", #"{"query": "churn cohort"}"#)], stop: "tool_use")),
            SSE.reply(SSE.message(text: ["Churn fell to 2.1% [\(churnID)]."])),
        ])

        let deltas = try await collect(try makeEngine(), "what did I say about the slide that mentions pricing")

        XCTAssertTrue(deltas.contains(.discard), "the preamble before the tool call is retracted")
        XCTAssertTrue(deltas.contains(.searching("churn cohort")))
        let batches = deltas.compactMap { if case .passages(let p) = $0 { return p } else { return nil } }
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[1].first?.id, churnID, "search results are numbered after the first passages")

        guard case .answer(let answer) = deltas.last else { return XCTFail("ends with the answer") }
        XCTAssertEqual(answer.text, "Churn fell to 2.1% [\(churnID)].")
        XCTAssertEqual(answer.citations, [Citation(file: Fixture.deck, anchor: FileAnchor(kind: .slide, value: "9"))])

        // The second request replays the first verbatim and appends the assistant turn and the results.
        let requests = MockAPI.requests.map(\.body)
        XCTAssertEqual(requests.count, 2)
        let first = try XCTUnwrap(requests[0]["messages"]?.array)
        let second = try XCTUnwrap(requests[1]["messages"]?.array)
        XCTAssertEqual(second.count, 3)
        XCTAssertEqual(second[0], first[0], "append-only: earlier turns unchanged")
        XCTAssertEqual(requests[1]["system"], requests[0]["system"])
        XCTAssertEqual(requests[1]["tools"], requests[0]["tools"])

        let assistant = try XCTUnwrap(second[1]["content"]?.array)
        XCTAssertEqual(second[1]["role"], "assistant")
        XCTAssertEqual(assistant[0], ["type": "thinking", "thinking": "", "signature": "sig-abc"])
        XCTAssertEqual(assistant[2], ["type": "tool_use", "id": "toolu_1", "name": "search", "input": ["query": "churn cohort"]])

        let result = try XCTUnwrap(second[2]["content"]?.array?.first)
        XCTAssertEqual(result["tool_use_id"], "toolu_1")
        XCTAssertTrue(result["content"]?.string?.contains("<passage id=\"\(churnID)\"") ?? false)
        XCTAssertNil(result["is_error"])
    }

    func testSearchesAreCappedThenToolChoiceNoneOnlyIfIgnored() async throws {
        let call = { (n: Int) in SSE.reply(SSE.message(thinking: false, text: [], tools: [("toolu_\(n)", #"{"query": "revenue"}"#)], stop: "tool_use")) }
        MockAPI.reset([call(1), call(2), call(3), call(4), SSE.reply(SSE.message(text: ["Done."]))])
        let deltas = try await collect(try makeEngine(), "pricing")
        XCTAssertEqual(deltas.filter { if case .searching = $0 { return true } else { return false } }.count, 3)
        let requests = MockAPI.requests.map(\.body)
        XCTAssertEqual(requests.count, 5)
        XCTAssertNil(requests[3]["tool_choice"], "auto keeps the cached messages; the model is told instead")
        let fourth = try XCTUnwrap(requests[4]["messages"]?.array?.last?["content"]?.array?.first)
        XCTAssertEqual(fourth["is_error"], true)
        XCTAssertEqual(fourth["content"], "No searches left. Answer from the passages you have.")
        XCTAssertEqual(requests[4]["tool_choice"], ["type": "none"], "only after it searched anyway")
        XCTAssertEqual(requests[4]["tools"], requests[0]["tools"], "tools stay declared so their cache holds")
        guard case .answer(let a) = deltas.last else { return XCTFail("ends with the answer") }
        XCTAssertEqual(a.text, "Done.")
    }

    func testFailedCallsAlsoRunOutOfTurns() async throws {
        let bad = { (n: Int) in SSE.reply(SSE.message(thinking: false, text: [], tools: [("toolu_\(n)", #"{"query": ""}"#)], stop: "tool_use")) }
        MockAPI.reset([bad(1), bad(2), bad(3), bad(4), SSE.reply(SSE.message(text: ["Answer."]))])
        let deltas = try await collect(try makeEngine(), "pricing")
        let requests = MockAPI.requests.map(\.body)
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(requests[4]["tool_choice"], ["type": "none"])
        guard case .answer(let a) = deltas.last else { return XCTFail("ends with the answer") }
        XCTAssertEqual(a.text, "Answer.")
    }

    func testBlankFinalTurnIsAnErrorNotAnEmptyAnswer() async throws {
        MockAPI.reset([SSE.reply(SSE.message(text: []))])
        do { _ = try await collect(try makeEngine(), "pricing"); XCTFail("should throw") }
        catch { XCTAssertEqual(error as? AskError, .stream("No answer")) }
    }

    func testRefusalAfterPartialTextRetractsIt() async throws {
        MockAPI.reset([SSE.reply(SSE.message(text: ["You decided"], stop: "refusal"))])
        var deltas: [Delta] = []
        do {
            for try await d in try makeEngine().askStreaming("pricing") { deltas.append(d) }
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? AskError, .refused)
        }
        XCTAssertEqual(deltas.last, .discard)
    }

    func testInvalidToolInputIsReturnedAsError() async throws {
        MockAPI.reset([
            SSE.reply(SSE.message(thinking: false, text: [], tools: [("toolu_1", #"{"query": "ch"#)], stop: "tool_use")),
            SSE.reply(SSE.message(text: ["Done."])),
        ])
        let deltas = try await collect(try makeEngine(), "pricing")
        XCTAssertFalse(deltas.contains { if case .searching = $0 { return true } else { return false } })
        let result = try XCTUnwrap(MockAPI.requests.last?.body["messages"]?.array?.last?["content"]?.array?.first)
        XCTAssertEqual(result["is_error"], true)
        let payload = try JSON.decode(Data(try XCTUnwrap(result["content"]?.string).utf8))
        XCTAssertEqual(payload["INVALID_JSON"], .string(#"{"query": "ch"#))
    }

    func testMaxTokensWithToolUseDoesNotRunTheTool() async throws {
        MockAPI.reset([SSE.reply(SSE.message(text: ["Partial answer"], tools: [("toolu_1", #"{"query": "x"}"#)], stop: "max_tokens"))])
        let deltas = try await collect(try makeEngine(), "pricing")
        XCTAssertFalse(deltas.contains { if case .searching = $0 { return true } else { return false } })
        XCTAssertEqual(MockAPI.requests.count, 1)
    }

    func testReplayDropsModelInternalBlocksBeforeAFallback() {
        let content: [JSON] = [
            ["type": "thinking", "thinking": "", "signature": "s1"],
            ["type": "text", "text": "partial", "citations": .null],
            ["type": "text", "text": " \n"],
            ["type": "tool_use", "id": "toolu_0", "name": "search", "input": ["query": "a"]],
            ["type": "fallback", "from": ["model": "claude-sonnet-5-5"], "to": ["model": "claude-sonnet-5"]],
            ["type": "thinking", "thinking": "", "signature": "s2"],
            ["type": "text", "text": ""],
            ["type": "tool_use", "id": "toolu_1", "name": "search", "input": ["query": "b"]],
        ]
        XCTAssertEqual(AskEngine.replayable(content), [
            ["type": "text", "text": "partial"],
            ["type": "thinking", "thinking": "", "signature": "s2"],
            ["type": "tool_use", "id": "toolu_1", "name": "search", "input": ["query": "b"]],
        ])
        var message = StreamedMessage()
        message.content = content
        XCTAssertEqual(AskEngine.toolCalls(in: message).map(\.id), ["toolu_1"], "only calls after the boundary run")
    }

    func testSearchToolDefinition() {
        let tool = Prompt.searchTool
        XCTAssertEqual(tool["name"], "search")
        XCTAssertEqual(tool["eager_input_streaming"], true)
        XCTAssertEqual(tool["input_schema"]?["required"], ["query"])
    }
}
