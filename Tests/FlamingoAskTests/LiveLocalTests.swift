import XCTest
import FlamingoCore
import FlamingoIndex
@testable import FlamingoAsk

/// The real 27B on the demo vault. Opt-in: `FLAMINGO_LIVE=1`; starts llama-server if needed.
final class LiveLocalTests: XCTestCase {
    func testDescribeAndAskOffline() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FLAMINGO_LIVE"] == "1", "set FLAMINGO_LIVE=1")
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../fixtures/vault").standardized
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-ask-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixtures, to: root)
        defer { try? FileManager.default.removeItem(at: root); LlamaServer.shared.stop() }
        let index = try IndexStore(vault: Vault(root: root))
        try index.reindex()
        let engine = AskEngine(index: index)
        engine.providerChoice = { .llama }

        let comment = try await engine.describe(FileRef(relativePath: "design/whiteboard-pricing.jpg"))
        print("DESCRIBE", comment.text)
        XCTAssertEqual(comment.anchor?.rendered, "(region full)")

        let answer = try await engine.ask("What price did the board see for Arc?")
        print("ANSWER", answer.text, answer.citations.map(\.id))
        XCTAssertFalse(answer.citations.isEmpty)
    }
}
