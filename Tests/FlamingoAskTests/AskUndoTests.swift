import XCTest
import FlamingoCore
import FlamingoIndex
@testable import FlamingoAsk

@MainActor
final class AskUndoTests: XCTestCase {
    private var retainedEngine: AskEngine?

    private func makeSession() throws -> AskSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-undo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = AskEngine(index: try IndexStore(vault: Vault(root: root)), source: Fixture.vault,
                               client: MockAPI.client, key: { "sk-test" })
        retainedEngine = engine
        let session = AskSession(engine: engine)
        session.hasKey = true
        return session
    }

    private func ask(_ session: AskSession, _ question: String) async throws {
        session.draft = question
        session.submit()
        let deadline = Date().addingTimeInterval(5)
        while session.current?.done != true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(session.current?.done == true)
    }

    func testUndoAndRedoSubmissionRetainCompletedAnswerWithoutSendingAgain() async throws {
        MockAPI.reset([SSE.reply(SSE.message(text: ["first answer"])), SSE.reply(SSE.message(text: ["second answer"]))])
        let session = try makeSession(), history = ActionHistory()
        session.actionHistory = history
        try await ask(session, "first")
        let first = try XCTUnwrap(session.current)
        try await ask(session, "second")
        let second = try XCTUnwrap(session.current), requests = MockAPI.requests.count

        XCTAssertTrue(try history.undo())
        XCTAssertEqual(session.current, first)
        XCTAssertTrue(session.history.isEmpty)
        XCTAssertTrue(try history.redo())
        XCTAssertEqual(session.current, second)
        XCTAssertEqual(session.history, [first])
        XCTAssertEqual(MockAPI.requests.count, requests)

        let root = try XCTUnwrap(retainedEngine).index.vault.stateDir
        let deadline = Date().addingTimeInterval(5)
        var saved: AskHistory?
        repeat {
            saved = try? AskHistoryStore.load(root.appendingPathComponent("ask-history.json"))
            if saved?.exchanges == [first, second] { break }
            try await Task.sleep(for: .milliseconds(5))
        } while Date() < deadline
        XCTAssertEqual(saved?.exchanges, [first, second])
    }

    func testImmediateUndoCancelsUnsentRequestAndRedoOnlyRestoresLocalState() async throws {
        MockAPI.reset([SSE.reply(SSE.message(text: ["should not be requested"]))])
        let session = try makeSession(), history = ActionHistory()
        session.actionHistory = history
        session.draft = "question"
        session.submit()
        XCTAssertTrue(try history.undo())
        XCTAssertNil(session.current)
        XCTAssertFalse(session.waiting)
        XCTAssertTrue(try history.redo())
        XCTAssertEqual(session.current?.question, "question")
        XCTAssertTrue(session.current?.done == true)
        XCTAssertFalse(session.waiting)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(MockAPI.requests.isEmpty)
    }

    func testStopUndoDoesNotResumeRequestOrAcceptItsLateUpdates() async throws {
        MockAPI.reset([SSE.reply(SSE.message(text: ["late answer"]))])
        let session = try makeSession(), history = ActionHistory()
        session.actionHistory = history
        session.draft = "question"
        session.submit()
        let id = session.current?.id
        session.stop()
        XCTAssertEqual(session.current?.error, "Stopped; partial answer retained")
        XCTAssertTrue(try history.undo())
        XCTAssertEqual(session.current?.id, id)
        XCTAssertTrue(session.current?.done == true)
        XCTAssertFalse(session.waiting)
        XCTAssertTrue(try history.redo())
        XCTAssertEqual(session.current?.error, "Stopped; partial answer retained")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(session.current?.text, "")
        XCTAssertTrue(MockAPI.requests.isEmpty)
    }

    func testHistoryAndQuestionRecallRestoreTheirPreviousState() async throws {
        MockAPI.reset([SSE.reply(SSE.message(text: ["A"])), SSE.reply(SSE.message(text: ["B"]))])
        let session = try makeSession(), history = ActionHistory()
        try await ask(session, "first")
        try await ask(session, "second")
        session.actionHistory = history
        let first = session.history[0], second = try XCTUnwrap(session.current)
        session.show(first)
        XCTAssertTrue(try history.undo())
        XCTAssertEqual(session.current, second)
        XCTAssertEqual(session.history, [first])
        XCTAssertEqual(session.draft, "second")
        XCTAssertTrue(try history.redo())
        XCTAssertEqual(session.current, first)
        XCTAssertEqual(session.history, [second])
        XCTAssertTrue(session.recall(-1))
        XCTAssertEqual(session.draft, "second")
        XCTAssertTrue(try history.undo())
        XCTAssertEqual(session.draft, "first")
        XCTAssertFalse(session.isRecalling)
        XCTAssertTrue(try history.redo())
        XCTAssertEqual(session.draft, "second")
        XCTAssertTrue(session.isRecalling)
        XCTAssertEqual(MockAPI.requests.count, 2)
    }

    func testAskScopeAndProviderUndoWithoutTouchingCredentials() throws {
        let session = try makeSession(), history = ActionHistory()
        session.actionHistory = history
        session.setCurrentFileOnly(true)
        XCTAssertTrue(try history.undo())
        XCTAssertFalse(session.currentFileOnly)
        XCTAssertTrue(try history.redo())
        XCTAssertTrue(session.currentFileOnly)

        let original = AskProvider.preferred
        defer { AskProvider.preferred = original }
        let changed: AskProvider = original == .ollama ? .auto : .ollama
        session.setProvider(changed)
        XCTAssertEqual(AskProvider.preferred, changed)
        XCTAssertTrue(try history.undo())
        XCTAssertEqual(AskProvider.preferred, original)
        XCTAssertTrue(try history.redo())
        XCTAssertEqual(AskProvider.preferred, changed)
    }
}
