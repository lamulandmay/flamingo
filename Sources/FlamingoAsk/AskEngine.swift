import Foundation
import FlamingoCore
import FlamingoIndex

public struct Citation: Sendable, Equatable, Identifiable {
    public var id: String { file.relativePath + (anchor?.rendered ?? "") }
    public var file: FileRef
    public var anchor: FileAnchor?
    public init(file: FileRef, anchor: FileAnchor? = nil) { self.file = file; self.anchor = anchor }
}

public struct Answer: Sendable, Equatable {
    public var text: String
    public var citations: [Citation]
    /// What each `[n]` in `text` points at, for the numbers that resolve to a passage.
    public var sources: [Int: Citation] = [:]
    public init(text: String, citations: [Citation]) { self.text = text; self.citations = citations }
}

/// What `askStreaming` yields, in order: passages, then text as it arrives, then the answer.
public enum Delta: Sendable, Equatable {
    /// Retrieved context. Arrives first, and again after each search the model makes.
    case passages([Passage])
    /// The next piece of answer text.
    case text(String)
    /// The model is searching the vault for this before answering.
    case searching(String)
    /// The text since the last search was a preamble to a tool call, not the answer. Drop it.
    case discard
    /// The finished answer, with citations parsed.
    case answer(Answer)
}

/// Retrieval over the index + a Claude call. Plan 09 owns.
public final class AskEngine: @unchecked Sendable {
    public let index: IndexStore
    public init(index: IndexStore) {
        self.index = index
        self.source = IndexSource(index: index)
    }

    /// The latest Sonnet-class model. The shell may switch it.
    public static let defaultModel = "claude-sonnet-5-5"

    public var model: String {
        get { lock.withLock { _model } }
        set { lock.withLock { _model = newValue } }
    }

    /// True when `ANTHROPIC_API_KEY` is set or a key is in the Keychain.
    public static var hasKey: Bool { KeyStore.key() != nil }

    /// Stores the key in the Keychain item `com.flamingo.anthropic`.
    public static func setKey(_ key: String) throws { try KeyStore.save(key) }

    /// The passages a question retrieves: the user's matching comments first, then sections
    /// by rank, packed into about 12k tokens and numbered from 1.
    public func retrieve(_ question: String) throws -> [Passage] {
        try Retriever(source: source).retrieve(question)
    }

    public func ask(_ question: String) async throws -> Answer {
        var answer: Answer?
        for try await delta in askStreaming(question) {
            if case .answer(let a) = delta { answer = a }
        }
        guard let answer else { throw AskError.stream("No answer") }
        return answer
    }

    /// Retrieves, streams the answer as it's written, and finishes with `.answer`.
    /// Cancelling the consuming task cancels the request.
    public func askStreaming(_ question: String) -> AsyncThrowingStream<Delta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached { [self] in
                do {
                    try await self.run(question) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Internals

    let source: PassageSource
    var client = MessagesClient()
    var keyProvider: @Sendable () -> String? = { KeyStore.key() }
    private let lock = NSLock()
    private var _model = AskEngine.defaultModel

    init(index: IndexStore, source: PassageSource, client: MessagesClient, key: @escaping @Sendable () -> String?) {
        self.index = index
        self.source = source
        self.client = client
        self.keyProvider = key
    }

    /// Retrieve, then let the model search up to `Prompt.maxSearches` times before it answers.
    private func run(_ question: String, yield: @escaping @Sendable (Delta) -> Void) async throws {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard let key = keyProvider() else { throw AskError.noKey }

        let retriever = Retriever(source: source)
        let passages = try retriever.retrieve(question)
        yield(.passages(passages))
        var sources = Dictionary(uniqueKeysWithValues: passages.map { ($0.id, $0.citation) })

        let model = self.model
        var messages: [JSON] = [Prompt.question(question, passages: passages, today: Date())]
        var searches = 0
        for turn in 0... {
            try Task.checkCancellation()
            let body = Prompt.body(model: model, messages: messages, canSearch: searches < Prompt.maxSearches)
            let message = try await client.send(body, key: key, betas: Prompt.betas(model: model)) { yield(.text($0)) }
            try Self.check(message)

            let calls = Self.toolCalls(in: message)
            // One turn past the searches is the most an answer needs; past that, answer with what came back.
            guard message.stopReason == "tool_use", !calls.isEmpty, turn <= Prompt.maxSearches + 1 else {
                yield(.answer(CitationParser.answer(text: message.text, sources: sources)))
                return
            }
            if !message.text.isEmpty { yield(.discard) }

            messages.append(["role": "assistant", "content": .array(Self.replayable(message.content))])
            var results: [JSON] = []
            for call in calls {
                if let raw = call.invalidInput {
                    let error: JSON = ["INVALID_JSON": .string(raw)]
                    results.append(Prompt.toolError(id: call.id, String(decoding: try error.encoded(), as: UTF8.self)))
                } else if call.name.lowercased() != "search" {
                    results.append(Prompt.toolError(id: call.id, "Unknown tool \(call.name). The only tool is `search`."))
                } else if searches >= Prompt.maxSearches {
                    results.append(Prompt.toolError(id: call.id, "No searches left. Answer from the passages you have."))
                } else if let query = call.input["query"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !query.isEmpty {
                    searches += 1
                    yield(.searching(query))
                    let found = (try? retriever.retrieve(query, budgetTokens: 4000)) ?? []
                    for p in found { sources[p.id] = p.citation }
                    if !found.isEmpty { yield(.passages(found)) }
                    results.append(Prompt.searchResult(id: call.id, passages: found))
                } else {
                    results.append(Prompt.toolError(id: call.id, "`query` must be a non-empty string."))
                }
            }
            messages.append(["role": "user", "content": .array(results)])
        }
    }

    struct ToolCall {
        var id: String
        var name: String
        var input: JSON
        /// Set when the streamed input wasn't valid JSON; the tool doesn't run.
        var invalidInput: String?
    }

    /// The `tool_use` blocks to answer: those after the last fallback boundary, since a model
    /// that declined mid-turn doesn't get its calls run.
    static func toolCalls(in message: StreamedMessage) -> [ToolCall] {
        let start = (message.content.lastIndex { $0["type"]?.string == "fallback" } ?? -1) + 1
        return message.content.indices.dropFirst(start).compactMap { i in
            let block = message.content[i]
            guard block["type"]?.string == "tool_use", let id = block["id"]?.string else { return nil }
            return ToolCall(id: id, name: block["name"]?.string ?? "", input: block["input"] ?? [:],
                            invalidInput: message.invalidInputs[i])
        }
    }

    /// The assistant turn as it goes back. Thinking blocks travel unchanged (signature and all,
    /// even when empty). Before a fallback boundary only text survives; the marker itself is dropped.
    static func replayable(_ content: [JSON]) -> [JSON] {
        let boundary = content.lastIndex { $0["type"]?.string == "fallback" } ?? -1
        return content.enumerated().compactMap { i, block in
            let type = block["type"]?.string
            if type == "fallback" || block == .null { return nil }
            if i < boundary, type != "text" { return nil }
            switch type {
            case "text":
                return ["type": "text", "text": block["text"] ?? ""]
            case "thinking":
                return ["type": "thinking", "thinking": block["thinking"] ?? "", "signature": block["signature"] ?? ""]
            case "redacted_thinking":
                return ["type": "redacted_thinking", "data": block["data"] ?? ""]
            case "tool_use":
                return ["type": "tool_use", "id": block["id"] ?? "", "name": block["name"] ?? "", "input": block["input"] ?? [:]]
            default:
                return block
            }
        }
    }

    /// Stop reasons that mean there's no usable answer. A refusal can cut a tool call off
    /// mid-input, so its tools never run either.
    static func check(_ message: StreamedMessage) throws {
        if message.stopReason == "refusal" { throw AskError.refused }
        if message.stopReason == "max_tokens", message.text.isEmpty { throw AskError.stream("Answer cut off") }
    }
}

/// `[3]`, `[2][5]` and `[2, 5]` in answer text.
enum CitationParser {
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<!\[)\[(\d{1,4}(?:\s*,\s*\d{1,4})*)\](?![\(\]])"#)

    /// Cited passage numbers in order of first appearance.
    static func numbers(in text: String) -> [Int] {
        let ns = text as NSString
        var seen = Set<Int>()
        var out: [Int] = []
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            for part in ns.substring(with: m.range(at: 1)).split(separator: ",") {
                if let n = Int(part.trimmingCharacters(in: .whitespaces)), seen.insert(n).inserted { out.append(n) }
            }
        }
        return out
    }

    /// The answer with citations deduped by place, in the order they're first cited. Numbers
    /// that don't name a passage are left in the text and dropped from the citations.
    static func answer(text: String, sources: [Int: Citation]) -> Answer {
        var places = Set<String>()
        var citations: [Citation] = []
        var cited: [Int: Citation] = [:]
        for n in numbers(in: text) {
            guard let c = sources[n] else { continue }
            cited[n] = c
            if places.insert(c.id).inserted { citations.append(c) }
        }
        var answer = Answer(text: text.trimmingCharacters(in: .whitespacesAndNewlines), citations: citations)
        answer.sources = cited
        return answer
    }
}
