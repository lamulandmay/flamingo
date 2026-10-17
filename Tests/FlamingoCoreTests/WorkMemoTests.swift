import XCTest
@testable import FlamingoCore

final class WorkMemoTests: XCTestCase {
    static let sample = WorkMemo(
        thought: "t8m2k4q9xa", on: "decks/q3-board-review.pptx#slide 7", recipe: "review-conflict", verdict: "conflict",
        sources: ["decks/q3-board-review.pptx#slide 7 · 2026-10-13 14:02", "finance/q3-model.xlsx#cell Revenue!C12 · 2026-10-12 19:30"],
        model: "qwen3.8-27b", provider: "llama", tokens: 7412, created: "2026-10-17 02:14",
        title: "Arc price: deck $249, model $229",
        body: "Slide 7 prices Arc at $249; the Q3 model still multiplies by $229.\n\n## Where they disagree\n1. **Arc retail price.** [[q3-board-review.pptx#slide 7]] \"Arc — $249 retail\"\n\n## Next step\nChange Revenue!C12 to $249.")

    func testRenderMatchesTheDesignAndParsesBack() throws {
        let text = Self.sample.render()
        XCTAssertTrue(text.hasPrefix("""
            ---
            flamingo: memo
            thought: t8m2k4q9xa
            on: "decks/q3-board-review.pptx#slide 7"
            recipe: review-conflict
            verdict: conflict
            sources:
              - "decks/q3-board-review.pptx#slide 7 · 2026-10-13 14:02"
              - "finance/q3-model.xlsx#cell Revenue!C12 · 2026-10-12 19:30"
            model: qwen3.8-27b
            provider: llama
            tokens: 7412
            created: 2026-10-17 02:14
            ---
            # Arc price: deck $249, model $229

            Slide 7
            """), text)
        XCTAssertEqual(try XCTUnwrap(WorkMemo.parse(text)), Self.sample)
        XCTAssertEqual(WorkMemo.parse(text)?.render(), text)
    }

    func testYAMLQuotingOfAwkwardValues() throws {
        var memo = Self.sample
        memo.on = "decks/q3: the \"final\" one!#slide 7"
        memo.verdict = "yes"          // a YAML boolean
        memo.model = "# local: model"
        memo.provider = "!llama"
        memo.sources = ["a #b: c", "x\\y \"z\""]
        let parsed = try XCTUnwrap(WorkMemo.parse(memo.render()))
        XCTAssertEqual(parsed, memo)
        XCTAssertTrue(memo.render().contains("verdict: \"yes\""))
        XCTAssertTrue(memo.render().contains("model: \"# local: model\""))
        XCTAssertTrue(memo.render().contains("provider: \"!llama\""))
    }

    func testUnknownFrontmatterSurvivesAndNonMemosAreRejected() throws {
        let text = Self.sample.render().replacingOccurrences(of: "model: qwen3.8-27b\n", with: "model: qwen3.8-27b\nfuture: 1\n")
        let parsed = try XCTUnwrap(WorkMemo.parse(text))
        XCTAssertEqual(parsed.render(), text.replacingOccurrences(of: "future: 1\n", with: "").replacingOccurrences(of: "created: 2026-10-17 02:14\n", with: "created: 2026-10-17 02:14\nfuture: 1\n"))
        XCTAssertNil(WorkMemo.parse("# just markdown\n"))
        XCTAssertNil(WorkMemo.parse("---\ntitle: x\n---\nbody\n"))
    }

    func testPathsAndWriting() throws {
        let tv = try TempVault(); defer { tv.destroy() }
        XCTAssertEqual(Self.sample.relativePath(), "work/2026-10-17/arc-price-deck-249-model-229.md")
        let relative = try Self.sample.write(in: tv.vault)
        XCTAssertEqual(WorkMemo.read(at: tv.vault.stateDir.appendingPathComponent(relative)), Self.sample)
        XCTAssertEqual(Self.sample.url(in: tv.vault).path, tv.vault.workDir.path + "/2026-10-17/arc-price-deck-249-model-229.md")
        var untitled = Self.sample; untitled.title = ""
        XCTAssertEqual(untitled.relativePath(), "work/2026-10-17/review-conflict.md")
    }

    func testLedgerAppendsWholeLinesAndIgnoresATornTail() throws {
        let tv = try TempVault(); defer { tv.destroy() }
        try WorkLedgerFile.append("{\"event\":\"queued\"}", in: tv.vault)
        try WorkLedgerFile.append("{\"event\":\"started\"}", in: tv.vault)
        XCTAssertEqual(WorkLedgerFile.lines(in: tv.vault), ["{\"event\":\"queued\"}", "{\"event\":\"started\"}"])
        let handle = try FileHandle(forWritingTo: tv.vault.workLedgerURL)
        handle.seekToEndOfFile(); handle.write(Data("{\"event\":\"fini".utf8)); handle.closeFile()
        XCTAssertEqual(WorkLedgerFile.lines(in: tv.vault).count, 2, "a crash mid-append leaves a torn last line")
        XCTAssertEqual(WorkLedgerFile.lines(in: Vault(root: tv.root.appendingPathComponent("empty"))), [])
    }
}
