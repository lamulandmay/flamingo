import XCTest
import FlamingoCore
import FlamingoIndex
@testable import FlamingoAsk

/// Retrieval against the real index on the demo vault (`fixtures/vault`, plan 10). The vault is
/// copied first so indexing never writes into the fixture.
final class VaultIntegrationTests: XCTestCase {
    static var index: IndexStore?

    override class func setUp() {
        // Resolve links first: copying a symlink copies the link, and indexing through it would
        // write into the fixture.
        let fixture = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/vault").resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: fixture.path) else { return }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("ask-vault-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: fixture, to: copy)
            let attributes = try FileManager.default.attributesOfItem(atPath: copy.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  !copy.resolvingSymlinksInPath().path.hasPrefix(fixture.path) else {
                print("vault copy is not a separate directory; not indexing")
                return
            }
            for name in ["index.sqlite", "index.sqlite-wal", "index.sqlite-shm", "graph.json"] {
                try? FileManager.default.removeItem(at: copy.appendingPathComponent(".flamingo/\(name)"))
            }
            let index = try IndexStore(vault: Vault(root: copy))
            try index.reindex()
            Self.index = index
        } catch {
            print("vault fixture unavailable: \(error)")
        }
    }

    func retrieve(_ q: String) throws -> [Passage] {
        guard let index = Self.index else { throw XCTSkip("fixtures/vault not available") }
        let passages = try Retriever(source: IndexSource(index: index)).retrieve(q)
        print("\n» \(q)")
        for p in passages.prefix(12) {
            print("  [\(p.id)] \(p.kind == .comment ? "comment" : "section") \(p.file.relativePath) \(p.anchor?.rendered ?? "") — \(p.text.prefix(70).replacingOccurrences(of: "\n", with: " "))")
        }
        return passages
    }

    func place(_ p: Passage) -> String { "\(p.file.name) \(p.anchor?.rendered ?? "")" }

    func testWhatDidIDecideAboutPricing() throws {
        let passages = try retrieve("what did I decide about pricing")
        let first = try XCTUnwrap(passages.first)
        XCTAssertEqual(first.kind, .comment, "the user's own thinking comes first")

        XCTAssertTrue(passages.contains { $0.kind == .comment && $0.text.contains("Pricing contradicts") },
                      "the comment connecting the deck and the model")
        XCTAssertTrue(passages.contains { $0.kind == .section && $0.file.name == "q3-board-review.pptx" && $0.anchor == FileAnchor(kind: .slide, value: "7") },
                      "the slide: \(passages.map(place))")
        // The sheet arrives through the comment's link, once the index has the workbook's text
        // (plans/REQUESTS.md: 10 → 05, "the index stores no file text").
        let model = FileRef(relativePath: "finance/q3-model.xlsx")
        if let text = try Self.index?.text(of: model), text.count > model.name.count + 2 {
            XCTAssertTrue(passages.contains { $0.kind == .section && $0.file == model },
                          "the sheet the comment links to: \(passages.map(place))")
        }
        XCTAssertFalse(passages.contains { $0.kind == .section && $0.text == $0.file.name },
                       "no passages that are only a file name")
        XCTAssertLessThanOrEqual(passages.reduce(0) { $0 + Retriever.tokens($1) }, 12_000)
    }

    func testTwoHopFollowUpFindsTheLinkedFile() throws {
        guard let index = Self.index else { throw XCTSkip("fixtures/vault not available") }
        let r = Retriever(source: IndexSource(index: index))
        let first = try r.retrieve("supplier MOQ")
        let more = try r.retrieve("BOM unit cost")
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(more.first?.id, first.count + 1)
        XCTAssertTrue(more.contains { $0.file.name == "unit-economics.xlsx" }, "\(more.map(place))")
    }

    func testQuestionsAcrossTheVault() throws {
        let launch = try retrieve("when does the PO need to go out")
        XCTAssertTrue(launch.contains { $0.file.name == "supplier-agreement.pdf" }, "\(launch.map(place))")
        let shade = try retrieve("shade size mismatch")
        XCTAssertTrue(shade.contains { $0.file.name == "arc-lamp.usdz" || $0.file.name == "arc-product-brief.docx" }, "\(shade.map(place))")
    }
}
