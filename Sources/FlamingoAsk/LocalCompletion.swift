import Foundation

// Thoughts never leave this Mac.
//
// Everything that reads a thought (understanding, `@ai` replies, the night shift and its memos,
// the briefing) goes through this file, and this file can only reach a model on this Mac:
// the local llama-server and Ollama, both on loopback. There is no provider setting, no API
// key, no Claude, and no fallback to anything remote. `LocalEndpoint` cannot be constructed
// for a host that is not loopback, and every thought path takes a `LocalEndpoint`, so reaching
// elsewhere is a compile error, not a policy. With no local model the job waits or fails
// quietly; it never escalates.

/// Why a model is being asked, which decides who answers.
public enum CompletionPurpose: String, Sendable, CaseIterable {
    /// Reading a thought just saved: a small Ollama model, or the 27B if it is already loaded.
    case understanding
    /// A person is waiting (`@ai`, "Work on this now"): the 27B, started on demand, else Ollama.
    case interactive
    /// Overnight work: the 27B, loaded for the night, else Ollama with a smaller budget.
    case nightShift

    /// The name used in fake-model fixtures: `fixtures/fake-llm/<name>-<label>.json`.
    var fixtureName: String { self == .nightShift ? "night-shift" : rawValue }
}

/// A model server on this Mac. The only way to name where a thought may be sent.
public struct LocalEndpoint: Sendable, Equatable {
    public enum Kind: String, Sendable { case llama, ollama, scripted }

    /// The OpenAI-compatible base (`http://127.0.0.1:8081/v1`); for Ollama, `…:11434/v1`.
    public let baseURL: URL
    public let model: String
    public let kind: Kind

    /// Nil unless `baseURL` is `http(s)` on `127.0.0.1`, `localhost` or `::1`.
    public init?(baseURL: URL, model: String, kind: Kind) {
        guard Self.isLoopback(baseURL) else { return nil }
        self.baseURL = baseURL; self.model = model; self.kind = kind
    }

    /// Ollama on its usual port.
    public static func ollama(model: String) -> LocalEndpoint {
        LocalEndpoint(baseURL: URL(string: "http://127.0.0.1:11434/v1")!, model: model, kind: .ollama)!
    }

    /// The test double that `FLAMINGO_FAKE_LLM=1` stands in with. Never talks to anything.
    static let scripted = LocalEndpoint(baseURL: URL(string: "http://127.0.0.1:0/v1")!, model: "fake-llm", kind: .scripted)!

    public static func isLoopback(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased() else { return false }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }

    /// The server root: Ollama's native API lives beside `/v1`.
    var root: URL { baseURL.deletingLastPathComponent() }

    /// How much retrieved text a prompt for this model can carry, in the index's token estimate.
    public var passageBudget: Int {
        switch kind {
        case .llama: return 8_000
        case .ollama: return 3_500
        case .scripted: return 8_000
        }
    }

    /// The name a memo records.
    public var displayName: String { kind == .llama ? LlamaServer.shared.displayName : model }

    /// `llama` or `ollama` (or `scripted`), for a memo's `provider`.
    public var provider: String { kind.rawValue }

    var chat: ChatEndpoint { ChatEndpoint(baseURL: baseURL, model: model, kind: kind == .llama ? .llama : .ollama) }
}

public struct LocalCompletionRequest: Sendable {
    public var system: String
    public var user: String
    /// JSON Schema text. When set the reply is a JSON object matching it.
    public var schema: String?
    public var maxTokens = 1200
    public var temperature = 0.2
    public var purpose: CompletionPurpose
    /// Names the request: the fake fixture (`<purpose>-<label>.json`) and the log line.
    public var label: String

    public init(system: String, user: String, schema: String? = nil, maxTokens: Int = 1200, temperature: Double = 0.2,
                purpose: CompletionPurpose, label: String) {
        self.system = system; self.user = user; self.schema = schema; self.maxTokens = maxTokens
        self.temperature = temperature; self.purpose = purpose; self.label = label
    }
}

public struct LocalCompletion: Sendable, Equatable {
    public var text: String
    /// The JSON object found in `text`, when there is one.
    public var json: Data?
    public var model: String
    public var provider: String
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int { (inputTokens ?? 0) + (outputTokens ?? 0) }
}

/// Where the local servers are and how to reach them. Tests replace the pieces.
package struct LocalCompletionRuntime: Sendable {
    package init() {}
    package var session: URLSession = .shared
    /// The 27B, started if need be. `background` is the night shift.
    package var llama: @Sendable (_ background: Bool, _ onLoading: @escaping @Sendable () -> Void) async throws -> URL = {
        try await LlamaServer.shared.endpoint(background: $0, onLoading: $1)
    }
    /// The 27B only if it is already serving.
    package var runningLlama: @Sendable () async -> URL? = { await LlamaServer.shared.runningEndpoint() }
    /// Whether Ollama answers on loopback; asked before the understanding pass picks it.
    package var ollamaIsUp: @Sendable (URLSession) async -> Bool = { session in
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/version")!)
        request.timeoutInterval = 2
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
    package var understandingModel: @Sendable () -> String = {
        UserDefaults.standard.string(forKey: "FlamingoThoughtModel") ?? "gemma3:4b"
    }
    package var ollamaModel: @Sendable () -> String = { AskProvider.ollamaModel }
    package var environment: @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _current = LocalCompletionRuntime()
    package static var current: LocalCompletionRuntime {
        get { lock.withLock { _current } }
        set { lock.withLock { _current = newValue } }
    }

    package var fakeModel: Bool { environment()["FLAMINGO_FAKE_LLM"] == "1" }
}

// MARK: Choosing and calling a model

/// Who answers a request of this purpose, on this Mac. Throws `AskError.unavailable` when no
/// local model can; the caller waits or gives up, and nothing else is tried.
public func localEndpoint(for purpose: CompletionPurpose, onStatus: @escaping @Sendable (String) -> Void = { _ in }) async throws -> LocalEndpoint {
    try await LocalCompletionRuntime.current.endpoint(for: purpose, onStatus: onStatus)
}

/// Asks a model on this Mac. Picks one by `request.purpose` unless `endpoint` is given.
/// Streams the text to `onText` when the model streams.
public func completeLocally(_ request: LocalCompletionRequest, using endpoint: LocalEndpoint? = nil,
                            onStatus: @escaping @Sendable (String) -> Void = { _ in },
                            onText: @escaping @Sendable (String) -> Void = { _ in }) async throws -> LocalCompletion {
    let runtime = LocalCompletionRuntime.current
    let target: LocalEndpoint
    if let endpoint { target = endpoint } else { target = try await runtime.endpoint(for: request.purpose, onStatus: onStatus) }
    try Task.checkCancellation()
    return try await runtime.complete(request, at: target, onText: onText)
}

extension LocalCompletionRuntime {
    func endpoint(for purpose: CompletionPurpose, onStatus: @escaping @Sendable (String) -> Void) async throws -> LocalEndpoint {
        if fakeModel { return .scripted }
        func ollama(_ model: String) -> LocalEndpoint { .ollama(model: model) }
        func llamaEndpoint(background: Bool) async throws -> LocalEndpoint {
            let name = LlamaServer.shared.displayName
            let url = try await llama(background) { onStatus("loading \(name)") }
            guard let endpoint = LocalEndpoint(baseURL: url, model: LlamaServer.shared.modelAlias, kind: .llama) else {
                throw AskError.unavailable("The local model isn't on this Mac")
            }
            return endpoint
        }
        switch purpose {
        case .understanding:
            if await ollamaIsUp(session) { return ollama(understandingModel()) }
            if let url = await runningLlama(), let e = LocalEndpoint(baseURL: url, model: LlamaServer.shared.modelAlias, kind: .llama) { return e }
            throw AskError.unavailable("No local model is running")
        case .interactive, .nightShift:
            do { return try await llamaEndpoint(background: purpose == .nightShift) }
            catch AskError.unavailable(_) {
                guard await ollamaIsUp(session) else { throw AskError.unavailable("No local model is running") }
                return ollama(ollamaModel())
            }
        }
    }

    func complete(_ request: LocalCompletionRequest, at endpoint: LocalEndpoint,
                  onText: @escaping @Sendable (String) -> Void) async throws -> LocalCompletion {
        switch endpoint.kind {
        case .scripted: return try scripted(request, onText: onText)
        case .ollama: return try await ollamaChat(request, at: endpoint)
        case .llama: return try await llamaChat(request, at: endpoint, onText: onText)
        }
    }

    // MARK: llama-server

    private func llamaChat(_ r: LocalCompletionRequest, at endpoint: LocalEndpoint,
                           onText: @escaping @Sendable (String) -> Void) async throws -> LocalCompletion {
        func body(withSchema: Bool) -> JSON {
            var body: JSON = [
                "model": .string(endpoint.model), "stream": true, "max_tokens": .int(r.maxTokens), "temperature": .double(r.temperature),
                "stream_options": ["include_usage": true],
                "chat_template_kwargs": ["enable_thinking": false],
                "messages": [["role": "system", "content": .string(r.system)], ["role": "user", "content": .string(r.user)]],
            ]
            if withSchema, let schema = r.schema, let parsed = try? JSON.decode(Data(schema.utf8)) {
                body["response_format"] = ["type": "json_schema", "json_schema": ["name": "result", "strict": true, "schema": parsed]]
            }
            return body
        }
        let client = ChatClient(session: session, timeout: 600)
        let out: (text: String, usage: ChatClient.Usage?)
        do {
            out = try await client.sendDetailed(body(withSchema: true), to: endpoint.chat, onText: onText)
        } catch AskError.api(let status, _) where r.schema != nil && (status == 400 || status == 422) {
            // An older server that doesn't take a schema: the prompt still says what to return.
            out = try await client.sendDetailed(body(withSchema: false), to: endpoint.chat, onText: onText)
        }
        return Self.completion(text: out.text, endpoint: endpoint, request: r, input: out.usage?.input, output: out.usage?.output)
    }

    // MARK: Ollama

    private func ollamaChat(_ r: LocalCompletionRequest, at endpoint: LocalEndpoint) async throws -> LocalCompletion {
        var body: [String: Any] = [
            "model": endpoint.model, "stream": false, "keep_alive": r.purpose == .nightShift ? "2m" : "5m",
            "options": ["temperature": r.temperature, "num_ctx": r.purpose == .understanding ? 4096 : 8192, "num_predict": r.maxTokens],
            "messages": [["role": "system", "content": r.system], ["role": "user", "content": r.user]],
        ]
        if let schema = r.schema, let parsed = try? JSONSerialization.jsonObject(with: Data(schema.utf8)) { body["format"] = parsed }
        var request = URLRequest(url: endpoint.root.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = r.purpose == .understanding ? 90 : 600
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw AskError.unavailable("Ollama isn't running")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard status == 200 else {
            if status == 404 { throw AskError.unavailable("\(endpoint.model) isn't pulled in Ollama") }
            let message = (json?["error"] as? String)?.split(separator: "\n").first.map(String.init) ?? ""
            throw AskError.api(status: status, message: message)
        }
        guard let content = (json?["message"] as? [String: Any])?["content"] as? String else { throw AskError.stream("No answer") }
        return Self.completion(text: content, endpoint: endpoint, request: r,
                               input: json?["prompt_eval_count"] as? Int, output: json?["eval_count"] as? Int)
    }

    // MARK: Fixtures

    /// `FLAMINGO_FAKE_LLM=1`: the canned reply in `fixtures/fake-llm/<purpose>-<label>.json`, so
    /// screenshots and QA are deterministic without loading a model. A recipe run by hand
    /// (`interactive`) falls back to the night-shift fixture of the same recipe.
    ///
    /// A fixture can point at a passage it was not told the number of: `"@finance/q3-model.xlsx"`
    /// (or `"@decks/q3.pptx#slide 7"`) becomes the number of that passage in the prompt, and
    /// `[@ref]` inside a string becomes `[n]`.
    private func scripted(_ r: LocalCompletionRequest, onText: @escaping @Sendable (String) -> Void) throws -> LocalCompletion {
        guard let dir = Self.fixtureDirectory(environment()) else { throw AskError.unavailable("No fake model replies found") }
        let names = ["\(r.purpose.fixtureName)-\(r.label).json"] + (r.purpose == .interactive ? ["night-shift-\(r.label).json"] : [])
        guard let data = names.lazy.compactMap({ try? Data(contentsOf: dir.appendingPathComponent($0)) }).first else {
            throw AskError.unavailable("No fake model reply for \(names[0])")
        }
        let text = Self.resolvePassageReferences(in: String(decoding: data, as: UTF8.self), prompt: r.user)
        onText(text)
        return Self.completion(text: text, endpoint: .scripted, request: r, input: 0, output: 0)
    }

    package static func resolvePassageReferences(in fixture: String, prompt: String) -> String {
        guard fixture.contains("@"), let tag = try? NSRegularExpression(pattern: #"<passage id="(\d+)" kind="\w+" file="([^"]*)"(?: at="([^"]*)")?"#) else { return fixture }
        let ns = prompt as NSString
        var exact: [String: Int] = [:], byFile: [String: Int] = [:]
        for m in tag.matches(in: prompt, range: NSRange(location: 0, length: ns.length)) {
            guard let id = Int(ns.substring(with: m.range(at: 1))) else { continue }
            let file = ns.substring(with: m.range(at: 2)).replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
            let at = m.range(at: 3).location == NSNotFound ? nil : ns.substring(with: m.range(at: 3))
            if let at { exact[file + "#" + at] = exact[file + "#" + at] ?? id }
            byFile[file] = byFile[file] ?? id
        }
        func number(_ ref: String) -> Int { exact[ref] ?? byFile[ref] ?? 0 }
        var out = fixture
        for (pattern, template) in [(#""@([^"]+)""#, "$"), (#"\[@([^\]]+)\]"#, "[$]")] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let current = out as NSString
            var result = "", cursor = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: current.length)) {
                result += current.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                result += template.replacingOccurrences(of: "$", with: String(number(current.substring(with: m.range(at: 1)))))
                cursor = m.range.location + m.range.length
            }
            out = result + current.substring(from: cursor)
        }
        return out
    }

    static func fixtureDirectory(_ environment: [String: String]) -> URL? {
        let fm = FileManager.default
        if let dir = environment["FLAMINGO_FAKE_LLM_DIR"] { return URL(fileURLWithPath: dir) }
        var starts = [fm.currentDirectoryPath, Bundle.main.bundlePath]
        if let pwd = environment["PWD"] { starts.append(pwd) }
        for start in starts {
            var url = URL(fileURLWithPath: start)
            for _ in 0..<8 {
                let candidate = url.appendingPathComponent("fixtures/fake-llm")
                if fm.fileExists(atPath: candidate.path) { return candidate }
                url.deleteLastPathComponent()
            }
        }
        return nil
    }

    // MARK: Results

    static func completion(text: String, endpoint: LocalEndpoint, request: LocalCompletionRequest, input: Int?, output: Int?) -> LocalCompletion {
        LocalCompletion(text: text, json: LocalJSON.object(in: text), model: endpoint.kind == .scripted ? "fake-llm" : endpoint.displayName,
                        provider: endpoint.provider,
                        inputTokens: input ?? (request.system.utf8.count + request.user.utf8.count + 3) / 4,
                        outputTokens: output ?? (text.utf8.count + 3) / 4)
    }
}

enum LocalJSON {
    /// The JSON object in a model's reply, tolerating a code fence or a sentence around it.
    static func object(in text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else { return nil }
        let data = Data(text[start...end].utf8)
        guard (try? JSON.decode(data))?.object != nil else { return nil }
        return data
    }

    static func parse(_ completion: LocalCompletion) -> JSON? {
        completion.json.flatMap { try? JSON.decode($0) }
    }
}
