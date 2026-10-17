import XCTest
import FlamingoCore
import FlamingoIndex
@testable import FlamingoAsk

/// A stand-in for the network that serves loopback and refuses everything else, recording both.
/// Thoughts never leave this Mac: a test that reaches a host that is not loopback has failed.
final class LoopbackStub: URLProtocol {
    struct Reply { var status = 200; var body: Data }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _requests: [(url: URL, body: Data)] = []
    nonisolated(unsafe) private static var _handler: (@Sendable (URL, Data) -> Reply?)?

    /// Every request that reached the stub, loopback or not.
    static var requests: [(url: URL, body: Data)] { lock.withLock { _requests } }
    /// Requests to a host that is not 127.0.0.1, localhost or ::1.
    static var violations: [URL] { requests.map(\.url).filter { !LocalEndpoint.isLoopback($0) } }

    /// `handler` answers loopback requests; nil refuses the connection (nothing is listening).
    static func reset(_ handler: (@Sendable (URL, Data) -> Reply?)?) {
        lock.withLock { _requests = []; _handler = handler }
    }

    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LoopbackStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let body = request.httpBody ?? request.httpBodyStream.map(Self.readAll) ?? Data()
        let handler: (@Sendable (URL, Data) -> Reply?)? = Self.lock.withLock {
            Self._requests.append((url, body))
            return Self._handler
        }
        guard LocalEndpoint.isLoopback(url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        guard let handler, let reply = handler(url, body) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["content-type": reply.status == 200 ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    // MARK: Canned replies

    /// An OpenAI-style streamed reply carrying `text`.
    static func chat(_ text: String) -> Reply { Reply(body: LocalModelTests.chat([text]).body) }

    /// Ollama's `/api/chat` reply.
    static func ollama(_ content: String) -> Reply {
        let json: [String: Any] = ["message": ["role": "assistant", "content": content], "prompt_eval_count": 120, "eval_count": 40]
        return Reply(body: try! JSONSerialization.data(withJSONObject: json))
    }

    static func version() -> Reply { Reply(body: Data(#"{"version":"0.12.0"}"#.utf8)) }
}

/// Points the local models at the stub for the length of a test and puts everything back.
class LocalModelTestCase: XCTestCase {
    private var saved: LocalCompletionRuntime!

    override func setUp() {
        super.setUp()
        saved = LocalCompletionRuntime.current
        var runtime = LocalCompletionRuntime()
        runtime.session = LoopbackStub.session
        runtime.llama = { _, _ in URL(string: "http://127.0.0.1:8081/v1")! }
        runtime.environment = { [:] }
        LocalCompletionRuntime.current = runtime
        LoopbackStub.reset(nil)
    }

    override func tearDown() {
        LocalCompletionRuntime.current = saved
        LoopbackStub.reset(nil)
        super.tearDown()
    }

    func use(_ change: (inout LocalCompletionRuntime) -> Void) {
        var runtime = LocalCompletionRuntime.current
        change(&runtime)
        LocalCompletionRuntime.current = runtime
    }
}

/// A copy of `fixtures/vault` with an index, a sidecar store and an engine over it.
final class ThoughtVault {
    let root: URL
    let vault: Vault
    let index: IndexStore
    let store: SidecarStore
    let engine: AskEngine

    init() throws {
        let fixture = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/vault").resolvingSymlinksInPath()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("thought-vault-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixture, to: root)
        for name in ["index.sqlite", "index.sqlite-wal", "index.sqlite-shm", "graph.json"] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(".flamingo/\(name)"))
        }
        // A fresh trail: the fixture's would be read by tests that don't care about it.
        vault = Vault(root: root)
        index = try IndexStore(vault: vault)
        try index.reindex()
        store = SidecarStore(vault: vault)
        engine = AskEngine(index: index, source: IndexSource(index: index), client: MockAPI.client, key: { nil })
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    static let deck = FileRef(relativePath: "decks/q3-board-review.pptx")
    static let model = FileRef(relativePath: "finance/q3-model.xlsx")

    /// Adds a thought on `file` and returns it as stored, with its uid.
    @discardableResult
    func think(_ text: String, on file: FileRef = ThoughtVault.deck, anchor: FileAnchor? = FileAnchor(kind: .slide, value: "7"),
               at date: Date = Date(timeIntervalSince1970: 1_792_000_000), meta: ThoughtMeta? = nil) throws -> Comment {
        try store.append(Comment(timestamp: date, anchor: anchor, text: text, meta: meta).stamped(), to: file)
        let all = try store.comments(for: file)
        return try XCTUnwrap(all.last { $0.text == text })
    }

    func reload() throws { try index.reindex() }
}
