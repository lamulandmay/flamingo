import XCTest
import AppKit
import FlamingoCore
@testable import FlamingoGraph

@MainActor
final class GraphDeselectionTests: XCTestCase {
    private let graph = Graph(nodes: [
        .init(id: "a.md", name: "a", ext: "md"),
        .init(id: "b.md", name: "b", ext: "md"),
        .init(id: "folder/", name: "folder", ext: ""),
    ])

    private func model() -> GraphModel {
        GraphModel(fixedGraph: graph, positions: [.zero, .init(x: 40, y: 0), .init(x: 80, y: 0)])
    }

    private func key(_ code: UInt16) -> GraphKeyInput {
        let characters = code == GraphKeyCode.space ? " " : code == GraphKeyCode.escape ? "\u{1B}" : "\r"
        return GraphKeyInput(keyCode: code, characters: characters,
                             charactersIgnoringModifiers: characters, modifiers: [], isRepeat: false)
    }

    private func assertDeselected(_ model: GraphModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(model.selectedIndex, file: file, line: line)
        XCTAssertNil(model.selectionPath, file: file, line: line)
        XCTAssertTrue(model.chosenIDs.isEmpty, file: file, line: line)
        XCTAssertEqual(model.connectionMode, .browse, file: file, line: line)
        let frame = model.advance(to: CACurrentMediaTime(), canvasSize: CGSize(width: 400, height: 300))
        XCTAssertNil(frame.selected, file: file, line: line)
        XCTAssertNil(frame.pulse, file: file, line: line)
        XCTAssertTrue(frame.multiSelected.isEmpty, file: file, line: line)
    }

    func testSpaceClearsFileWithoutTypingOrOpeningAndUpdateDoesNotRestoreIt() {
        let model = model(), recognizer = GraphGestureRecognizer()
        recognizer.target = model
        var selections: [String?] = [], typed: [String] = [], opened: [String] = []
        var escapes = 0
        model.onType = { typed.append($0) }
        model.onEscape = { escapes += 1 }
        model.onSelect = { opened.append($0.relativePath) }
        model.setFilter("ext:md")
        let filter = model.filterMask
        model.click(0)
        model.onSelectionChange = { selections.append($0?.relativePath) }

        XCTAssertTrue(recognizer.keyDown(key(GraphKeyCode.space)))
        assertDeselected(model)
        XCTAssertEqual(selections, [nil])
        XCTAssertTrue(typed.isEmpty)
        XCTAssertEqual(escapes, 0)
        XCTAssertEqual(model.filterMask, filter)

        model.update(graph: Graph(nodes: graph.nodes.reversed()))
        assertDeselected(model)
        XCTAssertTrue(recognizer.keyDown(key(GraphKeyCode.returnKey)))
        XCTAssertTrue(opened.isEmpty)
    }

    func testEscapeClearsFolderBeforeDismissCallbackIncludingCancelOperation() {
        let model = model(), recognizer = GraphGestureRecognizer()
        recognizer.target = model
        var selections: [String?] = [], scopes: [String?] = []
        var escapes = 0
        model.onSelectionChange = { [unowned model] in
            selections.append($0?.relativePath)
            model.select($0) // The shell echoes its cleared file selection back to the graph.
        }
        model.onScopeChange = { scopes.append($0) }
        model.onEscape = { [unowned model] in
            escapes += 1
            XCTAssertNil(model.selectedIndex)
            XCTAssertNil(model.selectionPath)
        }

        for cancelOperation in [false, true] {
            model.click(2)
            XCTAssertEqual(model.selectionPath, "folder/")
            selections = []
            if cancelOperation { recognizer.escape() }
            else { XCTAssertTrue(recognizer.keyDown(key(GraphKeyCode.escape))) }
            assertDeselected(model)
            XCTAssertEqual(selections, [nil])
            XCTAssertTrue(recognizer.keyDown(key(GraphKeyCode.returnKey)))
        }
        XCTAssertEqual(escapes, 2)
        XCTAssertTrue(scopes.isEmpty)
    }

    func testBothKeysClearMultipleFilesAndConnectionModeWithoutRepublishingAFile() {
        for code in [GraphKeyCode.space, GraphKeyCode.escape] {
            for mode in [GraphModel.ConnectionMode.browse, .add, .remove] {
                let model = model(), recognizer = GraphGestureRecognizer()
                recognizer.target = model
                model.click(0)
                model.click(1, additive: true)
                model.setConnectionMode(mode)
                XCTAssertEqual(model.chosenIDs, ["a.md", "b.md"])
                var selections: [String?] = []
                model.onSelectionChange = { selections.append($0?.relativePath) }

                XCTAssertTrue(recognizer.keyDown(key(code)))
                assertDeselected(model)
                XCTAssertEqual(selections, [nil], "Deselecting must not briefly publish the last chosen file")
            }
        }
    }
}
