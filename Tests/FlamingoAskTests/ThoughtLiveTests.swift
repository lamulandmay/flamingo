import XCTest
import FlamingoCore
import FlamingoIndex
@testable import FlamingoAsk

/// The thought AI on the demo vault with Ollama on localhost. Opt-in: `FLAMINGO_LIVE=1`.
/// The 27B is never started here: it is made unavailable so the small Ollama model answers.
final class ThoughtLiveTests: XCTestCase {
    func testUnderstandAndReviewConflictOnTheDemoVault() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FLAMINGO_LIVE"] == "1", "set FLAMINGO_LIVE=1")
        let saved = LocalCompletionRuntime.current
        defer { LocalCompletionRuntime.current = saved }
        var runtime = LocalCompletionRuntime()
        runtime.llama = { _, _ in throw AskError.unavailable("the 27B is not started by this test") }
        runtime.runningLlama = { nil }
        LocalCompletionRuntime.current = runtime
        guard await runtime.ollamaIsUp(runtime.session) else { throw XCTSkip("Ollama isn't running") }

        let v = try ThoughtVault()
        let text = "review conflict between this and [[q3-model.xlsx]] before friday"
        let c = try v.think(text)

        var t = Date()
        let outcome = await ThoughtReader(engine: v.engine, store: v.store).read(uid: try XCTUnwrap(c.uid), on: ThoughtVault.deck,
                                                                              candidates: [ThoughtVault.model])
        print("LIVE understand (\(Int(Date().timeIntervalSince(t) * 1000)) ms):", outcome)
        print("LIVE meta:", String(describing: try v.store.comment(uid: c.uid!, in: ThoughtVault.deck)?.meta))

        t = Date()
        let request = WorkRequest(recipe: .reviewConflict, thoughtUID: c.uid!, thoughtText: text, thoughtTimestamp: c.timestamp,
                                  file: ThoughtVault.deck, anchor: c.anchor,
                                  objects: ["decks/q3-board-review.pptx#slide 7", "finance/q3-model.xlsx"], purpose: .nightShift)
        let result = try await v.engine.work(request) { print("LIVE status:", $0) }
        print("LIVE review-conflict (\(Int(Date().timeIntervalSince(t) * 1000)) ms, \(result.tokens) tokens, \(result.model)):")
        print(result.memo.render())
        print("LIVE reply:", result.replyText)
    }
}
