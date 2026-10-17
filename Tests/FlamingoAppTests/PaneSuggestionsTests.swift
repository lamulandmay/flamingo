import XCTest
import FlamingoCore
import FlamingoIndex
@testable import Flamingo

final class PaneSuggestionsTests: XCTestCase {
    private func ref(_ name: String) -> FileRef { FileRef(relativePath: name) }
    private func connection(_ name: String, _ reason: ConnectionReason, weight: Double = 1) -> FileConnection {
        let evidence = [ConnectionEvidence(reason: reason, weight: weight)]
        return FileConnection(file: ref(name), anchor: nil, evidence: evidence, strength: FileConnections.strength(of: evidence))
    }
    private func snapshot(_ items: [FileConnection]) -> FileConnectionsSnapshot {
        var s = FileConnectionsSnapshot()
        s.explicit = items.filter(\.isExplicit); s.suggested = items.filter { !$0.isExplicit }
        return s
    }
    private func names(_ block: [PaneSuggestion]) -> [String] { block.map(\.file.relativePath) }

    func testExplicitBeatsSimilarBeatsTogetherBeatsRecency() {
        let seed = PaneSeed(file: ref("seed.md"), weight: 1)
        let evidence = [seed.file: snapshot([connection("together.md", .together, weight: 3), connection("similar.md", .similar),
                                             connection("linked.md", .linked)])]
        let recents = [(file: ref("recent.md"), score: 5.0)]
        let out = PaneSuggestions.rank(seeds: [seed], evidence: evidence, recents: recents, exclude: [seed.file], launchers: 1)
        XCTAssertEqual(names(out[0]), ["linked.md", "similar.md", "together.md", "recent.md"])
    }

    func testScoresFromSeveralSeedsAddUp() {
        let a = PaneSeed(file: ref("a.md"), weight: 1), b = PaneSeed(file: ref("b.md"), weight: 0.8)
        let evidence = [a.file: snapshot([connection("both.md", .similar), connection("one.md", .similar, weight: 1)]),
                        b.file: snapshot([connection("both.md", .similar)])]
        let out = PaneSuggestions.rank(seeds: [a, b], evidence: evidence, recents: [], exclude: [a.file, b.file], launchers: 1)
        XCTAssertEqual(names(out[0]).first, "both.md")
        let both = out[0][0].score, one = out[0][1].score
        XCTAssertEqual(both, one + 0.8 * connection("both.md", .similar).strength, accuracy: 1e-9)
    }

    func testRecencyOnlyBreaksTies() {
        let seed = PaneSeed(file: ref("s.md"), weight: 1)
        let evidence = [seed.file: snapshot([connection("x.md", .similar), connection("y.md", .similar)])]
        let recents = [(file: ref("y.md"), score: 3.0), (file: ref("x.md"), score: 1.0)]
        let out = PaneSuggestions.rank(seeds: [seed], evidence: evidence, recents: recents, exclude: [], launchers: 1)
        XCTAssertEqual(names(out[0]), ["y.md", "x.md"])
    }

    func testFilesAlreadyShowingAreExcluded() {
        let seed = PaneSeed(file: ref("s.md"), weight: 1)
        let evidence = [seed.file: snapshot([connection("shown.md", .linked), connection("free.md", .similar)])]
        let recents = [(file: ref("shown.md"), score: 2.0), (file: ref("s.md"), score: 9.0)]
        let out = PaneSuggestions.rank(seeds: [seed], evidence: evidence, recents: recents, exclude: [seed.file, ref("shown.md")], launchers: 1)
        XCTAssertEqual(names(out[0]), ["free.md"])
    }

    func testLauncherBlocksNeverOverlap() {
        let seed = PaneSeed(file: ref("s.md"), weight: 1)
        let items = (0..<20).map { connection(String(format: "f%02d.md", $0), .similar, weight: Double(20 - $0) / 20) }
        let out = PaneSuggestions.rank(seeds: [seed], evidence: [seed.file: snapshot(items)], recents: [], exclude: [], launchers: 3)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0].count, 8); XCTAssertEqual(out[1].count, 8); XCTAssertEqual(out[2].count, 4)
        let all = out.flatMap(names)
        XCTAssertEqual(Set(all).count, all.count)
        XCTAssertEqual(names(out[0]).first, "f00.md"); XCTAssertEqual(names(out[1]).first, "f08.md")
    }

    func testWithNoSeedsPicksComeFromRecents() {
        let recents = (0..<10).map { (file: ref("r\($0).md"), score: Double(10 - $0)) }
        let out = PaneSuggestions.rank(seeds: [], evidence: [:], recents: recents, exclude: [], launchers: 2)
        XCTAssertEqual(names(out[0]), (0..<8).map { "r\($0).md" })
        XCTAssertEqual(names(out[1]), ["r8.md", "r9.md"])
        XCTAssertTrue(out[0].allSatisfy { $0.reasons.isEmpty }, "recency alone shows no reason glyph")
        XCTAssertTrue(PaneSuggestions.rank(seeds: [], evidence: [:], recents: recents, exclude: [], launchers: 0).isEmpty)
    }

    func testReasonsAreStrongestFirstAndAtMostTwo() {
        let seed = PaneSeed(file: ref("s.md"), weight: 1)
        let evidence = [ConnectionEvidence(reason: .together), ConnectionEvidence(reason: .similar), ConnectionEvidence(reason: .linked)]
        let c = FileConnection(file: ref("x.md"), anchor: nil, evidence: evidence, strength: FileConnections.strength(of: evidence))
        let out = PaneSuggestions.rank(seeds: [seed], evidence: [seed.file: snapshot([c])], recents: [], exclude: [], launchers: 1)
        XCTAssertEqual(out[0][0].reasons, [.linked, .similar])
        XCTAssertEqual(out[0][0].phrases.count, 2)
    }
}
