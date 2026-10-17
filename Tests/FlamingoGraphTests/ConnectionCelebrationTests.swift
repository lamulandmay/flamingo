import XCTest
import AppKit
import QuartzCore
import FlamingoCore
@testable import FlamingoDesign
@testable import FlamingoGraph

@MainActor
final class ConnectionCelebrationTests: XCTestCase {
    /// Set `FLAMINGO_WAV_OUT` to a folder to write the three notes there and listen.
    func testChimeNotesAreQuietCleanWAVs() throws {
        for (i, f) in Chime.frequencies.enumerated() {
            let data = Chime.wav(frequency: f)
            XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
            XCTAssertEqual(String(decoding: data[8..<16], as: UTF8.self), "WAVEfmt ")
            let samples = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            XCTAssertEqual(samples.count * 2 + 44, data.count)
            let peak = Double(samples.map { abs(Int($0)) }.max() ?? 0) / Double(Int16.max)
            XCTAssertLessThan(peak, 0.3, "louder than about −10 dBFS")
            XCTAssertGreaterThan(peak, 0.1)
            XCTAssertLessThan(abs(Int(samples.first!)), 200, "clicks at the start")
            XCTAssertLessThan(abs(Int(samples.last!)), 50, "clicks at the end")
            if let dir = ProcessInfo.processInfo.environment["FLAMINGO_WAV_OUT"] {
                try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("thought-note-\(i + 1).wav"))
            }
            XCTAssertNotNil(NSSound(data: data))
        }
    }

    func testBeatsAreInOrderAndShort() {
        XCTAssertLessThan(CelebrationTime.depart, CelebrationTime.arrive)
        XCTAssertLessThan(CelebrationTime.arrive, CelebrationTime.fadeStart(alone: false))
        XCTAssertLessThan(CelebrationTime.end(alone: true), CelebrationTime.end(alone: false))
        XCTAssertLessThan(CelebrationTime.end(alone: false), 3, "a celebration never holds the corner for long")
    }

    private let deck = FileRef(relativePath: "decks/q3.pptx")
    private let sheet = FileRef(relativePath: "finance/q3-model.xlsx")

    func testPiPNeighborhoodAddsTheNewLinkWhenTheGraphHasNotCaughtUp() {
        let graph = Graph(nodes: [.init(id: deck.relativePath, name: deck.name, ext: "pptx"),
                                  .init(id: "notes/a.md", name: "a.md", ext: "md")],
                          edges: [.init(source: deck.relativePath, target: "notes/a.md", kind: .mention)])
        let c = GraphCelebration(id: 1, source: deck, targets: [sheet], level: 2)
        let local = ConnectionPiP.neighborhood(c, in: graph)
        XCTAssertEqual(local.graph.nodes.first?.id, deck.relativePath, "the source is the center")
        XCTAssertTrue(local.graph.nodes.contains { $0.id == sheet.relativePath })
        XCTAssertTrue(local.graph.edges.contains { $0.kind == .link && $0.target == sheet.relativePath })
        XCTAssertEqual(local.positions.count, local.graph.nodes.count)
        XCTAssertEqual(local.center, 0)
    }

    func testPiPNeighborhoodWorksWithNoGraphAtAll() {
        let local = ConnectionPiP.neighborhood(GraphCelebration(id: 1, source: deck, targets: [sheet], level: 1), in: Graph())
        XCTAssertEqual(local.graph.nodes.map(\.id), [deck.relativePath, sheet.relativePath])
        XCTAssertEqual(local.graph.edges.count, 1)
        XCTAssertNotEqual(local.positions[0], local.positions[1])
    }

    func testPiPNeighborhoodDoesNotDuplicateAnExistingLink() {
        let graph = Graph(nodes: [.init(id: deck.relativePath, name: deck.name, ext: "pptx"),
                                  .init(id: sheet.relativePath, name: sheet.name, ext: "xlsx")],
                          edges: [.init(source: sheet.relativePath, target: deck.relativePath, kind: .link)])
        let local = ConnectionPiP.neighborhood(GraphCelebration(id: 1, source: deck, targets: [sheet], level: 1), in: graph)
        XCTAssertEqual(local.graph.edges.count, 1)
    }

    func testCelebrationDrawsTheLineThenEnds() {
        let local = ConnectionPiP.neighborhood(GraphCelebration(id: 1, source: deck, targets: [sheet], level: 2), in: Graph())
        let model = GraphModel(fixedGraph: local.graph, positions: local.positions)
        let size = CGSize(width: 320, height: 208)
        model.viewResized(to: size)
        var ended = false
        model.onCelebrationEnded = { ended = true }
        model.celebrate(from: deck, to: [sheet], level: 2, zoom: true)
        let t0 = CACurrentMediaTime()
        let first = model.advance(to: t0, canvasSize: size).celebration
        XCTAssertEqual(first?.from, 0)
        XCTAssertEqual(first?.to, [1])
        XCTAssertEqual(first?.level, 2)
        let mid = model.advance(to: t0 + CelebrationTime.arrive, canvasSize: size).celebration
        XCTAssertEqual(mid?.t ?? 0, CelebrationTime.arrive, accuracy: 1e-6)
        _ = model.advance(to: t0 + CelebrationTime.end(alone: false) + 0.01, canvasSize: size)
        XCTAssertNil(model.advance(to: t0 + CelebrationTime.end(alone: false) + 0.02, canvasSize: size).celebration)
        let done = expectation(description: "ended")
        DispatchQueue.main.async { XCTAssertTrue(ended); done.fulfill() }
        wait(for: [done], timeout: 1)
    }

    func testCelebrationOfFilesNotInTheGraphIsHandedBack() {
        let model = GraphModel(fixedGraph: Graph(nodes: [.init(id: "x.md", name: "x.md", ext: "md")]), positions: [.zero])
        let size = CGSize(width: 320, height: 208)
        model.viewResized(to: size)
        var missed: (FileRef, [FileRef], Int)?
        model.onCelebrationMissed = { missed = ($0, $1, $2) }
        model.celebrate(from: deck, to: [sheet], level: 1, zoom: true)
        XCTAssertNil(model.advance(to: CACurrentMediaTime(), canvasSize: size).celebration)
        XCTAssertNil(model.advance(to: CACurrentMediaTime() + GraphModel.celebrationWait + 0.1, canvasSize: size).celebration)
        let done = expectation(description: "missed")
        DispatchQueue.main.async {
            XCTAssertEqual(missed?.0, self.deck)
            XCTAssertEqual(missed?.1, [self.sheet])
            XCTAssertEqual(missed?.2, 1)
            done.fulfill()
        }
        wait(for: [done], timeout: 1)
    }
}
