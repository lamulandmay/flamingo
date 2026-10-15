import XCTest
import FlamingoCore
@testable import FlamingoIndex

final class SemanticTests: XCTestCase {
    var root: URL!
    var store: IndexStore!

    /// Three concepts, one dimension each, plus a little of everything so no vector is zero.
    static let concepts: [[String]] = [["price", "pay", "cost", "dollars"], ["contract", "agreement", "manufacturer", "supplier"], ["lamp", "light", "glow"]]
    static let fake: @Sendable ([String]) -> [[Float]]? = { inputs in
        inputs.map { text in
            let words = text.lowercased().split { !$0.isLetter }.map(String.init)
            return concepts.map { c in Float(words.filter(c.contains).count) } + [0.2]
        }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("terms.md", "The supplier agreement binds the manufacturer to the contract.")
        try write("money.md", "We will charge forty dollars; the price is final.")
        try write("lamp.md", "A lamp with a warm glow.")
        store = try IndexStore(vault: Vault(root: root))
        store.embedding.embedder.fake = Self.fake
        try store.reindex()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func write(_ name: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testEmbedsEverySectionOnce() throws {
        let total = try store.embeddingProgress().total
        XCTAssertEqual(store.embedPending(), total)
        XCTAssertEqual(try store.embeddingProgress().embedded, total)
        XCTAssertEqual(store.embedPending(), 0, "nothing left")
    }

    func testFindsAConceptWithNoKeywordOverlap() throws {
        store.embedPending()
        XCTAssertEqual(try store.search("pay cost", limit: 5).first?.file.relativePath, "money.md")
        XCTAssertEqual(try store.searchSections("manufacturer", limit: 5).first?.file.relativePath, "terms.md")
        XCTAssertTrue(try store.search("pay cost", limit: 5).allSatisfy { $0.file.relativePath != "lamp.md" }, "below the floor")
    }

    func testKeywordHitsStayFirst() throws {
        store.embedPending()
        try write("cheap.md", "Pay what you want for the lamp.")
        try store.update([FileRef(relativePath: "cheap.md")])
        store.embedPending()
        XCTAssertEqual(try store.search("lamp", limit: 5).first?.file.relativePath, "lamp.md")
    }

    func testEditingAFileDropsItsVectorsUntilReembedded() throws {
        store.embedPending()
        try write("money.md", "A lamp that glows.")
        try store.update([FileRef(relativePath: "money.md")])
        let (embedded, total) = try store.embeddingProgress()
        XCTAssertLessThan(embedded, total)
        store.embedPending()
        XCTAssertEqual(try store.search("glow light", limit: 5).map(\.file.relativePath).sorted(), ["lamp.md", "money.md"])
    }

    func testWithoutOllamaSearchIsKeywordOnly() throws {
        store.embedding.embedder.fake = { _ in nil }
        XCTAssertEqual(store.embedPending(), 0)
        XCTAssertEqual(try store.search("price", limit: 5).map(\.file.relativePath), ["money.md"])
        XCTAssertTrue(try store.search("pay cost", limit: 5).isEmpty)
    }

    func testFusionAddsRanksAndKeepsFirstSeenOrderOnTies() {
        let fused = Fusion.fuse([["a", "b"], ["b", "c"]]) { $0 }
        XCTAssertEqual(fused.map(\.item), ["b", "a", "c"])
        let weighted = Fusion.fuse([["a"], ["c"]], weights: [1, 0.8]) { $0 }
        XCTAssertEqual(weighted.map(\.item), ["a", "c"])
    }

    func testMatrixReturnsCosineOrder() {
        let m = VectorMatrix(sections: [1, 2, 3], dim: 2, values: [1, 0, 0, 1, 0.6, 0.8])
        XCTAssertEqual(m.nearest([1, 0], limit: 2, floor: 0.1).map(\.section), [1, 3])
    }
}
