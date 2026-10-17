import XCTest
import SwiftUI
import FlamingoCore
@testable import FlamingoGraph

@MainActor
final class GraphDetailTests: XCTestCase {
    private let canvasSize = CGSize(width: 360, height: 240)

    private func node(_ id: String) -> Graph.Node {
        let path = id.hasSuffix("/") ? String(id.dropLast()) : id
        return .init(id: id, name: id == "/" ? "Vault" : (path as NSString).lastPathComponent,
                     ext: id.hasSuffix("/") ? "" : (path as NSString).pathExtension)
    }

    private func folderIDs() -> [String] {
        ["/", "hub/"] + (0..<18).map { "hub/branch-\($0)/" }
            + ["hub/branch-0/deep/deeper/deepest/", "file.md"]
    }

    func testRevealIsContinuousMonotonicAndCompleteAtMaximumZoom() {
        let ids = folderIDs()
        let thresholds = GraphDetail.revealZooms(ids: ids)
        XCTAssertEqual(thresholds.count, ids.count)
        XCTAssertEqual(thresholds[0], 0, "The root stays visible at overview scale")
        XCTAssertEqual(thresholds.last, 0, "File visibility is not changed by folder detail")
        XCTAssertTrue(thresholds.contains { $0 > 0 })
        for threshold in thresholds {
            XCTAssertTrue(threshold.isFinite)
            XCTAssertLessThanOrEqual(threshold, 2.5)
            var previous = -1.0
            for step in 0...200 {
                let zoom = GraphCamera.zoomRange.lowerBound
                    + CGFloat(step) / 200 * (GraphCamera.zoomRange.upperBound - GraphCamera.zoomRange.lowerBound)
                let opacity = GraphDetail.opacity(revealZoom: threshold, zoom: zoom)
                XCTAssertGreaterThanOrEqual(opacity, previous)
                XCTAssertTrue((0...1).contains(opacity))
                previous = opacity
            }
            XCTAssertEqual(previous, 1)
            if threshold > 0 {
                XCTAssertEqual(GraphDetail.opacity(revealZoom: threshold, zoom: threshold), 0.5, accuracy: 0.000001)
                let before = GraphDetail.opacity(revealZoom: threshold, zoom: threshold * 0.9999)
                let after = GraphDetail.opacity(revealZoom: threshold, zoom: threshold * 1.0001)
                XCTAssertLessThan(after - before, 0.001, "A small magnification must not pop a folder into view")
            }
        }
    }

    func testRevealThresholdsAreDeterministicAcrossNodeReordering() {
        let ids = folderIDs()
        let original = Dictionary(uniqueKeysWithValues: zip(ids, GraphDetail.revealZooms(ids: ids)))
        let reordered = Array(ids.reversed())
        let reversed = Dictionary(uniqueKeysWithValues: zip(reordered, GraphDetail.revealZooms(ids: reordered)))
        XCTAssertEqual(original, reversed)
        let scoped = ["parent/scope/"] + (0..<18).map { "parent/scope/child-\($0)/" }
        XCTAssertEqual(GraphDetail.revealZooms(ids: scoped)[0], 0, "The displayed scope is the shallowest visible level")
    }

    func testSmallFolderGraphsStayVisibleAtEveryZoom() {
        let ids = ["/"] + (0..<11).map { "folder-\($0)/nested/" } + ["file.md"]
        let thresholds = GraphDetail.revealZooms(ids: ids)
        XCTAssertEqual(thresholds, Array(repeating: 0, count: ids.count))
        XCTAssertTrue(thresholds.allSatisfy {
            GraphDetail.opacity(revealZoom: $0, zoom: GraphCamera.zoomRange.lowerBound) == 1
        })
    }

    private func frame(_ graph: Graph, positions: [CGPoint], opacity: [Double], labels: Double = 0) -> GraphFrame {
        var frame = GraphFrame(topology: GraphTopology(graph), positions: positions,
                               camera: .init(center: .zero, zoom: 2), selected: nil, hovered: nil,
                               hoverAmount: 0, filterMask: nil, labelAmount: labels, pinned: [], dragging: nil)
        frame.detailOpacity = opacity
        return frame
    }

    private func render(_ frame: GraphFrame) throws -> (bitmap: NSBitmapImageRep, stats: GraphRenderer.Stats) {
        let renderer = GraphRenderer()
        let canvas = Canvas { context, size in renderer.draw(frame, in: &context, size: size) }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .environment(\.colorScheme, .dark)
        let image = try XCTUnwrap(ImageRenderer(content: canvas).cgImage)
        return (NSBitmapImageRep(cgImage: image), renderer.stats)
    }

    private func rgb(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> [Double] {
        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        return [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)]
    }

    private func contrast(_ bitmap: NSBitmapImageRep, in rect: CGRect) throws -> Double {
        let background = try rgb(bitmap, x: 4, y: 4)
        var sum = 0.0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let color = try rgb(bitmap, x: x, y: y)
                sum += zip(color, background).reduce(0) { $0 + abs($1.0 - $1.1) }
            }
        }
        return sum
    }

    func testHiddenFolderHasNoNodeEdgeOrLabelEvenAsHoveredNeighbor() throws {
        let graph = Graph(nodes: [node("hidden/"), node("file.md")],
                          edges: [.init(source: "hidden/", target: "file.md", kind: .folder)])
        var hidden = frame(graph, positions: [.init(x: -55, y: 0), .init(x: 55, y: 0)], opacity: [0, 1], labels: 1)
        hidden.hovered = 1
        hidden.hoverAmount = 1
        let result = try render(hidden)
        XCTAssertEqual(result.stats.visibleNodes, 1)
        XCTAssertEqual(result.stats.drawnEdges, 0)
        XCTAssertEqual(result.stats.labels, 1, "Priority neighbor labels must obey the same visibility as their nodes")
        XCTAssertEqual(try contrast(result.bitmap, in: CGRect(x: 55, y: 105, width: 30, height: 30)), 0, accuracy: 0.001)
        hidden.detailOpacity = [1, 1]
        let revealed = try render(hidden)
        XCTAssertEqual(revealed.stats.visibleNodes, 2)
        XCTAssertEqual(revealed.stats.drawnEdges, 1)
        XCTAssertEqual(revealed.stats.labels, 2)
    }

    func testEmergingFolderFadesAndMagnifiesWhileItsCenterStaysHollow() throws {
        let graph = Graph(nodes: [node("folder/")])
        let partial = try render(frame(graph, positions: [.zero], opacity: [0.25]))
        let full = try render(frame(graph, positions: [.zero], opacity: [1]))
        let region = CGRect(x: 165, y: 105, width: 30, height: 30)
        let partialContrast = try contrast(partial.bitmap, in: region)
        let fullContrast = try contrast(full.bitmap, in: region)
        XCTAssertGreaterThan(partialContrast, 0)
        XCTAssertLessThan(partialContrast, fullContrast)
        for bitmap in [partial.bitmap, full.bitmap] {
            let center = try rgb(bitmap, x: 180, y: 120)
            let background = try rgb(bitmap, x: 4, y: 4)
            for (actual, expected) in zip(center, background) { XCTAssertEqual(actual, expected, accuracy: 0.001) }
        }
        let partialRadius = GraphRenderer.screenRadius(worldRadius: 4.5, zoom: 2, detailOpacity: 0.25, isFolder: true)
        let fullRadius = GraphRenderer.screenRadius(worldRadius: 4.5, zoom: 2, detailOpacity: 1, isFolder: true)
        XCTAssertLessThan(partialRadius, fullRadius)
    }

    func testContainmentEdgeFadesWithItsEmergingFolder() throws {
        let graph = Graph(nodes: [node("folder/"), node("file.md")],
                          edges: [.init(source: "folder/", target: "file.md", kind: .folder)])
        let positions = [CGPoint(x: -55, y: 0), CGPoint(x: 55, y: 0)]
        let partial = try render(frame(graph, positions: positions, opacity: [0.25, 1]))
        let full = try render(frame(graph, positions: positions, opacity: [1, 1]))
        let middle = CGRect(x: 130, y: 116, width: 100, height: 8)
        XCTAssertEqual(partial.stats.drawnEdges, 1)
        XCTAssertGreaterThan(try contrast(partial.bitmap, in: middle), 0)
        XCTAssertLessThan(try contrast(partial.bitmap, in: middle), try contrast(full.bitmap, in: middle))
    }

    private func fixedModel() -> GraphModel {
        let ids = folderIDs()
        var positions = ids.indices.map { CGPoint(x: -1000, y: CGFloat(1000 + $0 * 100)) }
        positions[0] = .zero
        positions[1] = CGPoint(x: 600, y: 0)
        positions[ids.count - 1] = CGPoint(x: 1200, y: 0)
        let model = GraphModel(fixedGraph: Graph(nodes: ids.map(node)), positions: positions)
        model.viewResized(to: canvasSize)
        model.camera = .init(center: .zero, zoom: GraphCamera.zoomRange.lowerBound)
        return model
    }

    func testHitTestingAndArrowNavigationSkipHiddenFoldersUntilRevealed() {
        let model = fixedModel()
        let hidden = 1
        let hiddenPoint = model.camera.toScreen(model.positions[hidden], size: canvasSize)
        XCTAssertLessThan(model.detailOpacity(for: hidden), GraphDetail.visibilityCutoff)
        XCTAssertNil(model.node(atScreen: hiddenPoint))
        model.select(FileRef(relativePath: "/"))
        model.moveSelection(.right)
        XCTAssertEqual(model.selectionPath, "file.md", "Arrow navigation must not enter an invisible folder")
        model.select(FileRef(relativePath: "/"))
        model.camera = .init(center: model.positions[hidden], zoom: GraphCamera.zoomRange.upperBound)
        XCTAssertEqual(model.node(atScreen: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)), hidden)
        model.moveSelection(.right)
        XCTAssertEqual(model.selectionPath, "hub/")
    }

    func testSelectionSearchAndDragOverrideOverviewHiding() {
        let model = fixedModel()
        let hidden = 1
        XCTAssertEqual(model.detailOpacity(for: hidden), 0)
        model.select(FileRef(relativePath: "hub/"))
        XCTAssertEqual(model.detailOpacity(for: hidden), 1)
        XCTAssertEqual(model.node(atScreen: model.camera.toScreen(model.positions[hidden], size: canvasSize)), hidden)
        model.select(FileRef(relativePath: "file.md"))
        XCTAssertEqual(model.detailOpacity(for: hidden), 0)
        model.setFilter("hub/")
        XCTAssertEqual(model.detailOpacity(for: hidden), 1)
        model.setFilter("")
        XCTAssertEqual(model.detailOpacity(for: hidden), 0)
        model.beginNodeDrag(hidden)
        XCTAssertEqual(model.detailOpacity(for: hidden), 1)
        model.endNodeDrag(hidden)
        XCTAssertEqual(model.detailOpacity(for: hidden), 0)
    }

    func testZoomDoesNotReplaceTopologyOrMoveSettledPositions() {
        let model = fixedModel()
        let token = model.topology.token
        let positions = model.positions
        let low = model.advance(to: 10, canvasSize: canvasSize)
        model.camera = .init(center: .zero, zoom: GraphCamera.zoomRange.upperBound)
        let high = model.advance(to: 11, canvasSize: canvasSize)
        XCTAssertEqual(model.topology.token, token)
        XCTAssertEqual(low.positions, positions)
        XCTAssertEqual(high.positions, positions)
        XCTAssertLessThan(low.detailOpacity[1], high.detailOpacity[1])
        model.camera = .init(center: .zero, zoom: GraphCamera.zoomRange.lowerBound)
        let returned = model.advance(to: 12, canvasSize: canvasSize)
        XCTAssertEqual(returned.detailOpacity, low.detailOpacity)
        XCTAssertEqual(model.topology.token, token)
        XCTAssertEqual(model.positions, positions)
    }

    func testPinnedFolderRemainsVisibleAfterDragEndsAtOverviewScale() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("graph-detail-pin-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = GraphModel(graph: Graph(nodes: folderIDs().map(node)), vault: Vault(root: root))
        model.suspend()
        defer { model.suspend() }
        model.viewResized(to: canvasSize)
        model.camera = .init(center: .zero, zoom: GraphCamera.zoomRange.lowerBound)
        XCTAssertEqual(model.detailOpacity(for: 1), 0)
        model.beginNodeDrag(1)
        model.endNodeDrag(1)
        XCTAssertTrue(model.isPinned(1))
        XCTAssertEqual(model.detailOpacity(for: 1), 1)
        model.unpin(1)
        XCTAssertFalse(model.isPinned(1))
        XCTAssertEqual(model.detailOpacity(for: 1), 0)
    }

    func testScopedFolderCatalogSurvivesFileBudgetAndKeepsOutsideRelationships() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("graph-detail-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scope"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("scope/a.md"))
        let folderPaths = (0..<20).map { "scope/branch-\($0)/nested/" }
        let relation = Graph.Edge(source: "scope/a.md", target: "outside/related.md", kind: .link)
        let graph = Graph(nodes: [node("scope/a.md"), node("outside/related.md"), node("unrelated/")]
                          + folderPaths.map(node), edges: [relation])
        let result = GraphModel.scopedResult(graph, to: "scope", in: Vault(root: root), budget: 1,
                                            including: ["scope/a.md"])
        let ids = Set(result.graph.nodes.map(\.id))
        XCTAssertTrue(result.truncated)
        XCTAssertTrue(ids.contains("scope/"))
        XCTAssertTrue(Set(folderPaths).isSubset(of: ids), "Known folders remain discoverable after file enumeration reaches its budget")
        XCTAssertTrue(ids.contains("scope/branch-19/"), "Missing ancestors are synthesized inside the scope")
        XCTAssertTrue(ids.contains("outside/related.md"))
        XCTAssertTrue(result.graph.edges.contains(relation))
        XCTAssertFalse(ids.contains("unrelated/"))
        XCTAssertFalse(ids.contains("/"), "A scoped graph must not regain the outer vault root")
        XCTAssertTrue(result.graph.edges.allSatisfy { ids.contains($0.source) && ids.contains($0.target) })
    }
}
