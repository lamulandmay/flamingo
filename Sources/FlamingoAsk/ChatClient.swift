import Foundation

/// `POST {baseURL}/chat/completions` with `stream: true`: llama-server and Ollama both speak it.
/// One answer per call, no tools; local models answer from the passages they're given.
struct ChatClient: Sendable {
    var session: URLSession = .shared
    /// Local generation can sit in prompt processing a while before the first token.
    var timeout: TimeInterval = 600

    /// Streams the answer text and returns it whole. Reasoning deltas are dropped.
    func send(_ body: JSON, to endpoint: ChatEndpoint, onText: @escaping @Sendable (String) -> Void) async throws -> String {
        try await sendDetailed(body, to: endpoint, onText: onText).text
    }

    struct Usage: Sendable, Equatable { var input: Int?; var output: Int? }

    /// Like `send`, and also the token counts the server reported (when it reports them).
    /// An answer the length limit cut off throws: structured output that stops early is no use.
    func sendDetailed(_ body: JSON, to endpoint: ChatEndpoint, onText: @escaping @Sendable (String) -> Void) async throws -> (text: String, usage: Usage?) {
        let reply = try await stream(body, to: endpoint, onText: onText)
        if reply.truncated { throw AskError.stream("Answer interrupted (length). Retry or narrow the question.") }
        return (reply.text, reply.usage)
    }

    struct Reply: Sendable, Equatable {
        var text: String
        var usage: Usage?
        /// `finish_reason` was `length`: the text so far stands, but it stops mid-answer.
        var truncated = false
    }

    /// The whole stream. A `length` finish returns what arrived, marked truncated; any other
    /// reason that isn't `stop` throws.
    func stream(_ body: JSON, to endpoint: ChatEndpoint, onText: @escaping @Sendable (String) -> Void) async throws -> Reply {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.httpBody = try body.encoded()

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw AskError.stream("No response") }
            guard http.statusCode == 200 else {
                var data = Data()
                for try await byte in bytes { data.append(byte) }
                throw Self.error(http.statusCode, body: data, endpoint: endpoint)
            }
            var text = ""
            var usage: Usage?
            var parser = SSEParser()
            var line: [UInt8] = []
            var done = false
            var truncated = false
            func handle(_ event: SSEParser.Event) throws {
                if event.data == "[DONE]" { done = true; return }
                guard let json = try? JSON.decode(Data(event.data.utf8)) else { return }
                if let message = json["error"]?["message"]?.string ?? json["error"]?.string { throw AskError.stream(message) }
                if let u = json["usage"], u.object != nil {
                    usage = Usage(input: u["prompt_tokens"]?.int, output: u["completion_tokens"]?.int)
                }
                guard let choice = json["choices"]?.array?.first else { return }
                if let t = choice["delta"]?["content"]?.string, !t.isEmpty {
                    text += t
                    onText(t)
                }
                if let reason = choice["finish_reason"]?.string, !reason.isEmpty {
                    if reason == "length" { truncated = true }
                    else if reason != "stop" { throw AskError.stream("Answer interrupted (\(reason)). Retry or narrow the question.") }
                    done = true
                }
            }
            for try await byte in bytes {
                if byte == 0x0A {
                    if line.last == 0x0D { line.removeLast() }
                    if let event = parser.feed(String(decoding: line, as: UTF8.self)) { try handle(event) }
                    line.removeAll(keepingCapacity: true)
                } else {
                    line.append(byte)
                }
            }
            if !line.isEmpty, let event = parser.feed(String(decoding: line, as: UTF8.self)) { try handle(event) }
            if let event = parser.flush() { try handle(event) }
            guard done else { throw AskError.stream("Answer interrupted before completion. Retry to finish it.") }
            return Reply(text: text, usage: usage, truncated: truncated)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw AskError.unavailable(Self.name(endpoint))
        }
    }

    static func error(_ status: Int, body: Data, endpoint: ChatEndpoint) -> AskError {
        let json = try? JSON.decode(body)
        let message = json?["error"]?["message"]?.string ?? json?["error"]?.string ?? ""
        return .api(status: status, message: message.split(separator: "\n").first.map(String.init) ?? "")
    }

    static func name(_ endpoint: ChatEndpoint) -> String {
        endpoint.kind == .ollama ? "Ollama isn't running" : "\(endpoint.model) isn't running"
    }
}
