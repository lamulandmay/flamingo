import XCTest
import FlamingoCore
import FlamingoIndex
@testable import FlamingoAsk

/// The key the engine reads, as the Keychain would hold it.
final class KeyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _key = "sk-test"
    var key: String { get { lock.withLock { _key } } set { lock.withLock { _key = newValue } } }
}

@MainActor
final class AskSessionTests: XCTestCase {
    var stored: [String] = []
    let keys = KeyBox()

    func makeSession() throws -> AskSession {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keys = self.keys
        let engine = AskEngine(index: try IndexStore(vault: Vault(root: dir)), source: Fixture.vault,
                               client: MockAPI.client, key: { keys.key })
        let session = AskSession(engine: engine)
        session.hasKey = true
        session.storeKey = { [weak self] key in
            self?.stored.append(key)
            keys.key = key
        }
        retain = engine
        return session
    }
    private var retain: AskEngine?

    func ask(_ session: AskSession, _ q: String) async {
        session.draft = q
        session.submit()
        await until { session.current?.done == true || !session.hasKey }
    }

    func until(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testAnswerArrivesAndCitesPassages() async throws {
        MockAPI.reset([SSE.reply(SSE.message(text: ["Kept $49 ", "[1]."]))])
        let s = try makeSession()
        await ask(s, "what did I decide about pricing")
        XCTAssertEqual(s.current?.text, "Kept $49 [1].")
        XCTAssertEqual(s.current?.citations.first?.file, Fixture.deck)
        XCTAssertFalse(s.waiting)
        XCTAssertEqual(s.draft, "what did I decide about pricing", "the question stays above its answer")
    }

    func testAskingAgainBeforeAnAnswerKeepsOnlyTheNewOne() async throws {
        MockAPI.reset([SSE.reply(SSE.message(text: ["first"])), SSE.reply(SSE.message(text: ["second"]))])
        let s = try makeSession()
        s.draft = "one"; s.submit()
        s.draft = "two"; s.submit()
        await until { s.current?.done == true }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(s.current?.question, "two")
        XCTAssertTrue(["first", "second"].contains(s.current?.text ?? ""))
        XCTAssertFalse(s.waiting)
        XCTAssertTrue(s.history.allSatisfy { $0.done }, "nothing in history is left streaming")
    }

    func testRecallWalksBackSkippingWhatIsAlreadyInTheField() async throws {
        MockAPI.reset((0..<3).map { _ in SSE.reply(SSE.message(text: ["ok"])) })
        let s = try makeSession()
        for q in ["alpha", "beta", "gamma"] { await ask(s, q) }
        XCTAssertEqual(s.history.map(\.question), ["alpha", "beta"])
        XCTAssertEqual(s.draft, "gamma")
        XCTAssertTrue(s.recall(-1)); XCTAssertEqual(s.draft, "beta")
        XCTAssertTrue(s.recall(-1)); XCTAssertEqual(s.draft, "alpha")
        XCTAssertTrue(s.recall(-1)); XCTAssertEqual(s.draft, "alpha", "stops at the oldest")
        XCTAssertTrue(s.recall(1)); XCTAssertEqual(s.draft, "beta")
        XCTAssertTrue(s.recall(1)); XCTAssertEqual(s.draft, "gamma")
        XCTAssertTrue(s.recall(1)); XCTAssertEqual(s.draft, "", "past the newest is an empty field")
        XCTAssertFalse(s.recall(1))
    }

    func testShowingAnEarlierExchangeSwapsItBackWithoutAsking() async throws {
        MockAPI.reset([SSE.reply(SSE.message(text: ["A"])), SSE.reply(SSE.message(text: ["B"]))])
        let s = try makeSession()
        await ask(s, "first")
        await ask(s, "second")
        let requests = MockAPI.requests.count
        s.show(s.history[0])
        XCTAssertEqual(s.current?.question, "first")
        XCTAssertEqual(s.current?.text, "A")
        XCTAssertEqual(s.history.map(\.question), ["second"])
        XCTAssertEqual(s.draft, "first")
        XCTAssertEqual(MockAPI.requests.count, requests)
    }

    func testRejectedKeyAsksForANewOneThenAsksAgain() async throws {
        if KeyStore.fromEnvironment { throw XCTSkip("ANTHROPIC_API_KEY is set; the key field never shows") }
        MockAPI.reset([SSE.error(401, "authentication_error", "invalid x-api-key"), SSE.reply(SSE.message(text: ["answer"]))])
        let s = try makeSession()
        await ask(s, "pricing")
        XCTAssertFalse(s.hasKey)
        XCTAssertEqual(s.keyError, "API key rejected")
        XCTAssertEqual(s.draft, "", "the question doesn't land in the key field")

        s.draft = "sk-ant-new"
        s.saveKey()
        XCTAssertEqual(stored, ["sk-ant-new"])
        XCTAssertTrue(s.hasKey)
        await until { s.current?.done == true }
        XCTAssertEqual(s.current?.question, "pricing", "the waiting question is asked again")
        XCTAssertEqual(s.current?.text, "answer")
        XCTAssertEqual(MockAPI.requests.last?.request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-new")
    }

    func testErrorsAreOneLine() async throws {
        MockAPI.reset([SSE.error(529, "overloaded_error", "Overloaded"), SSE.error(529, "overloaded_error", "Overloaded"),
                       SSE.error(529, "overloaded_error", "Overloaded")])
        let s = try makeSession()
        await ask(s, "pricing")
        XCTAssertEqual(s.current?.error, "Claude is overloaded")
        XCTAssertTrue(s.hasKey)
        XCTAssertFalse(s.waiting)
    }
}
