import XCTest
import FlamingoCore
@testable import FlamingoGraph

final class TopologyTests: XCTestCase {
    func testDedupAndRadius() {
        let g = Graph(nodes: [.init(id: "a.pptx", name: "a.pptx", ext: "pptx", commentCount: 2),
                              .init(id: "b.xlsx", name: "b.xlsx", ext: "xlsx"),
                              .init(id: "a.pptx", name: "dup", ext: "")],
                      edges: [.init(source: "a.pptx", target: "b.xlsx", kind: .link),
                              .init(source: "b.xlsx", target: "a.pptx", kind: .link),
                              .init(source: "a.pptx", target: "b.xlsx", kind: .trail),
                              .init(source: "a.pptx", target: "a.pptx", kind: .link),
                              .init(source: "a.pptx", target: "missing", kind: .link)])
        let t = GraphTopology(g)
        XCTAssertEqual(t.count, 2)
        XCTAssertEqual(t.labels, ["a", "b"])
        // One edge per pair: the link (strongest kind) carries all three weights.
        XCTAssertEqual(t.edges.count, 1)
        XCTAssertEqual(t.edges.first?.kind, .link)
        XCTAssertEqual(t.edges.first?.weight, 3)
        XCTAssertEqual(t.neighbors, [[1], [0]])
        XCTAssertEqual(t.radius[0], 3 + log(4), accuracy: 1e-9)
    }

    func testPairDrawsAsItsStrongestKind() {
        let g = Graph(nodes: [.init(id: "a.md", name: "a.md", ext: "md"), .init(id: "b.md", name: "b.md", ext: "md"),
                              .init(id: "c.md", name: "c.md", ext: "md"), .init(id: "d/", name: "d", ext: "")],
                      edges: [.init(source: "a.md", target: "b.md", kind: .trail),
                              .init(source: "b.md", target: "a.md", kind: .mention),
                              .init(source: "a.md", target: "c.md", kind: .related),
                              .init(source: "c.md", target: "a.md", kind: .manual),
                              .init(source: "d/", target: "b.md", kind: .folder)])
        let t = GraphTopology(g)
        let kinds = Dictionary(uniqueKeysWithValues: t.edges.map { ([t.ids[$0.a], t.ids[$0.b]].sorted().joined(separator: "-"), $0) })
        XCTAssertEqual(kinds["a.md-b.md"]?.kind, .mention)
        XCTAssertEqual(kinds["a.md-b.md"]?.strokeClass, 1)
        XCTAssertEqual(kinds["a.md-c.md"]?.kind, .manual)
        XCTAssertEqual(kinds["a.md-c.md"]?.strokeClass, 0)
        XCTAssertEqual(kinds["b.md-d/"]?.strokeClass, 2)
    }

    func testCameraRoundTripAndZoomAnchor() {
        var c = GraphCamera(center: CGPoint(x: 10, y: -5), zoom: 1.5)
        let size = CGSize(width: 800, height: 600)
        let s = CGPoint(x: 123, y: 456)
        let w = c.toWorld(s, size: size)
        let back = c.toScreen(w, size: size)
        XCTAssertEqual(back.x, s.x, accuracy: 1e-9); XCTAssertEqual(back.y, s.y, accuracy: 1e-9)
        c.zoom(by: 2, around: s, size: size)
        let w2 = c.toWorld(s, size: size)
        XCTAssertEqual(w2.x, w.x, accuracy: 1e-9); XCTAssertEqual(w2.y, w.y, accuracy: 1e-9)
        XCTAssertEqual(c.zoom, 3, accuracy: 1e-9)
    }
}
