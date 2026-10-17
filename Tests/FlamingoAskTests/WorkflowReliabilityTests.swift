import XCTest
import FlamingoCore
import FlamingoIndex
@testable import FlamingoAsk

final class WorkflowReliabilityTests: XCTestCase {
    func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-workflow-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testTruncatedStreamAndLengthStopAreFailures() async throws {
        let chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"Partial answer\"}}]}\n\n"
        for suffix in ["", "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\ndata: [DONE]\n\n"] {
            MockAPI.reset([.init(status: 200, body: Data((chunk + suffix).utf8))])
            do {
                _ = try await ChatClient(session: MockAPI.session).send([:], to: .init(baseURL: LocalModelTests.llamaURL, model: "test", kind: .llama)) { _ in }
                XCTFail("A partial response must not appear complete")
            } catch { XCTAssertTrue(error.localizedDescription.contains("interrupted")) }
        }
    }

    func testSelectedFileScopeCannotFollowLinksIntoOtherFiles() throws {
        let scoped = SelectedFileSource(base: Fixture.vault, file: Fixture.deck)
        let passages = try Retriever(source: scoped).retrieve("pricing")
        XCTAssertFalse(passages.isEmpty)
        XCTAssertTrue(passages.allSatisfy { $0.file == Fixture.deck })
        XCTAssertTrue(try scoped.sections(of: Fixture.sheet).isEmpty)
        XCTAssertNil(try scoped.text(of: Fixture.notes))
    }

    func testScopedAskAndConversationUseOnlyCurrentEvidenceNumbers() async throws {
        let index = try IndexStore(vault: Vault(root: directory()))
        let engine = AskEngine(index: index, source: Fixture.vault, client: MockAPI.client, key: { nil })
        engine.providerChoice = { .llama }; engine.llama = { _ in LocalModelTests.llamaURL }
        engine.chat = ChatClient(session: MockAPI.session)
        MockAPI.reset([LocalModelTests.chat(["Pricing [1]."])])
        let prior = [ConversationTurn(question: "What pricing decision?", answer: "Keep $49 [99].")]
        for try await delta in engine.askStreaming("Why?", history: prior, file: Fixture.deck) {
            if case .passages(let passages) = delta { XCTAssertTrue(passages.allSatisfy { $0.file == Fixture.deck }) }
        }
        let body = try XCTUnwrap(MockAPI.requests.first?.body["messages"]?.array?[1]["content"]?.string)
        XCTAssertTrue(body.contains("What pricing decision?"))
        XCTAssertFalse(body.contains("[99]"))
        XCTAssertFalse(body.contains("file=\"models/q3-model.xlsx\""))
        XCTAssertTrue(body.contains("earlier answers are not evidence"))
    }

    func testLongSectionCanReturnAnotherPassageAndPreservesRefinedLineAnchor() throws {
        let file = FileRef(relativePath: "long.md")
        let text = "Alpha decision. " + String(repeating: "unrelated filler ", count: 400) + "Beta decision with evidence. " + String(repeating: "tail ", count: 200)
        var fake = FakeSource()
        fake.sectionsByFile[file] = [.init(anchor: .init(kind: .line, value: "1"), title: nil, text: text)]
        let retriever = Retriever(source: SelectedFileSource(base: fake, file: file))
        let first = try retriever.retrieve("Alpha")
        let second = try retriever.retrieve("Beta")
        XCTAssertTrue(first.contains { $0.text.contains("Alpha decision") })
        XCTAssertTrue(second.contains { $0.text.contains("Beta decision") })
        XCTAssertFalse(second.contains { first.map(\.text).contains($0.text) })

        let source = RefinedHitSource(base: fake, hit: SearchHit(file: file, anchor: .init(kind: .line, value: "54"), snippet: "Beta decision with evidence.", score: 1))
        let found = try Retriever(source: source).retrieve("Beta")
        XCTAssertEqual(found.first?.anchor?.value, "54")
        XCTAssertTrue(found.first?.text.contains("Beta decision") == true)
        XCTAssertGreaterThan(found.first?.text.count ?? 0, 100, "must read the containing section, not only a short hit snippet")
    }

    func testAnalysisIsLocalProvenancedValidatedAndDoesNotWriteSidecar() async throws {
        let root = try directory(), file = FileRef(relativePath: "pricing.md"), other = FileRef(relativePath: "model.md")
        try "pricing content".write(to: root.appendingPathComponent(file.relativePath), atomically: true, encoding: .utf8)
        var source = FakeSource(vault: Vault(root: root))
        source.sectionsByFile[file] = [.init(anchor: .init(kind: .line, value: "1"), title: "Pricing", text: "Pricing is $49.")]
        source.sectionsByFile[other] = [.init(anchor: .init(kind: .line, value: "1"), title: "Pricing", text: "Pricing model uses $49.")]
        let index = try IndexStore(vault: source.vault)
        let engine = AskEngine(index: index, source: source, client: MockAPI.client, key: { "cloud-key-must-not-be-used" })
        engine.providerChoice = { .claude }; engine.llama = { _ in LocalModelTests.llamaURL }
        engine.chat = ChatClient(session: MockAPI.session)
        MockAPI.reset([LocalModelTests.chat([#"{"summary":"The file lists a $49 price.","connections":[{"passage":1,"reason":"not a candidate"},{"passage":2,"reason":"Both use the same price"},{"passage":999,"reason":"invented"}]}"#])])
        let result = try await engine.analyze(file: file)
        XCTAssertEqual(result.comment.provenance?.origin, .ai)
        XCTAssertEqual(result.comment.provenance?.model, LlamaServer.modelName)
        XCTAssertEqual(result.connections.map(\.citation.file), [other])
        XCTAssertTrue(result.comment.text.contains("[[model.md#line 1]]"))
        XCTAssertEqual(MockAPI.requests.first?.request.url?.host, "127.0.0.1")
        XCTAssertTrue(try SidecarStore(vault: source.vault).comments(for: file).isEmpty)
        XCTAssertEqual(result.fingerprint, try engine.analysisFingerprint(for: file))

        engine.llama = { _ in
            try "changed source size".write(to: root.appendingPathComponent(file.relativePath), atomically: true, encoding: .utf8)
            return LocalModelTests.llamaURL
        }
        MockAPI.reset([LocalModelTests.chat([#"{"summary":"Stale reading","connections":[]}"#])])
        do { _ = try await engine.analyze(file: file); XCTFail("Stale analyses must not be saved") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed during analysis")) }
    }

    func testHistoryRoundTripRetainsCitationExcerptOriginAndDraft() throws {
        let url = try directory().appendingPathComponent("history.json")
        let citation = Citation(file: Fixture.deck, anchor: .init(kind: .slide, value: "7"), excerpt: "Exact evidence", commentID: Fixture.decision.id, provenance: .init(origin: .human, appName: "Keynote"))
        var exchange = Exchange(question: "Why?")
        exchange.sources = [1: citation]; exchange.text = "Because [1]."; exchange.done = true; exchange.fileScope = Fixture.deck; exchange.saveTarget = Fixture.deck
        try AskHistoryStore.save(AskHistory(exchanges: [exchange], draft: "Follow-up"), to: url)
        let loaded = try AskHistoryStore.load(url)
        XCTAssertEqual(loaded.draft, "Follow-up")
        XCTAssertEqual(loaded.exchanges.first?.sources[1]?.excerpt, "Exact evidence")
        XCTAssertEqual(loaded.exchanges.first?.sources[1]?.provenance?.appName, "Keynote")
        XCTAssertEqual(loaded.exchanges.first?.fileScope, Fixture.deck)
        XCTAssertEqual(loaded.exchanges.first?.saveTarget, Fixture.deck)
    }

    func testSourceExpansionUsesCommentIdentityAndFullSection() throws {
        let engine = AskEngine(index: try IndexStore(vault: Vault(root: directory())), source: Fixture.vault,
                               client: MockAPI.client, key: { nil })
        let section = try engine.sourceText(for: Citation(file: Fixture.deck, anchor: .init(kind: .slide, value: "7"), excerpt: "short"))
        XCTAssertTrue(section.contains("20% off annual plans"))
        let thought = try engine.sourceText(for: Citation(file: Fixture.deck, anchor: .init(kind: .slide, value: "7"), commentID: Fixture.decision.id))
        XCTAssertEqual(thought, Fixture.decision.text)
        XCTAssertThrowsError(try engine.sourceText(for: Citation(file: Fixture.deck, commentID: UUID())))
    }
}

@MainActor
final class AskRecoveryTests: XCTestCase {
    func testRelaunchRestoresDraftScopeAndInterruptedExchangeWithoutStoringKeyField() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try IndexStore(vault: Vault(root: root))
        let engine = AskEngine(index: index, source: Fixture.vault, client: MockAPI.client, key: { nil })
        let url = index.vault.stateDir.appendingPathComponent("ask-history.json")
        var partial = Exchange(question: "Prior question"); partial.text = "Partial response"
        try AskHistoryStore.save(AskHistory(exchanges: [partial], draft: "Follow-up", currentFileOnly: true), to: url)
        let session = AskSession(engine: engine)
        XCTAssertEqual(session.draft, "Follow-up")
        XCTAssertTrue(session.currentFileOnly)
        XCTAssertTrue(session.current?.done == true)
        XCTAssertNotNil(session.current?.error)
        session.hasKey = true; session.keyDraft = "sk-ant-secret-test"; session.draft = "Durable question"
        session.persist()
        let deadline = Date().addingTimeInterval(2)
        while (try AskHistoryStore.load(url).draft) != "Durable question", Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try AskHistoryStore.load(url).draft, "Durable question")
        XCTAssertFalse(try String(contentsOf: url).contains("sk-ant-secret-test"))

        let corrupted = Data("Original broken history".utf8)
        try corrupted.write(to: url)
        let guarded = AskSession(engine: engine)
        guarded.hasKey = true; guarded.draft = "New question"; guarded.persist()
        XCTAssertNotNil(guarded.persistenceError)
        XCTAssertEqual(try Data(contentsOf: url), corrupted)
    }
}

private struct RefinedHitSource: PassageSource {
    var base: FakeSource
    var hit: SearchHit
    var vault: Vault { base.vault }
    func searchSections(_ query: String, limit: Int) throws -> [SearchHit] { [hit] }
    func searchComments(_ query: String, limit: Int) throws -> [CommentHit] { [] }
    func sections(of ref: FileRef) throws -> [SourceSection] { try base.sections(of: ref) }
    func text(of ref: FileRef) throws -> String? { try base.text(of: ref) }
    func comments(on ref: FileRef) throws -> [Comment] { [] }
    func files() -> [FileRef] { base.files() }
}
