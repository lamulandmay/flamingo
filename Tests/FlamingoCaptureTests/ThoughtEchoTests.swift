import XCTest
@testable import FlamingoCapture
import FlamingoCore

@MainActor
final class ThoughtEchoTests: XCTestCase {
    /// Stands in for the clock: a sleep that only ends when the test says time has passed.
    final class Clock: @unchecked Sendable {
        var open = false
        var delays: [TimeInterval] = []
        func sleep(_ delay: TimeInterval) async throws {
            delays.append(delay)
            while !open { try await Task.sleep(for: .milliseconds(1)) }
            try Task.checkCancellation()
        }
    }

    private func hit(_ line: String, _ n: Int = 0) -> EchoHit {
        EchoHit(uid: "t\(n)", file: FileRef(relativePath: "decks/q3.pptx"), firstLine: line, kind: .question, date: Date(timeIntervalSince1970: 1_760_000_000))
    }

    private func make(_ clock: Clock, hits: [EchoHit], asked: @escaping (String) -> Void = { _ in }) -> ThoughtEchoModel {
        ThoughtEchoModel(similar: { text in asked(text); return hits }, sleep: { try await clock.sleep($0) })
    }

    func testWordCountIgnoresQuotesAndMentions() {
        XCTAssertEqual(ThoughtEchoModel.wordCount("Why is margin lower"), 4)
        XCTAssertEqual(ThoughtEchoModel.wordCount("> a long quoted passage here\nOne two"), 2)
        XCTAssertEqual(ThoughtEchoModel.wordCount("@ai check this"), 2)
        XCTAssertEqual(ThoughtEchoModel.wordCount(""), 0)
    }

    func testFewerThanFourWordsNeverAsks() async {
        let clock = Clock(); clock.open = true
        var asked: [String] = []
        let model = make(clock, hits: [hit("x")], asked: { asked.append($0) })
        model.update(draft: "three little words")
        await model.settle()
        XCTAssertTrue(asked.isEmpty)
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertTrue(clock.delays.isEmpty)
    }

    func testAsksOnlyAfterTheDelayAndShowsAtMostTwo() async {
        let clock = Clock()
        var asked: [String] = []
        let model = make(clock, hits: [hit("one", 1), hit("two", 2), hit("three", 3)], asked: { asked.append($0) })
        model.update(draft: "Why is margin lower")
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(asked.isEmpty, "nothing before the delay has passed")
        XCTAssertEqual(clock.delays, [0.4])
        clock.open = true
        await model.settle()
        XCTAssertEqual(asked, ["Why is margin lower"])
        XCTAssertEqual(model.hits.map(\.firstLine), ["one", "two"])
    }

    func testTypingOnRestartsTheDelayAndOnlyTheLastDraftIsAsked() async {
        let clock = Clock()
        var asked: [String] = []
        let model = make(clock, hits: [hit("a")], asked: { asked.append($0) })
        model.update(draft: "Why is margin lower")
        try? await Task.sleep(for: .milliseconds(10))
        model.update(draft: "Why is margin lower in Q3")
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(clock.delays, [0.4, 0.4])
        clock.open = true
        await model.settle()
        XCTAssertEqual(asked, ["Why is margin lower in Q3"])
    }

    func testDeletingBackBelowFourWordsClearsTheRows() async {
        let clock = Clock(); clock.open = true
        let model = make(clock, hits: [hit("a")])
        model.update(draft: "Why is margin lower")
        await model.settle()
        XCTAssertEqual(model.hits.count, 1)
        model.update(draft: "Why is")
        XCTAssertTrue(model.hits.isEmpty)
    }

    func testAnAnswerForAnOlderDraftIsDropped() async {
        let clock = Clock(); clock.open = true
        let model = ThoughtEchoModel(similar: { text in
            try? await Task.sleep(for: .milliseconds(40))
            return [EchoHit(uid: "t", file: FileRef(relativePath: "a.md"), firstLine: text, date: Date())]
        }, sleep: { try await clock.sleep($0) })
        model.update(draft: "Why is margin lower")
        try? await Task.sleep(for: .milliseconds(15))
        model.update(draft: "Why is")
        await model.settle()
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(model.hits.isEmpty)
    }
}
