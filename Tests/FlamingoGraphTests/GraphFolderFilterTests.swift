import XCTest
import FlamingoCore
@testable import FlamingoGraph

final class GraphFolderFilterTests: XCTestCase {
    private func node(_ id: String) -> Graph.Node {
        .init(id: id, name: (id as NSString).lastPathComponent,
              ext: id.hasSuffix("/") ? "" : (id as NSString).pathExtension)
    }

    private func matches(_ query: String, in topology: GraphTopology) -> Set<String> {
        let mask = GraphFilter(query).mask(for: topology) ?? Array(repeating: true, count: topology.count)
        return Set(topology.ids.indices.filter { mask[$0] }.map { topology.ids[$0] })
    }

    func testFolderContainmentKeepsUnrelatedFilesInOrphanResults() {
        let graph = GraphFolders.addingAncestors(to: Graph(nodes: [node("notes/alone.md"), node("image.png")]))
        let topology = GraphTopology(graph)
        XCTAssertTrue(topology.neighbors.allSatisfy { !$0.isEmpty }, "The enriched graph contains parent edges")
        XCTAssertEqual(matches("orphans", in: topology), ["notes/alone.md", "image.png"])
        XCTAssertTrue(matches("orphans", in: GraphTopology(Graph(nodes: [node("empty/")]))).isEmpty,
                      "Folders are not orphan files even when they have no containment edges")
    }

    func testEveryNonContainmentRelationshipExcludesBothEndpoints() {
        for kind: Graph.Edge.Kind in [.link, .trail, .mention, .manual] {
            let graph = GraphFolders.addingAncestors(to: Graph(
                nodes: [node("notes/a.md"), node("notes/b.md"), node("notes/alone.md")],
                edges: [.init(source: "notes/a.md", target: "notes/b.md", kind: kind)]))
            XCTAssertEqual(matches("orphans", in: GraphTopology(graph)), ["notes/alone.md"], "Relationship: \(kind)")
        }
    }

    func testOrphanConjunctionPreservesTextAndExtensionFilters() {
        let graph = GraphFolders.addingAncestors(to: Graph(
            nodes: [node("notes/alone.md"), node("notes/image.png"), node("other/alone.md"), node("notes/linked.md")],
            edges: [.init(source: "notes/linked.md", target: "notes/image.png", kind: .link)]))
        let topology = GraphTopology(graph)
        XCTAssertEqual(matches("orphans ext:md NOTES", in: topology), ["notes/alone.md"])
        XCTAssertEqual(matches("ext:md notes", in: topology), ["notes/alone.md", "notes/linked.md"])
        XCTAssertTrue(matches("notes", in: topology).contains("notes/"), "Ordinary path queries still include folders")
    }
}
