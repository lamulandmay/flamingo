import XCTest
import FlamingoCore
import FlamingoIndex
@testable import FlamingoAsk

final class ThoughtAskTests: LocalModelTestCase {
    func testWikifiedTurnsCitationNumbersIntoLinks() {
        var a = Answer(text: "The model uses $229 [1]. The deck says $249 [2][3]. Both agree on launch [1, 2]. See [9].", citations: [])
        a.sources = [
            1: Citation(file: FileRef(relativePath: "finance/q3-model.xlsx"), anchor: FileAnchor(kind: .cell, value: "Revenue!C12")),
            2: Citation(file: FileRef(relativePath: "decks/q3.pptx"), anchor: FileAnchor(kind: .slide, value: "7")),
            3: Citation(file: FileRef(relativePath: "decks/q3.pptx"), anchor: FileAnchor(kind: .slide, value: "7")),
        ]
        XCTAssertEqual(a.wikified(), "The model uses $229 [[finance/q3-model.xlsx#cell Revenue!C12]]. "
                       + "The deck says $249 [[decks/q3.pptx#slide 7]]. "
                       + "Both agree on launch [[finance/q3-model.xlsx#cell Revenue!C12]] [[decks/q3.pptx#slide 7]]. See [9].")
        XCTAssertEqual(Answer(text: "No sources [1].", citations: []).wikified(), "No sources [1].")
    }

    func testWikifiedCannotBeUsedToBreakOutOfALink() {
        var a = Answer(text: "x [1]", citations: [])
        a.sources = [1: Citation(file: FileRef(relativePath: "a]]b|c.md"), anchor: nil)]
        XCTAssertFalse(a.wikified().contains("]]b"))
        XCTAssertFalse(a.wikified().contains("|"))
    }

    func testMultiFileSourceReadsOnlyItsFiles() throws {
        let source = MultiFileSource(base: Fixture.vault, files: [Fixture.deck, Fixture.sheet, Fixture.deck])
        XCTAssertEqual(source.files(), [Fixture.deck, Fixture.sheet])
        XCTAssertEqual(try source.sections(of: Fixture.notes).count, 0)
        XCTAssertNil(try source.text(of: Fixture.notes))
        XCTAssertTrue(try source.comments(on: Fixture.notes).isEmpty)
        let hits = try source.searchSections("pricing", limit: 10)
        XCTAssertTrue(hits.allSatisfy { [Fixture.deck, Fixture.sheet].contains($0.file) })
        XCTAssertEqual(hits.first?.file, Fixture.deck, "the matching slide ranks first")
        XCTAssertEqual(try source.searchComments("pricing", limit: 5).first?.comment.id, Fixture.decision.id)
        XCTAssertTrue(ThoughtPrivacy.isScoped(source))
        XCTAssertTrue(ThoughtPrivacy.isScoped(ThoughtBlindSource(base: source)))
        XCTAssertFalse(ThoughtPrivacy.isScoped(Fixture.vault))
    }

    func testThoughtBlindSourceHidesEveryThought() throws {
        let blind = ThoughtBlindSource(base: Fixture.vault)
        XCTAssertTrue(try blind.comments(on: Fixture.deck).isEmpty)
        XCTAssertTrue(try blind.searchComments("pricing", limit: 10).isEmpty)
        XCTAssertFalse(try blind.searchSections("pricing", limit: 10).isEmpty, "files stay")
    }

    func testAskingLocallyStreamsFromTheFakeModel() async throws {
        use { $0.environment = { ["FLAMINGO_FAKE_LLM": "1"] } }
        let v = try ThoughtVault()
        var deltas: [Delta] = []
        for try await d in v.engine.askStreamingLocally("what price does the model use?", files: [ThoughtVault.model]) { deltas.append(d) }
        guard case .answer(let answer)? = deltas.last else { return XCTFail("\(deltas)") }
        XCTAssertTrue(answer.text.contains("$229"))
        XCTAssertEqual(answer.model, "fake-llm")
        XCTAssertTrue(deltas.contains { if case .passages(let p) = $0 { return p.allSatisfy { $0.file == ThoughtVault.model } } else { return false } })
        XCTAssertTrue(LoopbackStub.requests.isEmpty)
    }

    func testAskingLocallyWithNoModelEndsInAnErrorNotARemoteCall() async throws {
        use { $0.llama = { _, _ in throw AskError.unavailable("none") } }
        LoopbackStub.reset(nil)
        let v = try ThoughtVault()
        v.engine.providerChoice = { .claude }
        v.engine.keyProvider = { "sk-test" }
        do {
            for try await _ in v.engine.askStreamingLocally("hello", files: [ThoughtVault.deck]) {}
            XCTFail("should throw")
        } catch { XCTAssertTrue(error is AskError) }
        XCTAssertEqual(LoopbackStub.violations, [])
    }

    func testTheScopeOfAThoughtIsItsFileAndTheFilesItLinksTo() throws {
        let v = try ThoughtVault()
        let c = try v.think("Pricing contradicts [[q3-model.xlsx]] and [[no-such-file.md]]")
        let scope = v.engine.thoughtScope(for: c, on: ThoughtVault.deck)
        XCTAssertEqual(scope, [ThoughtVault.deck, ThoughtVault.model])
        XCTAssertEqual(v.engine.thoughtScope(for: c, on: FileRef(relativePath: "_inbox/2026-10-14")), [ThoughtVault.model])
        XCTAssertEqual(v.engine.resolveFile("q3-model.xlsx"), ThoughtVault.model)
        XCTAssertNil(v.engine.resolveFile("../etc/passwd"))
        XCTAssertNil(v.engine.resolveFile("/etc/passwd"))
    }

    func testFixturesDirectoryIsFound() {
        XCTAssertNotNil(LocalCompletionRuntime.fixtureDirectory([:]))
        for name in ["understanding-understand", "night-shift-review-conflict", "night-shift-compare-versions", "night-shift-summarize",
                     "night-shift-answer", "night-shift-find-related", "interactive-ask"] {
            let data = try? Data(contentsOf: WorkRecipeTests.fixture(name))
            XCTAssertNotNil(data.flatMap { try? JSON.decode(Self.unreferenced($0)) }, name)
        }
    }

    /// A fixture with its `@file` references made into numbers, which is what makes it JSON.
    static func unreferenced(_ data: Data) -> Data {
        Data(LocalCompletionRuntime.resolvePassageReferences(in: String(decoding: data, as: UTF8.self), prompt: "").utf8)
    }
}
