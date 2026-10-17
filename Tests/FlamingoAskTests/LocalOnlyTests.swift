import XCTest
import FlamingoCore
import FlamingoIndex
@testable import FlamingoAsk

/// Thoughts never leave this Mac. Every path that reads a thought is run through a network that
/// refuses anything but loopback, and Chat with a remote provider is checked for thought text.
final class LocalOnlyTests: LocalModelTestCase {
    // MARK: The type

    func testAnEndpointCanOnlyBeBuiltForThisMac() {
        func make(_ s: String) -> LocalEndpoint? { URL(string: s).flatMap { LocalEndpoint(baseURL: $0, model: "m", kind: .llama) } }
        XCTAssertNotNil(make("http://127.0.0.1:8081/v1"))
        XCTAssertNotNil(make("http://localhost:11434/v1"))
        XCTAssertNotNil(make("http://[::1]:8080/v1"))
        XCTAssertNotNil(make("https://127.0.0.1/v1"))
        for remote in ["https://api.anthropic.com/v1", "http://10.0.0.5:8080/v1", "http://192.168.1.2/v1", "http://0.0.0.0:8080/v1",
                       "http://127.0.0.1.evil.example/v1", "http://localhost.evil.example/v1", "http://user@127.0.0.1/v1",
                       "file:///tmp/x", "ftp://127.0.0.1/", "http://example.com/127.0.0.1"] {
            XCTAssertNil(make(remote), remote)
        }
    }

    // MARK: Every thought path, through the stub

    func testUnderstandingReachesOnlyLoopback() async throws {
        let v = try ThoughtVault()
        let thought = try v.think("review conflict between this and [[q3-model.xlsx]] before friday")
        LoopbackStub.reset { url, _ in
            url.path == "/api/version" ? LoopbackStub.version()
                : url.path == "/api/chat" ? LoopbackStub.ollama(#"{"kind":"intent","action":"review-conflict","objects":["finance/q3-model.xlsx"],"confidence":0.9}"#) : nil
        }
        let outcome = await ThoughtReader(engine: v.engine, store: v.store).read(uid: try XCTUnwrap(thought.uid), on: ThoughtVault.deck)
        guard case .saved = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(LoopbackStub.requests.isEmpty)
        XCTAssertEqual(LoopbackStub.violations, [])
    }

    func testAskingAboutAThoughtReachesOnlyLoopbackEvenWhenChatIsSetToClaude() async throws {
        let v = try ThoughtVault()
        v.engine.providerChoice = { .claude }
        v.engine.keyProvider = { "sk-test" }
        v.engine.llama = { _ in URL(string: "http://127.0.0.1:8081/v1")! }
        LoopbackStub.reset { url, _ in url.path.hasSuffix("/chat/completions") ? LoopbackStub.chat("The model uses $229 [1].") : nil }
        var answer: Answer?
        for try await d in v.engine.askStreamingLocally("what price does the model use?", files: [ThoughtVault.model, ThoughtVault.deck]) {
            if case .answer(let a) = d { answer = a }
        }
        XCTAssertEqual(answer?.text, "The model uses $229 [1].")
        XCTAssertEqual(LoopbackStub.violations, [])
        XCTAssertFalse(LoopbackStub.requests.contains { $0.url.host?.contains("anthropic") ?? false })
        // Only the files it was pointed at were searched.
        let body = String(decoding: try XCTUnwrap(LoopbackStub.requests.last?.body), as: UTF8.self)
        XCTAssertFalse(body.contains("whiteboard-pricing"))
    }

    func testAWorkRecipeReachesOnlyLoopback() async throws {
        let v = try ThoughtVault()
        let thought = try v.think("review conflict between this and [[q3-model.xlsx]]")
        LoopbackStub.reset { url, body in
            guard url.path.hasSuffix("/chat/completions") else { return nil }
            let prompt = String(decoding: body, as: UTF8.self)
            let fixture = try! String(contentsOf: WorkRecipeTests.fixture("night-shift-review-conflict"), encoding: .utf8)
            return LoopbackStub.chat(LocalCompletionRuntime.resolvePassageReferences(in: fixture, prompt: Self.userText(body) ?? prompt))
        }
        let request = WorkRequest(recipe: .reviewConflict, thoughtUID: try XCTUnwrap(thought.uid), thoughtText: thought.text,
                                  thoughtTimestamp: thought.timestamp, file: ThoughtVault.deck, anchor: thought.anchor,
                                  objects: ["decks/q3-board-review.pptx#slide 7", "finance/q3-model.xlsx"])
        let result = try await v.engine.work(request) { _ in }
        XCTAssertEqual(result.memo.verdict, "conflict")
        XCTAssertFalse(LoopbackStub.requests.isEmpty)
        XCTAssertEqual(LoopbackStub.violations, [])
    }

    func testWithNoLocalModelTheJobFailsQuietlyAndNothingIsTriedElsewhere() async throws {
        let v = try ThoughtVault()
        v.engine.keyProvider = { "sk-test" }
        use { $0.llama = { _, _ in throw AskError.unavailable("llama-server isn't installed") } }
        LoopbackStub.reset(nil) // nothing listens, not even Ollama
        for purpose in CompletionPurpose.allCases {
            do {
                _ = try await completeLocally(LocalCompletionRequest(system: "s", user: "a private thought", purpose: purpose, label: "x"))
                XCTFail("\(purpose) should not be answered")
            } catch { XCTAssertTrue(error is AskError, "\(purpose): \(error)") }
        }
        XCTAssertEqual(LoopbackStub.violations, [])
        XCTAssertFalse(LoopbackStub.requests.contains { !LocalEndpoint.isLoopback($0.url) })
        XCTAssertTrue(LoopbackStub.requests.allSatisfy { $0.url.host == "127.0.0.1" })
    }

    func testTheFakeModelNeverTouchesTheNetwork() async throws {
        use { $0.environment = { ["FLAMINGO_FAKE_LLM": "1"] } }
        LoopbackStub.reset(nil)
        let done = try await completeLocally(LocalCompletionRequest(system: "s", user: "u", purpose: .understanding, label: "understand"))
        XCTAssertEqual(done.model, "fake-llm")
        XCTAssertEqual(LocalJSON.parse(done)?["action"]?.string, "review-conflict")
        XCTAssertTrue(LoopbackStub.requests.isEmpty)
    }

    static func userText(_ body: Data) -> String? {
        guard let json = try? JSON.decode(body), let messages = json["messages"]?.array else { return nil }
        return messages.last?["content"]?.string
    }

    // MARK: Chat with a remote provider carries no thought

    struct LeakySource: PassageSource {
        var base = Fixture.vault
        /// A semantic hit on a thought, as the index returns it among the sections.
        var semantic: SearchHit
        var vault: Vault { base.vault }
        func searchSections(_ query: String, limit: Int) throws -> [SearchHit] { [semantic] + (try base.searchSections(query, limit: limit)) }
        func searchComments(_ query: String, limit: Int) throws -> [CommentHit] { try base.searchComments(query, limit: limit) }
        func sections(of ref: FileRef) throws -> [SourceSection] { try base.sections(of: ref) }
        func text(of ref: FileRef) throws -> String? { try base.text(of: ref) }
        func comments(on ref: FileRef) throws -> [Comment] { try base.comments(on: ref) }
        func files() -> [FileRef] { base.files() }
    }

    func testChatWithARemoteProviderSendsNoThoughtText() async throws {
        let secret = "Decided: keep $49, drop the annual discount."
        let hit = SearchHit(file: Fixture.deck, anchor: Fixture.decision.anchor, snippet: secret, score: 1, commentID: Fixture.decision.id)
        MockAPI.reset([SSE.reply(SSE.message(text: ["Pricing is $49 [1]."]))])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let engine = AskEngine(index: try IndexStore(vault: Vault(root: dir)), source: LeakySource(semantic: hit),
                               client: MockAPI.client, key: { "sk-test" })
        let history = [
            ConversationTurn(question: "what did I decide about pricing", answer: "You decided to keep $49 and drop the annual discount."),
            ConversationTurn(question: "what else", answer: "Nothing in the file says.", thoughtDerived: true),
            ConversationTurn(question: "what is in the notes", answer: "Standup: shipped onboarding."),
        ]
        for try await _ in engine.askStreaming("what did I decide about pricing", history: history) {}

        let sent = String(decoding: try XCTUnwrap(MockAPI.requests.first).body.encoded(), as: UTF8.self)
        XCTAssertTrue(sent.contains("Pricing: $49 per seat"), "files are still read")
        XCTAssertFalse(sent.contains("Decided: keep $49"), "the thought's words")
        XCTAssertFalse(sent.contains("Needs a better title"), "another thought on the file")
        XCTAssertFalse(sent.contains("kind=\\\"comment\\\""), "no thought passage")
        XCTAssertFalse(sent.contains("drop the annual discount"), "a turn that quoted the thought")
        XCTAssertFalse(sent.contains("Nothing in the file says"), "a turn drawn from thoughts")
        XCTAssertTrue(sent.contains("shipped onboarding"), "an unrelated turn stays")
        XCTAssertEqual(MockAPI.requests.first?.request.url?.host, "api.anthropic.com")
    }

    func testTheSameQuestionToALocalModelStillSeesTheThought() async throws {
        let secret = "Decided: keep $49, drop the annual discount."
        MockAPI.reset([LocalModelTests.chat(["Keep $49 [1]."])])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let engine = AskEngine(index: try IndexStore(vault: Vault(root: dir)), source: Fixture.vault, client: MockAPI.client, key: { nil })
        engine.chat = ChatClient(session: MockAPI.session)
        engine.providerChoice = { .llama }
        engine.llama = { _ in LocalModelTests.llamaURL }
        for try await _ in engine.askStreaming("what did I decide about pricing") {}
        let sent = String(decoding: try XCTUnwrap(MockAPI.requests.first).body.encoded(), as: UTF8.self)
        XCTAssertTrue(sent.contains(String(secret.prefix(20))), "on this Mac the thought is read")
        XCTAssertEqual(MockAPI.requests.first?.request.url?.host, "127.0.0.1")
    }

    func testClaudeCodeAndAutoAlsoStripThoughts() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for choice in [AskProvider.claude, .auto] {
            MockAPI.reset([SSE.reply(SSE.message(text: ["ok [1]"]))])
            let engine = AskEngine(index: try IndexStore(vault: Vault(root: dir)), source: Fixture.vault, client: MockAPI.client, key: { "sk-test" })
            engine.providerChoice = { choice }
            for try await _ in engine.askStreaming("what did I decide about pricing") {}
            let sent = String(decoding: try XCTUnwrap(MockAPI.requests.first).body.encoded(), as: UTF8.self)
            XCTAssertFalse(sent.contains("Decided: keep $49"), "\(choice)")
            XCTAssertEqual(MockAPI.requests.first?.request.url?.host, "api.anthropic.com", "\(choice)")
        }
    }

    func testPassagesFromAThoughtAreFilteredWhateverMadeThem() {
        let thought = Passage(id: 1, kind: .comment, file: Fixture.deck, text: "private")
        let viaHit = Passage(id: 2, kind: .section, file: Fixture.deck, text: "snippet", commentID: UUID())
        let file = Passage(id: 3, kind: .section, file: Fixture.deck, text: "public")
        XCTAssertEqual(ThoughtPrivacy.withoutThoughts([thought, viaHit, file]).map(\.id), [3])
    }
}
