import Foundation
import FlamingoCore
import FlamingoIndex

public struct Citation: Sendable, Equatable, Identifiable, Codable {
    public var id: String { file.relativePath + (anchor?.rendered ?? "") }
    public var file: FileRef
    public var anchor: FileAnchor?
    public var excerpt: String?
    public var commentID: UUID?
    public var provenance: CommentProvenance?
    public init(file: FileRef, anchor: FileAnchor? = nil, excerpt: String? = nil,
                commentID: UUID? = nil, provenance: CommentProvenance? = nil) {
        self.file = file; self.anchor = anchor; self.excerpt = excerpt; self.commentID = commentID; self.provenance = provenance
    }
    public static func == (lhs: Citation, rhs: Citation) -> Bool {
        lhs.file == rhs.file && lhs.anchor == rhs.anchor
    }
}

public struct Answer: Sendable, Equatable, Codable {
    public var text: String
    public var citations: [Citation]
    /// What each `[n]` in `text` points at, for the numbers that resolve to a passage.
    public var sources: [Int: Citation] = [:]
    public var model: String?
    public init(text: String, citations: [Citation]) { self.text = text; self.citations = citations }
}

public struct ConversationTurn: Codable, Equatable, Sendable {
    public var question: String
    public var answer: String
    public init(question: String, answer: String) { self.question = question; self.answer = answer }
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
    /// One tertiary line about the model, e.g. `loading qwen3.8-27b` while it loads.
    case status(String)
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

    /// Claude can answer: with an API key, or through the user's Claude Code sign-in.
    public static var claudeReady: Bool { hasKey || ClaudeCodeClient.executable != nil }

    /// Stores the key in the Keychain item `com.flamingo.anthropic`.
    public static func setKey(_ key: String) throws { try KeyStore.save(key) }

    /// The passages a question retrieves: the user's matching comments first, then sections
    /// by rank, packed into about 12k tokens and numbered from 1.
    public func retrieve(_ question: String) throws -> [Passage] {
        try Retriever(source: source).retrieve(question)
    }

    /// Expands a citation from the local index for inspection without making a model call.
    /// The original file remains the authority; extraction may be incomplete.
    public func sourceText(for citation: Citation, maxCharacters: Int = 20_000) throws -> String {
        let text: String?
        if let id = citation.commentID {
            text = try source.comments(on: citation.file).first { $0.id == id }?.text
        } else if let anchor = citation.anchor {
            let sections = try source.sections(of: citation.file)
            let section = sections.first { $0.anchor == anchor }
                ?? (anchor.kind == .line ? sections.filter {
                    $0.anchor.kind == .line && (Int($0.anchor.value) ?? Int.max) <= (Int(anchor.value) ?? 0)
                }.max { (Int($0.anchor.value) ?? 0) < (Int($1.anchor.value) ?? 0) } : nil)
                ?? (anchor.kind == .cell ? sections.first { $0.anchor.kind == .sheet && anchor.value.hasPrefix($0.anchor.value + "!") } : nil)
            text = section?.text
        } else { text = try source.text(of: citation.file) }
        guard let text, !text.isEmpty else { throw AskError.stream("This source changed or is no longer indexed. Open the file to inspect it.") }
        let limit = max(1, min(maxCharacters, 50_000))
        return String(text.prefix(limit)) + (text.count > limit ? "\n[…section continues in the file]" : "")
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
        askStreaming(question, history: [])
    }

    public func askStreaming(_ question: String, history: [ConversationTurn], file: FileRef? = nil, context: AskContext = .empty) -> AsyncThrowingStream<Delta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached { [self] in
                do {
                    let scoped: PassageSource
                    if let file { scoped = SelectedFileSource(base: self.source, file: file) }
                    else { scoped = self.source }
                    try await self.run(question, history: history, source: scoped, context: context) { continuation.yield($0) }
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
    var chat = ChatClient()
    var claudeCode = ClaudeCodeClient()
    var hasClaudeCode: @Sendable () -> Bool = { ClaudeCodeClient.executable != nil }
    var keyProvider: @Sendable () -> String? = { KeyStore.key() }
    var providerChoice: @Sendable () -> AskProvider = { AskProvider.preferred }
    var isOnline: @Sendable () -> Bool = { Reachability.shared.isOnline }
    var llama: @Sendable (@escaping @Sendable () -> Void) async throws -> URL = { try await LlamaServer.shared.endpoint(onLoading: $0) }
    private let lock = NSLock()
    private var _model = AskEngine.defaultModel

    init(index: IndexStore, source: PassageSource, client: MessagesClient, key: @escaping @Sendable () -> String?) {
        self.index = index
        self.source = source
        self.client = client
        self.keyProvider = key
        self.providerChoice = { .claude }
        // Tests never reach a real Claude Code install.
        self.hasClaudeCode = { false }
    }

    /// Claude when chosen, or on auto with a key and a network; otherwise a local model.
    /// On auto, Claude going offline before any text falls back to the local model.
    private func run(_ question: String, history: [ConversationTurn], source: PassageSource, context: AskContext = .empty, yield: @escaping @Sendable (Delta) -> Void) async throws {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let choice = providerChoice()
        switch choice {
        case .claude:
            if keyProvider() == nil, hasClaudeCode() {
                try await runClaudeCode(question, history: history, source: source, context: context, yield: yield)
            } else {
                try await runClaude(question, history: history, source: source, context: context, yield: yield)
            }
        case .llama, .ollama:
            try await runLocal(question, history: history, source: source, context: context, kind: choice, yield: yield)
        case .auto:
            // Automatic sends passages to Claude only with an API key the user entered for
            // Flamingo. Claude Code's sign-in is used only when "Claude" is chosen outright,
            // so files never leave the Mac because some other tool happens to be installed.
            guard keyProvider() != nil, isOnline() else { return try await runLocal(question, history: history, source: source, context: context, kind: .llama, yield: yield) }
            let shown = Flag()
            do {
                try await runClaude(question, history: history, source: source, context: context) { delta in
                    if case .text = delta { shown.set() }
                    yield(delta)
                }
            } catch AskError.offline where !shown.value {
                try await runLocal(question, history: history, source: source, context: context, kind: .llama, yield: yield)
            }
        }
    }

    /// One pass, no search tool. The 27B falls back to Ollama when it can't be started.
    private func runLocal(_ question: String, history: [ConversationTurn], source: PassageSource, context: AskContext = .empty, kind: AskProvider, yield: @escaping @Sendable (Delta) -> Void) async throws {
        var endpoint: ChatEndpoint
        if kind == .ollama {
            endpoint = ChatEndpoint(baseURL: ChatEndpoint.ollama, model: AskProvider.ollamaModel, kind: .ollama)
        } else {
            do {
                let url = try await llama { yield(.status("loading \(LlamaServer.shared.displayName)")) }
                endpoint = ChatEndpoint(baseURL: url, model: LlamaServer.shared.modelAlias, kind: .llama)
            } catch AskError.unavailable(_) where providerChoice() == .auto {
                endpoint = ChatEndpoint(baseURL: ChatEndpoint.ollama, model: AskProvider.ollamaModel, kind: .ollama)
            }
        }
        try Task.checkCancellation()
        let passages = try gather(question, history: history, source: source, context: context, budget: Prompt.localBudget(endpoint.kind)).passages
        yield(.passages(passages))
        let sources = Dictionary(uniqueKeysWithValues: passages.map { ($0.id, $0.citation) })
        let body = Prompt.localBody(endpoint, question: question, passages: passages, today: Date(), history: history, context: context)
        let modelName = endpoint.kind == .llama ? LlamaServer.shared.displayName : endpoint.model
        let text = try await chat.send(body, to: endpoint) { yield(.text($0)) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AskError.stream("No answer") }
        var answer = CitationParser.answer(text: text, sources: sources)
        answer.model = modelName
        yield(.answer(answer))
    }

    /// Claude Code's sign-in, one pass: the same passages and prompt as a local model gets,
    /// at Claude's quality and speed.
    private func runClaudeCode(_ question: String, history: [ConversationTurn], source: PassageSource, context: AskContext, yield: @escaping @Sendable (Delta) -> Void) async throws {
        let passages = try gather(question, history: history, source: source, context: context, budget: 12_000).passages
        yield(.passages(passages))
        let sources = Dictionary(uniqueKeysWithValues: passages.map { ($0.id, $0.citation) })
        let user = Prompt.userText(question, passages: passages, today: Date(), history: history, context: context)
        let text = try await claudeCode.send(system: Prompt.localSystem, user: user) { yield(.text($0)) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AskError.stream("No answer") }
        var answer = CitationParser.answer(text: text, sources: sources)
        answer.model = "claude-" + claudeCode.model
        yield(.answer(answer))
    }

    /// Retrieve, then let the model search up to `Prompt.maxSearches` times before it answers.
    private func runClaude(_ question: String, history: [ConversationTurn], source: PassageSource, context: AskContext = .empty, yield: @escaping @Sendable (Delta) -> Void) async throws {
        guard let key = keyProvider() else { throw AskError.noKey }

        let (passages, retriever) = try gather(question, history: history, source: source, context: context, budget: 12_000)
        yield(.passages(passages))
        var sources = Dictionary(uniqueKeysWithValues: passages.map { ($0.id, $0.citation) })

        let model = self.model
        var messages: [JSON] = [Prompt.question(question, passages: passages, today: Date(), history: history, context: context)]
        var searches = 0
        var forceAnswer = false
        for turn in 0... {
            try Task.checkCancellation()
            let body = Prompt.body(model: model, messages: messages, canSearch: !forceAnswer)
            let message = try await client.send(body, key: key, betas: Prompt.betas(model: model)) { yield(.text($0)) }
            if message.stopReason == "refusal" {
                // A decline can arrive after part of the answer streamed; that part doesn't stand.
                yield(.discard)
                throw AskError.refused
            }
            try Self.check(message)

            let calls = Self.toolCalls(in: message)
            guard message.stopReason == "tool_use", !calls.isEmpty, !forceAnswer else {
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw AskError.stream("No answer") }
                var answer = CitationParser.answer(text: message.text, sources: sources)
                answer.model = model
                yield(.answer(answer))
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
                    forceAnswer = true
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
            // Failed calls don't count as searches, so the turns are capped too.
            if turn >= Prompt.maxSearches { forceAnswer = true }
        }
    }

    /// The open file's best sections first (about a third of the budget), then the vault's,
    /// numbered on from them. Returns the vault retriever for the model's own searches.
    func gather(_ question: String, history: [ConversationTurn], source: PassageSource, context: AskContext, budget: Int) throws -> (passages: [Passage], retriever: Retriever) {
        let query = Self.retrievalQuestion(question, history: history)
        var out: [Passage] = []
        if let open = context.openFile, !(source is SelectedFileSource) {
            // "Summarize this", "what does it say?": nothing to search the vault for.
            let aboutOpen = QueryPlan.terms(question).count <= 1 && !Set(QueryPlan.words(question)).isDisjoint(with: Self.followUpWords)
            let local = Retriever(source: SelectedFileSource(base: source, file: open))
            local.sectionLimit = aboutOpen ? 20 : 6
            out = (try? local.retrieve(query, budgetTokens: aboutOpen ? budget : budget / 3)) ?? []
            if aboutOpen, !out.isEmpty { return (out, Retriever(source: source, firstID: (out.map(\.id).max() ?? 0) + 1)) }
        }
        let retriever = Retriever(source: source, firstID: (out.map(\.id).max() ?? 0) + 1)
        retriever.skip(out)
        let used = out.map(Retriever.tokens).reduce(0, +)
        out += try retriever.retrieve(query, budgetTokens: max(1000, budget - used))
        return (out, retriever)
    }

    /// A follow-up ("and the deck?", "why?") borrows the last question's words; a question
    /// that stands on its own doesn't, so a change of subject isn't searched for the old one.
    static func retrievalQuestion(_ question: String, history: [ConversationTurn]) -> String {
        guard let last = history.last else { return question }
        let words = Set(QueryPlan.words(question))
        let followUp = QueryPlan.terms(question).count <= 2 || !words.isDisjoint(with: followUpWords)
        return followUp ? String(last.question.prefix(250)) + " " + question : question
    }

    static let followUpWords: Set<String> = ["it", "its", "that", "this", "those", "these", "they", "them", "there", "he", "she", "one", "ones", "same", "also", "else"]

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
                // The API rejects empty text blocks; one can be left open by a mid-stream decline.
                guard let text = block["text"]?.string,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return ["type": "text", "text": .string(text)]
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

/// Set once, read from another task.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.withLock { _value } }
    func set() { lock.withLock { _value = true } }
}

/// `[3]`, `[2][5]` and `[2, 5]` in answer text.
enum CitationParser {
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<!\[)\[\s*(\d{1,4}(?:\s*,\s*\d{1,4})*)\s*\](?![\(\]])"#)

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
