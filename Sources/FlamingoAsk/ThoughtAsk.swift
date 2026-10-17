import Foundation
import FlamingoCore
import FlamingoIndex

extension AskEngine {
    /// `@ai` / `@flamingo` on a thought: the question answered by a model on this Mac only,
    /// from `files` (the thought's target, the files it links to and the files of its thread).
    /// Never reads Ask's provider setting and never reaches Claude, so the thought may be
    /// read in full. The stream is the same as `askStreaming`'s; cancel the task to stop it.
    public func askStreamingLocally(_ question: String, history: [ConversationTurn] = [], files: [FileRef],
                                    context: AskContext = .empty) -> AsyncThrowingStream<Delta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached { [self] in
                do {
                    try await self.runThoughtQuestion(question, history: history, files: files, context: context) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The files a thought's question or work is about, in order: where it was left, the files
    /// its words link to (resolved in the vault), then the same for the thread's other thoughts.
    /// At most `limit`; files that don't exist are left out.
    public func thoughtScope(for comment: Comment, on file: FileRef, thread: [Comment] = [], limit: Int = 8) -> [FileRef] {
        var out: [FileRef] = []
        func add(_ ref: FileRef) { if !out.contains(ref), out.count < limit { out.append(ref) } }
        if !file.isVirtual { add(file) }
        for c in [comment] + thread {
            for link in c.links {
                if let ref = resolveFile(Wikilink.components(of: link).target, near: file) { add(ref) }
            }
        }
        return out
    }

    private func runThoughtQuestion(_ question: String, history: [ConversationTurn], files: [FileRef], context: AskContext,
                                    yield: @escaping @Sendable (Delta) -> Void) async throws {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        let runtime = LocalCompletionRuntime.current
        let endpoint = try await runtime.endpoint(for: .interactive) { yield(.status($0)) }
        try Task.checkCancellation()
        let scoped = MultiFileSource(base: source, files: files)
        let passages = try gather(question, history: history, source: scoped, context: context, budget: Prompt.localBudget(endpoint.chat.kind)).passages
        yield(.passages(passages))
        let sources = Dictionary(uniqueKeysWithValues: passages.map { ($0.id, $0.citation) })

        let text: String
        if endpoint.kind == .scripted {
            let request = LocalCompletionRequest(system: Prompt.localSystem, user: question, purpose: .interactive, label: "ask")
            let done = try await runtime.complete(request, at: endpoint) { _ in }
            text = LocalJSON.parse(done)?["text"]?.string ?? done.text
            yield(.text(text))
        } else {
            let body = Prompt.localBody(endpoint.chat, question: question, passages: passages, today: Date(), history: history, context: context)
            text = try await ChatClient(session: runtime.session, timeout: chat.timeout).send(body, to: endpoint.chat) { yield(.text($0)) }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AskError.stream("No answer") }
        var answer = CitationParser.answer(text: text, sources: sources)
        answer.model = endpoint.displayName
        yield(.answer(answer))
    }
}

extension Answer {
    /// The text with each `[n]` replaced by a wikilink to what it cites, `[[path#slide 7]]`,
    /// so a note that holds the answer links to its sources (and Obsidian sees them). A number
    /// that doesn't name a source is left as written.
    public func wikified() -> String {
        guard !sources.isEmpty else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        var previous: [String] = []
        for m in CitationParser.matches(in: text) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let numbers = ns.substring(with: m.range(at: 1)).split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            var links: [String] = []
            var unresolved: [Int] = []
            for n in numbers {
                if let c = sources[n] {
                    let link = Self.wikilink(c)
                    if !links.contains(link) { links.append(link) }
                } else { unresolved.append(n) }
            }
            if links.isEmpty { out += ns.substring(with: m.range) }
            else if m.range.location == cursor, !previous.isEmpty, links.allSatisfy(previous.contains), unresolved.isEmpty {
                // `[2][3]` on one place is one link.
            } else {
                out += links.joined(separator: " ")
                if !unresolved.isEmpty { out += " " + unresolved.map { "[\($0)]" }.joined() }
            }
            previous = links
            cursor = m.range.location + m.range.length
        }
        return out + ns.substring(from: cursor)
    }

    static func wikilink(_ citation: Citation) -> String {
        func clean(_ s: String) -> String { s.replacingOccurrences(of: "]]", with: "]").replacingOccurrences(of: "|", with: "/") }
        let anchor = citation.anchor.map { "#" + clean($0.label) } ?? ""
        return "[[" + clean(citation.file.relativePath) + anchor + "]]"
    }
}
