import XCTest
import FlamingoCore
@testable import FlamingoIndex

/// Real nomic-embed-text over the demo vault. Opt-in: `FLAMINGO_LIVE=1` with Ollama running.
final class SemanticLiveTests: XCTestCase {
    func testConceptsWithoutKeywordOverlap() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FLAMINGO_LIVE"] == "1", "set FLAMINGO_LIVE=1")
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../fixtures/vault").standardized
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixtures, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IndexStore(vault: Vault(root: root))
        try store.reindex()
        XCTAssertGreaterThan(store.embedPending(), 0)
        XCTAssertEqual(store.semanticSections("contract with the manufacturer", limit: 5).first?.path, "legal/supplier-agreement.pdf")
        XCTAssertTrue(store.semanticSections("zebra migration patterns", limit: 5).isEmpty, "below the floor")
        XCTAssertTrue(try store.search("size of the market opportunity", limit: 3).contains { $0.file.relativePath == "research/market-sizing.pdf" })
        XCTAssertEqual(try store.search("q3 model", limit: 1).first?.file.relativePath, "finance/q3-model.xlsx", "keyword still leads")
    }
}
