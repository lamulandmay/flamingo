import XCTest
import AppKit
@testable import Flamingo

@MainActor
final class SourceNavigationTests: XCTestCase {
    func testRepeatedQueryHighlightsRequestedLineInsteadOfEarlierOccurrence() throws {
        let text = "same phrase\nother\nother\nsame phrase here\n"
        let range = try XCTUnwrap(SourceTextView.highlightRange(in: text, line: 4, query: "same phrase"))
        XCTAssertEqual((text as NSString).substring(with: range), "same phrase")
        XCTAssertEqual(SourceTextView.lineNumber(in: text, utf16Offset: range.location), 4)
    }

    func testMissingQueryOnRequestedLineKeepsExactAnchor() throws {
        let text = "search needle\nactual cited evidence\n"
        let range = try XCTUnwrap(SourceTextView.highlightRange(in: text, line: 2, query: "search needle"))
        XCTAssertEqual((text as NSString).substring(with: range), "actual cited evidence\n")
    }

    func testUnanchoredQueryCanFindWholeDocument() throws {
        let text = "intro\nCafé measurement\n"
        let range = try XCTUnwrap(SourceTextView.highlightRange(in: text, line: nil, query: "cafe"))
        XCTAssertEqual((text as NSString).substring(with: range), "Café")
    }

    func testLineNumbersAgreeWithNativeLocationsForWindowsAndUnicodeNewlines() throws {
        for separator in ["\n", "\r\n", "\r", "\u{2028}"] {
            let text = ["🦩 first", "second", "third"].joined(separator: separator)
            for expected in 1...3 {
                let range = try XCTUnwrap(SourceTextView.highlightRange(in: text, line: expected, query: ""))
                XCTAssertEqual(SourceTextView.lineNumber(in: text, utf16Offset: range.location), expected)
            }
            XCTAssertEqual(SourceTextView.lineNumber(in: text, utf16Offset: (text as NSString).length), 3)
            XCTAssertEqual(SourceTextView.lineNumber(in: text + separator, utf16Offset: ((text + separator) as NSString).length), 4)
        }
    }

    func testSearchFieldFocusesImmediatelyWhenAttachedAndAgainOnShortcutRequest() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = ImmediateSearchTextField(frame: NSRect(x: 20, y: 20, width: 320, height: 24))
        field.requestFocus()
        window.contentView?.addSubview(field)
        XCTAssertTrue(field.currentEditor() != nil || window.firstResponder === field,
                      "No delayed task should be needed between attachment and accepting typed characters")
        window.makeFirstResponder(nil)
        field.requestFocus()
        XCTAssertTrue(field.currentEditor() != nil || window.firstResponder === field)
    }
}
