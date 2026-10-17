import Combine
import XCTest
@testable import Flamingo
import FlamingoCore
import FlamingoExtract
import FlamingoIndex

@MainActor
final class UnifiedSearchUITests: XCTestCase {
    func testPreviewResolvesTheExactAnchorKindAndValue() {
        let sections = [
            Section(anchor: .init(kind: .slide, value: "2"), text: "Revised budget slide"),
            Section(anchor: .init(kind: .page, value: "2"), text: "PDF second page"),
            Section(anchor: .init(kind: .sheet, value: "Budget"), text: "Budget sheet"),
            Section(anchor: .init(kind: .cell, value: "Budget!B12"), text: "Revenue: 42"),
        ]
        for section in sections {
            XCTAssertEqual(SearchExactPreview.resolve(anchor: section.anchor, sections: sections, text: "whole document"), section)
        }
        XCTAssertNil(SearchExactPreview.resolve(anchor: .init(kind: .slide, value: "9"), sections: sections, text: "whole document"),
                     "A missing slide must not silently show the first page or whole document.")
        XCTAssertNil(SearchExactPreview.resolve(anchor: .init(kind: .cell, value: "Forecast!B12"), sections: sections, text: "whole document"))
    }

    func testLinePreviewFindsContainingSectionWithoutJumpingAcrossGaps() {
        let beginning = Section(anchor: .init(kind: .line, value: "1"), text: "one\ntwo\nthree")
        let later = Section(anchor: .init(kind: .line, value: "10"), text: "ten\neleven\ntwelve")
        let sections = [later, beginning]
        XCTAssertEqual(SearchExactPreview.resolve(anchor: .init(kind: .line, value: "2"), sections: sections, text: ""), beginning)
        XCTAssertEqual(SearchExactPreview.resolve(anchor: .init(kind: .line, value: "12"), sections: sections, text: ""), later)
        for line in ["0", "4", "9", "13", "not-a-line"] {
            XCTAssertNil(SearchExactPreview.resolve(anchor: .init(kind: .line, value: line), sections: sections, text: ""))
        }
    }

    func testUnsectionedTextFallbackRequiresAnExistingLine() {
        let text = "first\nsecond\nthird"
        let resolved = SearchExactPreview.resolve(anchor: .init(kind: .line, value: "3"), sections: [], text: text)
        XCTAssertEqual(resolved?.text, text)
        XCTAssertEqual(resolved?.anchor, .init(kind: .line, value: "1"))
        XCTAssertNil(SearchExactPreview.resolve(anchor: .init(kind: .line, value: "4"), sections: [], text: text))
        XCTAssertNil(SearchExactPreview.resolve(anchor: .init(kind: .slide, value: "1"), sections: [], text: text))
    }

    func testSemanticRefreshPreservesSelectedFileAndUsesItsNewEvidence() {
        let model = PaletteModel()
        let first = result("first.pdf"), selected = result("selected.pdf"), later = result("later.pdf")
        model.setItems([.result(first), .result(selected)])
        model.select(1)
        let newHit = SearchHit(file: selected.file, anchor: .page(7), snippet: "new semantic evidence", score: 4)
        var enhanced = selected
        enhanced.hits = [newHit]
        model.setItems([.result(enhanced), .result(later), .result(first)], preservingSelection: true)
        XCTAssertEqual(model.highlight, 0)
        XCTAssertEqual(model.selectedResult?.file, selected.file)
        XCTAssertEqual(model.selectedResult?.hits, [newHit])
        var opened: PaletteItem?
        model.onRun = { item, _ in opened = item }
        model.runHighlighted(externally: false)
        guard case .result(let openedResult) = opened else { return XCTFail("Selected result was not opened") }
        XCTAssertEqual(openedResult.hits.first?.anchor, .page(7))
    }

    func testSelectionFallsBackWhenRemovedAndCannotRunAnEmptyList() {
        let model = PaletteModel()
        let first = result("first.pdf"), second = result("second.pdf")
        model.setItems([.result(first), .result(second)])
        model.select(1)
        model.setItems([.result(first), .result(first)], preservingSelection: true)
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.selectedResult?.file, first.file)
        model.moveHighlight(100)
        XCTAssertEqual(model.highlight, 0)
        var calls = 0
        model.onRun = { _, _ in calls += 1 }
        model.setItems([])
        model.moveHighlight(-1)
        model.jumpHighlight(toEnd: true)
        model.runHighlighted(externally: true)
        XCTAssertNil(model.selectedResult)
        XCTAssertEqual(calls, 0)
    }

    func testNewQueryResetsSelectionInsteadOfPreservingOldRank() {
        let model = PaletteModel()
        let first = result("first.pdf"), second = result("second.pdf")
        model.setItems([.result(first), .result(second)])
        model.select(1)
        model.setItems([.result(first), .result(second)])
        XCTAssertEqual(model.highlight, 0)
        model.select(-1)
        model.select(100)
        XCTAssertEqual(model.highlight, 0)
        model.moveHighlight(1)
        model.moveHighlight(1)
        XCTAssertEqual(model.highlight, 1)
        model.jumpHighlight(toEnd: false)
        XCTAssertEqual(model.highlight, 0)
    }

    func testSidebarRejectsAnOlderSuccessfulResponseAfterNewQueryCompletes() async throws {
        try await verifyStaleSidebarResponse(.success(.init(results: [result("obsolete.pdf")], notice: "obsolete notice")))
    }

    func testSidebarRejectsAnOlderFailureAfterNewQueryCompletes() async throws {
        try await verifyStaleSidebarResponse(.failure(CocoaError(.fileReadUnknown)))
    }

    private func verifyStaleSidebarResponse(_ obsolete: Result<UnifiedSearchResponse, Error>) async throws {
        let model = SidebarSearchModel()
        let gate = DeferredSearch()
        let oldStarted = expectation(description: "Old search started")
        let newStarted = expectation(description: "New search started")
        let oldReturned = expectation(description: "Cancelled search eventually returned")
        let newPublished = expectation(description: "Current results published")
        gate.onStart = { query in (query == "old" ? oldStarted : newStarted).fulfill() }
        gate.onReturn = { query in if query == "old" { oldReturned.fulfill() } }
        model.runUnified = { query in try await gate.search(query) }
        let publication = model.$groups.dropFirst().sink { groups in
            if groups.map(\.file.relativePath) == ["current.pdf"] { newPublished.fulfill() }
        }
        model.query = "old"
        await fulfillment(of: [oldStarted], timeout: 3)
        model.query = "new"
        await fulfillment(of: [newStarted], timeout: 3)
        gate.finish("new", with: .success(.init(results: [result("current.pdf")], notice: "current notice")))
        await fulfillment(of: [newPublished], timeout: 3)
        gate.finish("old", with: obsolete)
        await fulfillment(of: [oldReturned], timeout: 3)
        await Task.yield()
        XCTAssertEqual(model.groups.map(\.file.relativePath), ["current.pdf"])
        XCTAssertEqual(model.notice, "current notice")
        XCTAssertFalse(model.searching)
        XCTAssertNil(model.error)
        withExtendedLifetime(publication) {}
    }

    private func result(_ path: String) -> UnifiedSearchResult {
        UnifiedSearchResult(file: FileRef(relativePath: path))
    }

    /// Deliberately ignores cancellation to emulate a disk/model operation already
    /// underway, so the UI must reject the response rather than rely on the backend.
    private final class DeferredSearch {
        var onStart: ((String) -> Void)?
        var onReturn: ((String) -> Void)?
        private var pending: [String: CheckedContinuation<UnifiedSearchResponse, Error>] = [:]
        func search(_ query: String) async throws -> UnifiedSearchResponse {
            defer { onReturn?(query) }
            return try await withCheckedThrowingContinuation { continuation in
                pending[query] = continuation
                onStart?(query)
            }
        }
        func finish(_ query: String, with result: Result<UnifiedSearchResponse, Error>) {
            pending.removeValue(forKey: query)?.resume(with: result)
        }
    }
}
