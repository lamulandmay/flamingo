import AppKit
import XCTest
@testable import Flamingo
import FlamingoDesign

/// Texts are written with the selection in them: `|` is the caret, `«…»` a selection.
@MainActor
final class MarkdownEditingTests: XCTestCase {
    private func parse(_ marked: String) -> (NSString, NSRange) {
        let ns = NSMutableString(string: marked)
        let caret = ns.range(of: "|").location
        if caret != NSNotFound {
            ns.deleteCharacters(in: NSRange(location: caret, length: 1))
            return (ns, NSRange(location: caret, length: 0))
        }
        let open = ns.range(of: "«").location
        ns.deleteCharacters(in: NSRange(location: open, length: 1))
        let close = ns.range(of: "»").location
        ns.deleteCharacters(in: NSRange(location: close, length: 1))
        return (ns, NSRange(location: open, length: close - open))
    }

    private func render(_ edit: MarkdownEdit?, _ ns: NSString, _ selection: NSRange) -> String? {
        guard let edit else { return nil }
        let out = NSMutableString(string: ns)
        out.replaceCharacters(in: edit.range, with: edit.replacement)
        let s = edit.selection ?? selection
        if s.length == 0 { out.insert("|", at: s.location) }
        else { out.insert("»", at: NSMaxRange(s)); out.insert("«", at: s.location) }
        return out as String
    }

    private func newline(_ marked: String) -> String? {
        let (ns, s) = parse(marked); return render(MarkdownEditing.newline(in: ns, selection: s), ns, s)
    }
    private func backspace(_ marked: String) -> String? {
        let (ns, s) = parse(marked); return render(MarkdownEditing.deleteBackward(in: ns, selection: s), ns, s)
    }
    private func tab(_ marked: String, out: Bool = false) -> String? {
        let (ns, s) = parse(marked); return render(MarkdownEditing.indent(in: ns, selection: s, outdent: out), ns, s)
    }
    private func toggle(_ style: MarkdownEditing.Inline, _ marked: String) -> String? {
        let (ns, s) = parse(marked); return render(MarkdownEditing.toggle(style, in: ns, selection: s), ns, s)
    }

    // MARK: Lists

    func testReturnContinuesBulletsCheckboxesAndQuotes() {
        XCTAssertEqual(newline("- milk|"), "- milk\n- |")
        XCTAssertEqual(newline("* milk|"), "* milk\n* |")
        XCTAssertEqual(newline("- mi|lk"), "- mi\n- |lk")
        XCTAssertEqual(newline("- [x] done|"), "- [x] done\n- [ ] |")
        XCTAssertEqual(newline("> said|"), "> said\n> |")
        XCTAssertEqual(newline("> - quoted|"), "> - quoted\n> - |")
        XCTAssertEqual(newline("\t- nested|"), "\t- nested\n\t- |")
    }

    func testReturnLeavesOtherLinesAlone() {
        XCTAssertNil(newline("plain|"))
        XCTAssertNil(newline("# Heading|"))
        XCTAssertNil(newline("-|"))
        XCTAssertNil(newline("|- item"))
    }

    func testReturnOnAnEmptyItemStepsOut() {
        XCTAssertEqual(newline("- a\n- |"), "- a\n|")
        XCTAssertEqual(newline("- a\n\t- |"), "- a\n- |")
        XCTAssertEqual(newline("- [ ] |"), "|")
        XCTAssertEqual(newline("> - |"), "> |")
        XCTAssertEqual(newline("> |"), "|")
    }

    func testReturnNumbersOnAndRenumbersBelow() {
        XCTAssertEqual(newline("1. one|\n2. two\n3. three"), "1. one\n2. |\n3. two\n4. three")
        XCTAssertEqual(newline("9) nine|"), "9) nine\n10) |")
        XCTAssertEqual(newline("1. a|\n   - child\n2. b"), "1. a\n2. |\n   - child\n3. b")
        XCTAssertEqual(newline("1. a\n1. b|\n1. c"), "1. a\n1. b\n1. |\n1. c", "1. 1. 1. stays that way")
        XCTAssertEqual(newline("1. a|\n2. b\n\nAfter\n7. c"), "1. a\n2. |\n3. b\n\nAfter\n7. c")
    }

    func testBackspaceAfterAMarkerTakesItOff() {
        XCTAssertEqual(backspace("- |milk"), "|milk")
        XCTAssertEqual(backspace("- [ ] |milk"), "- |milk")
        XCTAssertEqual(backspace("- a\n\t- |b"), "- a\n- |b")
        XCTAssertEqual(backspace("3. |c"), "|c")
        XCTAssertEqual(backspace("> |x"), "|x")
        XCTAssertNil(backspace("- m|ilk"))
        XCTAssertNil(backspace("plain|"))
        XCTAssertNil(backspace("# |Heading"))
    }

    func testTabNestsAndShiftTabUnnests() {
        XCTAssertEqual(tab("- a\n- |b"), "- a\n\t- |b")
        XCTAssertEqual(tab("- a\n\t- |b", out: true), "- a\n- |b")
        XCTAssertEqual(tab("- a\n  - b\n    - |c", out: true), "- a\n  - b\n  - |c")
        XCTAssertEqual(tab("- |a", out: true), "- |a", "top level: nothing, and the key is used up")
        XCTAssertEqual(tab("«- a\n- b»"), "\t«- a\n\t- b»")
        XCTAssertNil(tab("plain|"))
    }

    func testCheckboxToggles() {
        let ns = "- [ ] buy\n- [x] sold" as NSString
        let tick = MarkdownEditing.toggleCheckbox(in: ns, at: 3)
        XCTAssertEqual(tick, MarkdownEdit(range: NSRange(location: 3, length: 1), replacement: "x", selection: nil))
        XCTAssertEqual(MarkdownEditing.toggleCheckbox(in: ns, at: 14)?.replacement, " ")
        XCTAssertNil(MarkdownEditing.toggleCheckbox(in: "- plain" as NSString, at: 3))
    }

    // MARK: Bold, italic, underline

    func testSelectionWrapsAndUnwraps() {
        XCTAssertEqual(toggle(.bold, "make «this» bold"), "make **«this»** bold")
        XCTAssertEqual(toggle(.bold, "make **«this»** bold"), "make «this» bold")
        XCTAssertEqual(toggle(.bold, "make «**this**» bold"), "make «this» bold")
        XCTAssertEqual(toggle(.italic, "«x»"), "*«x»*")
        XCTAssertEqual(toggle(.italic, "*«x»*"), "«x»")
        XCTAssertEqual(toggle(.underline, "«x»"), "<u>«x»</u>")
        XCTAssertEqual(toggle(.underline, "<u>«x»</u>"), "«x»")
        XCTAssertEqual(toggle(.bold, "make« this »bold"), "make **«this»** bold", "spaces stay outside the markers")
    }

    func testBoldAndItalicStack() {
        XCTAssertEqual(toggle(.italic, "**«x»**"), "***«x»***")
        XCTAssertEqual(toggle(.bold, "***«x»***"), "*«x»*")
        XCTAssertEqual(toggle(.italic, "***«x»***"), "**«x»**")
    }

    func testPartialSelectionsSplitOrMerge() {
        XCTAssertEqual(toggle(.bold, "**ab«cd»ef**"), "**ab**«cd»**ef**")
        XCTAssertEqual(toggle(.bold, "a «b **c» d**"), "a **«b c d»**")
    }

    func testSelectionSkipsListPrefixesAndSpansLines() {
        XCTAssertEqual(toggle(.bold, "- «item»"), "- **«item»**")
        XCTAssertEqual(toggle(.bold, "«- item\n»"), "- **«item»**\n")
        XCTAssertEqual(toggle(.bold, "«one\ntwo»"), "**«one**\n**two»**")
        XCTAssertEqual(toggle(.bold, "«**one**\n**two**»"), "«one\ntwo»")
    }

    func testCaretOpensAPairAndStepsOut() {
        XCTAssertEqual(toggle(.bold, "|"), "**|**")
        XCTAssertEqual(toggle(.bold, "**|**"), "|")
        XCTAssertEqual(toggle(.bold, "say **bold|**"), "say **bold**|")
        XCTAssertEqual(toggle(.bold, "say **bold |**"), "say **bold** |")
        XCTAssertEqual(toggle(.italic, "*|*"), "|")
        XCTAssertEqual(toggle(.italic, "**|**"), "***|***")
        XCTAssertEqual(toggle(.underline, "<u>x|</u>"), "<u>x</u>|")
    }

    func testCaretInAWordStylesTheWord() {
        XCTAssertEqual(toggle(.bold, "a wo|rd here"), "a **wo|rd** here")
        XCTAssertEqual(toggle(.bold, "a **wo|rd** here"), "a wo|rd here")
        XCTAssertEqual(toggle(.bold, "a word| here"), "a **word**| here", "from the end, typing carries on unstyled")
        XCTAssertEqual(toggle(.bold, "a |word here"), "a **|word** here")
        XCTAssertEqual(toggle(.bold, "a **word**| here"), "a word| here", "the same key again takes it back")
    }

    // MARK: Syntax

    func testSpansKeepCodeAndLinksIntact() {
        let ns = "a `**not**` [[file_name_here]] https://x.com/a_b_c **yes** _it_" as NSString
        let kinds = MarkdownSyntax.spans(in: ns, NSRange(location: 0, length: ns.length)).map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == .strong }.count, 1)
        XCTAssertEqual(kinds.filter { $0 == .emphasis }.count, 1)
        XCTAssertTrue(kinds.contains(.code) && kinds.contains(.wikilink) && kinds.contains(.url))
    }

    func testStructureFindsFrontmatterTitleAndCode() {
        let s = MarkdownStyler.Structure.of("---\na: 1\n---\nTitle\n```js\ncode\n```\nafter" as NSString)
        XCTAssertEqual(s.frontmatterEnd, 13)
        XCTAssertEqual(s.title, 13)
        XCTAssertEqual(s.blocks, [.init(open: 19, close: 30)])
        XCTAssertEqual(s.kind(ofLineAt: 4), .frontmatter)
        XCTAssertEqual(s.kind(ofLineAt: 13), .title)
        XCTAssertEqual(s.kind(ofLineAt: 25), .code(19))
        XCTAssertEqual(s.kind(ofLineAt: 34), .body)
        XCTAssertEqual(MarkdownStyler.Structure.of("```\nopen" as NSString).blocks, [], "a fence on the title line is just the title")
    }

    // MARK: Styling

    private func styled(_ text: String) -> (NSTextStorage, MarkdownStyler) {
        let storage = NSTextStorage(), styler = MarkdownStyler()
        styler.font = .system; styler.size = 16
        storage.delegate = styler
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        styler.flush(storage)
        return (storage, styler)
    }

    private func font(_ storage: NSTextStorage, _ at: Int) -> NSFont { storage.attribute(.font, at: at, effectiveRange: nil) as! NSFont }

    func testFirstLineIsTheTitle() {
        let (storage, styler) = styled("Groceries\nmilk")
        XCTAssertEqual(font(storage, 0).pointSize, 28)
        XCTAssertEqual(font(storage, 10).pointSize, 16)
        // A new line under the title is body text again.
        storage.replaceCharacters(in: NSRange(location: 9, length: 0), with: "\nbread")
        styler.flush(storage)
        XCTAssertEqual(font(storage, 10).pointSize, 16)
        XCTAssertEqual(font(storage, 0).pointSize, 28)
    }

    func testInlineAndListStyles() {
        let (storage, _) = styled("T\n**bold** *it* <u>under</u>\n- item\n- [x] done")
        XCTAssertTrue(font(storage, 4).fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(font(storage, 12).fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertNotNil(storage.attribute(.underlineStyle, at: 19, effectiveRange: nil))
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor, Theme.NS.textTertiary, "markers are quiet")
        let item = (storage.string as NSString).range(of: "- item").location
        XCTAssertEqual(storage.attribute(.markdownBullet, at: item, effectiveRange: nil) as? Bool, true)
        let paragraph = storage.attribute(.paragraphStyle, at: item + 3, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertGreaterThan(paragraph?.headIndent ?? 0, 0, "wrapped lines hang under the text")
        let box = (storage.string as NSString).range(of: "[x]").location
        XCTAssertEqual(storage.attribute(.markdownCheckbox, at: box, effectiveRange: nil) as? Bool, true)
    }

    func testOpeningAFenceRestylesBelow() {
        let (storage, styler) = styled("T\n``\nlet x = 1\n```")
        XCTAssertNil(storage.attribute(.markdownCodeBlock, at: 5, effectiveRange: nil))
        storage.replaceCharacters(in: NSRange(location: 2, length: 0), with: "`")
        styler.flush(storage)
        XCTAssertNotNil(storage.attribute(.markdownCodeBlock, at: 6, effectiveRange: nil))
        XCTAssertTrue(font(storage, 6).isFixedPitch)
    }
}
