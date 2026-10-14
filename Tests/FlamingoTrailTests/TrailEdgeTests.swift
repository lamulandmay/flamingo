import XCTest
import FlamingoCore
@testable import FlamingoTrail

final class TrailEdgeTests: XCTestCase {

    private func edges(_ events: [TrailEvent], now: Date? = nil, tuning: TrailTuning = TrailTuning()) -> [Graph.Edge] {
        let sessions = TrailClustering.sessions(from: events, tuning: tuning)
        return TrailClustering.edges(from: sessions, now: now ?? sessions.last?.end ?? trailBase, tuning: tuning)
    }

    private func pairs(_ edges: [Graph.Edge]) -> [[String]] { edges.map { [$0.source, $0.target] } }

    private func weight(_ edges: [Graph.Edge], _ a: String, _ b: String) -> Double? {
        let (s, t) = a < b ? (a, b) : (b, a)
        return edges.first { $0.source == s && $0.target == t }?.weight
    }

    private func assertWellFormed(_ edges: [Graph.Edge], file: StaticString = #filePath, line: UInt = #line) {
        for e in edges {
            XCTAssertLessThan(e.source, e.target, "source < target, no self edges", file: file, line: line)
            XCTAssertEqual(e.kind, .trail, file: file, line: line)
            XCTAssertGreaterThan(e.weight, 0, file: file, line: line)
        }
        let keys = edges.map { "\($0.source)\u{0}\($0.target)" }
        XCTAssertEqual(keys, keys.sorted(), "sorted by (source, target)", file: file, line: line)
        XCTAssertEqual(Set(keys).count, keys.count, "no duplicate pairs", file: file, line: line)
    }

    /// No decay: each session's vote is exactly 1.
    private var undecayed: TrailTuning { var t = TrailTuning(); t.decayDays = .greatestFiniteMagnitude; return t }

    // MARK: Small sessions

    func testThreeFileSessionIsAClique() {
        let e = edges(opens(["c.md", "a.md", "b.md"]))
        assertWellFormed(e)
        XCTAssertEqual(pairs(e), [["a.md", "b.md"], ["a.md", "c.md"], ["b.md", "c.md"]])
        XCTAssertEqual(e.map(\.weight), [1, 1, 1])
    }

    func testSingleFileAndSearchOnlySessionsHaveNoEdges() {
        XCTAssertEqual(edges(opens(["a.md"])), [])
        XCTAssertEqual(edges([ev(.searched, 0, text: "churn")]), [])
        XCTAssertEqual(edges([]), [])
    }

    func testRevisitsDoNotMakeSelfEdges() {
        let e = edges(opens(["a.md", "b.md", "a.md", "b.md", "a.md"]))
        XCTAssertEqual(pairs(e), [["a.md", "b.md"]])
        XCTAssertEqual(e[0].weight, 1, "one vote per session, however often the pair recurs")
    }

    func testCliqueLimitBoundary() {
        let six = (0..<6).map { "f\($0).md" }
        XCTAssertEqual(edges(opens(six)).count, 15)
        let seven = (0..<7).map { "f\($0).md" }
        let e = edges(opens(seven))
        assertWellFormed(e)
        XCTAssertEqual(pairs(e), (1..<7).map { ["f\($0 - 1).md", "f\($0).md"] })
    }

    func testPassThroughFilesGetNoEdges() {
        let stream = [ev(.opened, 0, file: "A"), ev(.opened, 1, file: "B"),
                      ev(.opened, 2, file: "C"), ev(.opened, 10, file: "D")]
        XCTAssertEqual(pairs(edges(stream)), [["C", "D"]])
    }

    func testSessionsDoNotConnectAcrossGaps() {
        let e = edges(opens(["a.md", "b.md"]) + opens(["c.md", "d.md"], from: 3600))
        XCTAssertEqual(pairs(e), [["a.md", "b.md"], ["c.md", "d.md"]])
    }

    // MARK: Large sessions

    func testFiftyFileSessionConnectsConsecutiveFilesOnly() {
        // Visit order is a permutation, so "consecutive" can't be confused with "sorted".
        let order = (0..<50).map { String(format: "f%02d.md", ($0 * 7) % 50) }
        let e = edges(opens(order))
        assertWellFormed(e)
        XCTAssertEqual(e.count, 49)
        let expected = Set((1..<50).map { i -> String in
            let (a, b) = order[i - 1] < order[i] ? (order[i - 1], order[i]) : (order[i], order[i - 1])
            return "\(a)|\(b)"
        })
        XCTAssertEqual(Set(e.map { "\($0.source)|\($0.target)" }), expected)
        XCTAssertTrue(e.allSatisfy { $0.weight == 1 })
    }

    func testCommentedFilesInLargeSessionAreConnected() {
        let files = (0..<10).map { "f\($0).md" }
        var stream = opens(files)
        stream += [ev(.commented, 11, file: "f1.md", text: "x"), ev(.commented, 51, file: "f5.md", text: "y"),
                   ev(.linked, 81, file: "f8.md", text: "f1.md")]
        let e = edges(stream)
        assertWellFormed(e)
        XCTAssertEqual(e.count, 9 + 3)
        for (a, b) in [("f1.md", "f5.md"), ("f1.md", "f8.md"), ("f5.md", "f8.md")] {
            XCTAssertNotNil(weight(e, a, b), "\(a) – \(b)")
        }
        XCTAssertNil(weight(e, "f0.md", "f5.md"))
    }

    func testOnlyTheMostCommentedFilesArePaired() {
        // 20 files; f00…f09 get 1…10 comments. The 5 most commented (f05…f09) pair up; the
        // rest only get their consecutive edges.
        let files = (0..<20).map { String(format: "f%02d.md", $0) }
        var stream = opens(files)
        for k in 0..<10 {
            for n in 0...k { stream.append(ev(.commented, 300 + Double(k * 20 + n), file: files[k], text: "c\(n)")) }
        }
        XCTAssertEqual(TrailTuning().maxCommentedFiles, 5)
        let e = edges(stream)
        assertWellFormed(e)
        XCTAssertNotNil(weight(e, "f05.md", "f09.md"))
        XCTAssertNotNil(weight(e, "f06.md", "f08.md"))
        XCTAssertNil(weight(e, "f04.md", "f09.md"))
        XCTAssertNil(weight(e, "f01.md", "f09.md"))
        XCTAssertNil(weight(e, "f02.md", "f05.md"))
        // 19 consecutive + C(5,2) commented pairs, minus the 4 consecutive ones among f05…f09.
        XCTAssertEqual(e.count, 19 + 10 - 4)
    }

    // MARK: Weights

    func testWeightDecaysWithAge() {
        let now = trailBase
        let week = edges(opens(["a.md", "b.md"], base: now.addingTimeInterval(-7 * 86_400)), now: now)
        let year = edges(opens(["c.md", "d.md"], base: now.addingTimeInterval(-365 * 86_400)), now: now)
        let w = week[0].weight, y = year[0].weight
        XCTAssertGreaterThan(w, y)
        XCTAssertEqual(w, 1 / (1 + 7.0 / 30), accuracy: 0.001)
        XCTAssertEqual(y, 1 / (1 + 365.0 / 30), accuracy: 0.001)
        XCTAssertEqual(edges(opens(["a.md", "b.md"], base: now), now: now)[0].weight, 1)
    }

    func testWeightSumsAcrossSessions() {
        let now = trailBase
        let stream = opens(["a.md", "b.md"], base: now.addingTimeInterval(-7 * 86_400))
            + opens(["b.md", "a.md"], base: now.addingTimeInterval(-365 * 86_400))
        let e = edges(stream, now: now)
        XCTAssertEqual(pairs(e), [["a.md", "b.md"]])
        XCTAssertEqual(e[0].weight, 1 / (1 + 7.0 / 30) + 1 / (1 + 365.0 / 30), accuracy: 0.002)
    }

    func testUndecayedWeightCountsSessions() {
        let stream = opens(["a.md", "b.md"]) + opens(["a.md", "b.md", "c.md"], from: 3600)
            + opens(["b.md", "a.md"], from: 7200)
        let e = edges(stream, tuning: undecayed)
        XCTAssertEqual(weight(e, "a.md", "b.md"), 3)
        XCTAssertEqual(weight(e, "a.md", "c.md"), 1)
        XCTAssertEqual(weight(e, "b.md", "c.md"), 1)
    }

    func testFutureSessionsDoNotGainWeight() {
        let e = edges(opens(["a.md", "b.md"]), now: trailBase.addingTimeInterval(-86_400))
        XCTAssertEqual(e[0].weight, 1)
    }

    // MARK: Per-file cap

    func testPerFileCapKeepsEdgesRankedHighByEitherEnd() {
        var t = TrailTuning()
        t.maxEdgesPerFile = 1
        // One clique, all weights equal: ties break by (source, target).
        let e = edges(opens(["a", "b", "c", "d"]), tuning: t)
        XCTAssertEqual(pairs(e), [["a", "b"], ["a", "c"], ["a", "d"]])
    }

    func testPerFileCapPrefersStrongerEdges() {
        var t = undecayed
        t.maxEdgesPerFile = 1
        // a–b in 3 sessions, b–c in 2, a–c in 1.
        let stream = opens(["a", "b"]) + opens(["a", "b"], from: 3600) + opens(["a", "b"], from: 7200)
            + opens(["b", "c"], from: 10_800) + opens(["b", "c"], from: 14_400)
            + opens(["a", "c"], from: 18_000)
        let e = edges(stream, tuning: t)
        XCTAssertEqual(pairs(e), [["a", "b"], ["b", "c"]])
        XCTAssertEqual(e.map(\.weight), [3, 2])
    }

    func testPerFileCapDoesNotThinConsecutiveChain() {
        var t = TrailTuning()
        t.maxEdgesPerFile = 2
        let e = edges(opens((0..<50).map { String(format: "f%02d.md", $0) }), tuning: t)
        XCTAssertEqual(e.count, 49)
    }

    func testDefaultCapPrunesADenseCluster() {
        // 20 files that all co-occur, as if every pair had been visited together.
        var t = TrailTuning()
        t.cliqueLimit = 20
        let files = (0..<20).map { String(format: "f%02d.md", $0) }
        let e = edges(opens(files), tuning: t)
        assertWellFormed(e)
        XCTAssertLessThan(e.count, 190)
        // Every surviving edge is in the top 12 of at least one of its ends.
        var byFile: [String: [Graph.Edge]] = [:]
        for x in e { byFile[x.source, default: []].append(x); byFile[x.target, default: []].append(x) }
        for file in files {
            let ranked = files.filter { $0 != file }.map { o in file < o ? "\(file)|\(o)" : "\(o)|\(file)" }.sorted()
            let top = Set(ranked.prefix(12))
            for x in byFile[file] ?? [] {
                let key = "\(x.source)|\(x.target)"
                let other = x.source == file ? x.target : x.source
                let otherTop = Set(files.filter { $0 != other }.map { o in other < o ? "\(other)|\(o)" : "\(o)|\(other)" }.sorted().prefix(12))
                XCTAssertTrue(top.contains(key) || otherTop.contains(key), key)
            }
        }
    }
}
