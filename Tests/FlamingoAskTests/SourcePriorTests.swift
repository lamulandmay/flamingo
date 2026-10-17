import XCTest
import FlamingoCore
@testable import FlamingoAsk

final class SourcePriorTests: XCTestCase {
    func testUserDocumentsOutrankToolOutput() {
        let doc = SourcePrior.weight("Documents/Works/plan.md")
        XCTAssertGreaterThan(doc, 1)
        for noise in [".claude/projects/x/session.jsonl", ".claude-science/conda/envs/python/include/a.hpp",
                      "codex/cgnsa/build/run/source-manifest.json", "Library/Application Support/App/state.json",
                      "proj/node_modules/pkg/README.md", "x/flybrain-0.0.2.dist-info/RECORD"] {
            XCTAssertLessThan(SourcePrior.weight(noise), 0.35, noise)
        }
        XCTAssertEqual(SourcePrior.weight("src/main.swift"), 1)
    }

    func testHashManifestsReadAsLowQuality() {
        let manifest = (0..<8).map { #""src/f\#($0).py":"a4115b9dddee77c703309d69126ab40f248711488ed43d547ea8c86d""# }.joined(separator: ",")
        XCTAssertLessThan(SourcePrior.quality(manifest), 0.4)
        XCTAssertEqual(SourcePrior.quality("The launch moves to November 18 because tooling slipped two weeks."), 1)
    }

    func testDuplicateKeyIgnoresSpacingAndCase() {
        XCTAssertEqual(SourcePrior.duplicateKey("# Design\n\nOne  accent."), SourcePrior.duplicateKey("# design one accent"))
    }

    func testFollowUpsBorrowTheLastQuestionAndNewSubjectsDont() {
        let history = [ConversationTurn(question: "what did the supplier agreement say about MOQ", answer: "5,000")]
        XCTAssertEqual(AskEngine.retrievalQuestion("and the lead time?", history: history),
                       "what did the supplier agreement say about MOQ and the lead time?")
        XCTAssertEqual(AskEngine.retrievalQuestion("why did tooling slip in the arc launch plan", history: history),
                       "why did tooling slip in the arc launch plan")
    }

    func testContextNamesOpenFileAndCollapsesRepeatVisits() {
        let at = Date(timeIntervalSince1970: 1_792_000_000)
        let ctx = AskContext(openFile: FileRef(relativePath: "decks/q3.pptx"), anchor: FileAnchor(kind: .slide, value: "7"), folder: "decks",
                             recent: [.init(file: FileRef(relativePath: "a.md"), at: at), .init(file: FileRef(relativePath: "a.md"), at: at),
                                      .init(file: FileRef(relativePath: "b.md"), at: at)])
        let prompt = ctx.prompt()
        XCTAssertTrue(prompt.hasPrefix("<context>\nopen: decks/q3.pptx at "))
        XCTAssertEqual(prompt.components(separatedBy: "a.md").count - 1, 1)
        XCTAssertTrue(prompt.contains("b.md"))
        XCTAssertEqual(AskContext.empty.prompt(), "")
    }
}
