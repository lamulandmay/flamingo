import XCTest
import FlamingoCore
@testable import Flamingo

final class GraphFolderCatalogTests: XCTestCase {
    private func file(_ path: String, comments: Int = 0) -> Graph.Node {
        let ref = FileRef(relativePath: path)
        return Graph.Node(id: path, name: ref.name, ext: ref.ext, commentCount: comments)
    }

    func testFoldersOfDroppedOrphansRemainWhileFilesStayCapped() {
        let orphans = (0...VaultSession.orphanLimit).map { file("Archive/Year/unused-\($0).txt") }
        let kept = [file("Work/thought.md", comments: 1), file("Work/source.txt"), file("Elsewhere/target.txt")]
        let relationships: [Graph.Edge] = [.init(source: kept[1].id, target: kept[2].id, kind: .manual, weight: 3),
                                          .init(source: kept[2].id, target: kept[0].id, kind: .trail, weight: 2),
                                          .init(source: kept[0].id, target: kept[1].id, kind: .link)]
        let graph = VaultSession.drawable(Graph(nodes: orphans + kept, edges: relationships))
        let ids = Set(graph.nodes.map(\.id))

        XCTAssertEqual(Set(graph.nodes.filter { !$0.id.hasSuffix("/") }.map(\.id)), Set(kept.map(\.id)))
        XCTAssertTrue(ids.isSuperset(of: ["/", "Archive/", "Archive/Year/", "Work/", "Elsewhere/"]))
        XCTAssertEqual(graph.edges.filter { $0.kind != .folder }, relationships)
        XCTAssertTrue(graph.edges.allSatisfy { ids.contains($0.source) && ids.contains($0.target) })
        XCTAssertTrue(graph.edges.contains { $0.kind == .folder && $0.source == "Archive/" && $0.target == "Archive/Year/" })
        XCTAssertFalse(graph.edges.contains { $0.target.hasPrefix("Archive/Year/unused-") })
    }

    func testOrphanLimitCountsFilesAndContainmentDoesNotRetainOrphans() {
        let files = (0..<VaultSession.orphanLimit).map { file("folder-\($0)/file.txt") }
        let expanded = GraphFolders.addingAncestors(to: Graph(nodes: files))
        let atLimit = VaultSession.drawable(expanded)
        XCTAssertEqual(atLimit.nodes.filter { !$0.id.hasSuffix("/") }.count, VaultSession.orphanLimit)

        var aboveLimit = expanded
        aboveLimit.nodes.append(file("last-folder/last-file.txt"))
        let trimmed = VaultSession.drawable(aboveLimit)
        XCTAssertTrue(trimmed.nodes.allSatisfy { $0.id.hasSuffix("/") })
        XCTAssertEqual(trimmed.nodes.count, VaultSession.orphanLimit + 2)
        let ids = Set(trimmed.nodes.map(\.id))
        XCTAssertTrue(trimmed.edges.allSatisfy { ids.contains($0.source) && ids.contains($0.target) })
    }

    func testCatalogIsStableIdempotentAndDoesNotDuplicateExistingFolders() {
        let folder = Graph.Node(id: "Projects/", name: "Projects", ext: "", commentCount: 2)
        let graph = Graph(nodes: [folder, file("Projects/Research/result.md"), file("Projects/notes.txt")],
                          edges: [.init(source: folder.id, target: "Projects/notes.txt", kind: .folder)])
        let first = GraphFolders.addingAncestors(to: graph)
        XCTAssertEqual(GraphFolders.addingAncestors(to: first), first)
        XCTAssertEqual(first.nodes.count, Set(first.nodes.map(\.id)).count)
        XCTAssertEqual(first.nodes.first(where: { $0.id == folder.id }), folder)
        XCTAssertEqual(first.edges.filter { $0.kind == .folder }.count, 4)

        let sources = [file("Hidden/B/two.txt"), file("Hidden/A/one.txt")]
        XCTAssertEqual(GraphFolders.addingAncestors(to: graph, from: sources),
                       GraphFolders.addingAncestors(to: graph, from: Array(sources.reversed())))
    }

    func testExplicitSourceFolderNodesSurviveWithoutFiles() {
        let source = Graph.Node(id: "Empty/Deep/", name: "Deep", ext: "", commentCount: 1)
        let graph = GraphFolders.addingAncestors(to: Graph(), from: [source])
        XCTAssertEqual(graph.nodes.map(\.id), ["/", "Empty/", "Empty/Deep/"])
        XCTAssertEqual(graph.nodes.last, source)
        XCTAssertEqual(graph.edges.map(\.source), ["/", "Empty/"])
        XCTAssertEqual(graph.edges.map(\.target), ["Empty/", "Empty/Deep/"])
    }

    @MainActor
    func testAnUnchangedRebuildIsNotPublished() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flamingo-graph-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = Vault(root: root)
        let a = FileRef(relativePath: "notes/a.txt"), b = FileRef(relativePath: "b.txt")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try Data("alpha words".utf8).write(to: vault.url(for: a))
        try Data("beta words".utf8).write(to: vault.url(for: b))
        let session = VaultSession(vault: vault)
        defer { session.stop() }
        _ = await session.update([a, b])

        let built = await session.buildGraph()
        let first = try XCTUnwrap(built)
        XCTAssertTrue(first.nodes.contains { $0.id == "notes/" })
        let again = await session.buildGraph()
        XCTAssertNil(again, "the same graph again is not published")

        _ = try session.connections.setConnections(between: [a, b], connected: true)
        let rebuilt = await session.buildGraph()
        let connected = try XCTUnwrap(rebuilt)
        XCTAssertTrue(connected.edges.contains { $0.kind == .manual })
        let unchanged = await session.buildGraph()
        XCTAssertNil(unchanged)
    }

    func testSyntheticAndUnsafePathsDoNotInventFolders() {
        let invalid = ["_inbox/2026-10-15", "_inbox/deeper/note", ".flamingo/notes/source.md", "/outside/file.txt",
                       "../outside/file.txt", "safe/../outside/file.txt", "safe/./file.txt", "safe//file.txt",
                       "", "bad\0name/file.txt", "https://example.com/note"]
        let graph = Graph(nodes: invalid.map { file($0, comments: 1) })
        XCTAssertEqual(GraphFolders.addingAncestors(to: graph), graph)
        let real = GraphFolders.addingAncestors(to: Graph(nodes: graph.nodes + [file("Research/_inbox-notes/report.md")]))
        XCTAssertEqual(Set(real.nodes.filter { $0.id.hasSuffix("/") }.map(\.id)),
                       ["/", "Research/", "Research/_inbox-notes/"])
    }
}
