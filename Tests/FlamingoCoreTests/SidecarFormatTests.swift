import XCTest
@testable import FlamingoCore

final class SidecarFormatTests: XCTestCase {

    // MARK: Round trip over every fixture

    func testEveryFixtureRoundTripsByteForByte() throws {
        let fixtures = try Fixtures.all()
        XCTAssertGreaterThanOrEqual(fixtures.count, 12, "need a dozen fixtures")
        for (name, text) in fixtures {
            let doc = SidecarFormat.parseDocument(text)
            XCTAssertEqual(SidecarFormat.render(doc), text, "render(parse(x)) != x for \(name)")
            // And parsing the render again is a fixed point.
            XCTAssertEqual(SidecarFormat.parseDocument(SidecarFormat.render(doc)), doc, "parse∘render not idempotent for \(name)")
        }
    }

    func testFrozenTupleAPIAgreesWithDocumentAPI() throws {
        for (name, text) in try Fixtures.all() {
            let (target, id, comments) = SidecarFormat.parse(text)
            let doc = SidecarFormat.parseDocument(text)
            XCTAssertEqual(target, doc.target, name)
            XCTAssertEqual(id, doc.id, name)
            XCTAssertEqual(comments, doc.comments, name)
        }
    }

    func testFileWithoutTrailingNewlineGainsOne() {
        let text = "---\ntarget: a.txt\n---\n- [2026-10-14 22:05] Hi"
        XCTAssertEqual(SidecarFormat.render(SidecarFormat.parseDocument(text)), text + "\n")
    }

    // MARK: Specific fixtures

    func testContractExample() throws {
        let doc = SidecarFormat.parseDocument(try Fixtures.text("01-contract-example.md"))
        XCTAssertEqual(doc.target, FileRef(relativePath: "decks/q3.pptx"))
        XCTAssertEqual(doc.id, UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        XCTAssertEqual(doc.comments.count, 2)
        XCTAssertEqual(doc.comments[0].anchor, FileAnchor(kind: .slide, value: "7"))
        XCTAssertEqual(doc.comments[0].text, "Pricing contradicts [[q3-model.xlsx]]")
        XCTAssertEqual(doc.comments[0].links, ["q3-model.xlsx"])
        XCTAssertEqual(doc.comments[0].timestamp, ts("2026-10-14 22:05"))
        XCTAssertNil(doc.comments[1].anchor)
        XCTAssertEqual(doc.comments[1].text, "Needs a better title\nSecond line of the same comment is indented two spaces.")
        XCTAssertTrue(doc.comments[1].isMultiline)
        XCTAssertEqual(doc.comments[1].firstLine, "Needs a better title")
    }

    func testAnchorsWithBangAndSpaces() throws {
        let doc = SidecarFormat.parseDocument(try Fixtures.text("02-anchors-with-bang.md"))
        XCTAssertEqual(doc.comments.map(\.anchor), [
            FileAnchor(kind: .cell, value: "Q3!B12"),
            FileAnchor(kind: .sheet, value: "Assumptions"),
            FileAnchor(kind: .cell, value: "Q3!B12"),
        ])
        XCTAssertEqual(doc.comments[0].links, ["q3.pptx"])
    }

    func testDuplicateCommentsGetDistinctStableIDs() throws {
        let doc = SidecarFormat.parseDocument(try Fixtures.text("03-duplicates-and-time.md"))
        XCTAssertEqual(doc.comments.count, 3)
        XCTAssertNotEqual(doc.comments[0].id, doc.comments[1].id)
        XCTAssertEqual(doc.comments[0].text, doc.comments[1].text)
        XCTAssertEqual(doc.comments[2].anchor, FileAnchor(kind: .time, value: "12:03:44"))
        // Same input → same ids, every time.
        let again = SidecarFormat.parseDocument(try Fixtures.text("03-duplicates-and-time.md"))
        XCTAssertEqual(again.comments.map(\.id), doc.comments.map(\.id))
    }

    func testStableIDsDifferAcrossTargets() {
        let a = SidecarFormat.stableID(target: "a.txt", timestamp: "2026-10-14 22:05", anchor: nil, text: "x", occurrence: 0)
        let b = SidecarFormat.stableID(target: "b.txt", timestamp: "2026-10-14 22:05", anchor: nil, text: "x", occurrence: 0)
        let a2 = SidecarFormat.stableID(target: "a.txt", timestamp: "2026-10-14 22:05", anchor: nil, text: "x", occurrence: 0)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, a2)
        XCTAssertNotEqual(a, SidecarFormat.stableID(target: "a.txt", timestamp: "2026-10-14 22:05", anchor: nil, text: "x", occurrence: 1))
        XCTAssertNotEqual(a, SidecarFormat.stableID(target: "a.txt", timestamp: "2026-10-14 22:05", anchor: FileAnchor(kind: .page, value: "1"), text: "x", occurrence: 0))
    }

    func testUnknownAnchorKindsStayInText() throws {
        let doc = SidecarFormat.parseDocument(try Fixtures.text("04-unknown-anchors.md"))
        XCTAssertEqual(doc.comments.count, 5)
        for c in doc.comments { XCTAssertNil(c.anchor, c.text) }
        XCTAssertEqual(doc.comments[0].text, "(foo 7) Unknown anchor kind stays in text")
        XCTAssertEqual(doc.comments[2].text, "(slide 7)No space after paren is text")
        XCTAssertEqual(doc.comments[4].text, "( slide 7) Leading space is text")
    }

    func testExtraFrontmatterKeysArePreservedAndReadable() throws {
        var doc = SidecarFormat.parseDocument(try Fixtures.text("05-extra-frontmatter.md"))
        XCTAssertEqual(doc.frontmatterKeys, ["target", "id", "tags", "reviewer", "created"])
        XCTAssertEqual(doc.frontmatterValue(for: "reviewer"), "Someone Else")
        XCTAssertEqual(doc.frontmatterValue(for: "tags"), "[review, urgent]")
        // Changing target rewrites one line and leaves the rest alone, in order.
        doc.target = FileRef(relativePath: "code/renamed.swift")
        let out = SidecarFormat.render(doc)
        XCTAssertTrue(out.hasPrefix("---\ntarget: code/renamed.swift\nid: 7C9E6679-7425-40DE-944B-E07FC1F90AE7\ntags: [review, urgent]\nreviewer: \"Someone Else\"\ncreated: 2026-10-14\n---\n"), out)
    }

    func testQuotedTargetIsUnquotedAndRequoted() throws {
        var doc = SidecarFormat.parseDocument(try Fixtures.text("06-quoted-target.md"))
        XCTAssertEqual(doc.target, FileRef(relativePath: "weird: name #1.pdf"))
        doc.target = FileRef(relativePath: "also: weird.pdf")
        XCTAssertTrue(SidecarFormat.render(doc).contains("target: \"also: weird.pdf\"\n"))
        doc.target = FileRef(relativePath: "plain.pdf")
        XCTAssertTrue(SidecarFormat.render(doc).contains("target: plain.pdf\n"))
    }

    func testNoFrontmatter() throws {
        var doc = SidecarFormat.parseDocument(try Fixtures.text("07-no-frontmatter.md"))
        XCTAssertNil(doc.frontmatter)
        XCTAssertNil(doc.target)
        XCTAssertEqual(doc.comments.count, 2)
        doc.target = FileRef(relativePath: "x.txt")
        XCTAssertEqual(SidecarFormat.render(doc), "---\ntarget: x.txt\n---\n- [2026-10-14 14:00] No frontmatter at all\n- [2026-10-14 14:01] Still parsed\n")
    }

    func testRawLinesKeepTheirPlace() throws {
        let doc = SidecarFormat.parseDocument(try Fixtures.text("08-raw-lines.md"))
        let kinds = doc.items.map { item -> String in
            switch item {
            case .raw(let l): return "raw(\(l))"
            case .comment(let c): return "comment(\(c.firstLine))"
            }
        }
        XCTAssertEqual(kinds, [
            "raw(# A heading someone typed in Obsidian)", "raw()", "comment(First)", "raw()",
            "raw(- plain bullet without timestamp)", "comment(Second)", "raw(Trailing prose line)",
        ])
        XCTAssertEqual(doc.comments[1].text, "Second\ncontinued\n\nafter an empty continuation line")
    }

    func testEmptyFirstLines() throws {
        let doc = SidecarFormat.parseDocument(try Fixtures.text("09-empty-first-lines.md"))
        XCTAssertEqual(doc.comments.map(\.text), ["", "", "\ntext that starts on the second line", "\nalso second line only"])
        XCTAssertEqual(doc.comments.map(\.anchor), [nil, FileAnchor(kind: .slide, value: "2"), nil, FileAnchor(kind: .page, value: "9")])
    }

    func testAnchorValuesWithSpacesAndParens() throws {
        let doc = SidecarFormat.parseDocument(try Fixtures.text("10-anchor-values.md"))
        XCTAssertEqual(doc.comments.map(\.anchor), [
            FileAnchor(kind: .region, value: "10 20 30 40"),
            FileAnchor(kind: .node, value: "a (nested"),   // the first `)` followed by a space ends the value
            FileAnchor(kind: .cell, value: "Sheet 1!A1:B2"),
            FileAnchor(kind: .node, value: "x)y"),
        ])
        XCTAssertEqual(doc.comments[1].text, "b) Value containing parens")
        XCTAssertEqual(doc.comments[3].text, "Close paren not followed by space")
    }

    func testTextEdgeCases() throws {
        let doc = SidecarFormat.parseDocument(try Fixtures.text("11-text-edge-cases.md"))
        XCTAssertEqual(doc.comments[0].links, ["link", "other"])
        XCTAssertEqual(doc.comments[1].text, "Tabs\there and trailing spaces   ")
        XCTAssertEqual(doc.comments[2].text, "Unicode: café — 日本語 🦩")
        XCTAssertEqual(doc.comments[3].text, "  leading spaces in text")
    }

    func testBadTimestampsAreRawLines() throws {
        let doc = SidecarFormat.parseDocument(try Fixtures.text("12-bad-timestamps.md"))
        XCTAssertEqual(doc.comments.count, 1)
        XCTAssertEqual(doc.comments[0].text, "Real comment")
        XCTAssertEqual(doc.items.filter { if case .raw = $0 { return true } else { return false } }.count, 5)
    }

    func testEmptyAndFrontmatterOnlyFiles() throws {
        let empty = SidecarFormat.parseDocument("")
        XCTAssertNil(empty.frontmatter)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(SidecarFormat.render(empty), "")

        let fences = SidecarFormat.parseDocument(try Fixtures.text("13-empty-frontmatter.md"))
        XCTAssertEqual(fences.frontmatter, [])
        XCTAssertTrue(fences.isEmpty)

        let unclosed = SidecarFormat.parseDocument(try Fixtures.text("18-unclosed-frontmatter.md"))
        XCTAssertNil(unclosed.frontmatter)
        XCTAssertEqual(unclosed.items.count, 2)

        XCTAssertEqual(SidecarFormat.render(SidecarFormat.parseDocument("\n")), "\n")
        XCTAssertEqual(SidecarFormat.render(SidecarFormat.parseDocument("---\n")), "---\n")
    }

    // MARK: Render

    func testRenderMatchesContractExample() {
        let out = SidecarFormat.render(
            target: FileRef(relativePath: "decks/q3.pptx"),
            id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"),
            comments: [
                Comment(timestamp: ts("2026-10-14 22:05"), anchor: FileAnchor(kind: .slide, value: "7"), text: "Pricing contradicts [[q3-model.xlsx]]"),
                Comment(timestamp: ts("2026-10-14 22:09"), text: "Needs a better title\nSecond line of the same comment is indented two spaces."),
            ])
        XCTAssertEqual(out, try Fixtures.text("01-contract-example.md"))
    }

    func testRenderWithoutIDOmitsTheKey() {
        let out = SidecarFormat.render(target: FileRef(relativePath: "a.txt"), id: nil, comments: [])
        XCTAssertEqual(out, "---\ntarget: a.txt\n---\n")
    }

    func testDocumentNormalizesTimestampsToMinutes() {
        let precise = ts("2026-10-14 22:05").addingTimeInterval(42.7)
        let doc = SidecarDocument(target: FileRef(relativePath: "a.txt"), id: nil, comments: [Comment(timestamp: precise, text: "x")])
        XCTAssertEqual(doc.comments[0].timestamp, ts("2026-10-14 22:05"))
        XCTAssertEqual(SidecarFormat.parseDocument(SidecarFormat.render(doc)), doc)
    }

    func testDocumentAssignsStableIDsOnConstruction() {
        let random = Comment(text: "x")
        let doc = SidecarDocument(target: FileRef(relativePath: "a.txt"), id: nil, comments: [random])
        XCTAssertNotEqual(doc.comments[0].id, random.id)
        XCTAssertEqual(doc.comments[0].id, SidecarFormat.parseDocument(SidecarFormat.render(doc)).comments[0].id)
    }

    func testTextThatLooksLikeAnAnchorIsReadBackAsOne() {
        // Inherent to the format: documented, not fixed.
        let doc = SidecarDocument(target: FileRef(relativePath: "a.txt"), id: nil,
                                  comments: [Comment(timestamp: ts("2026-10-14 22:05"), text: "(slide 7) x")])
        let back = SidecarFormat.parseDocument(SidecarFormat.render(doc))
        XCTAssertEqual(back.comments[0].anchor, FileAnchor(kind: .slide, value: "7"))
        XCTAssertEqual(back.comments[0].text, "x")
    }

    func testMultilineTextWithTrailingNewlineRoundTrips() {
        for text in ["a\n", "a\n\nb", "\n", "a\n  indented\n", "", "x\r\ny"] {
            let doc = SidecarDocument(target: FileRef(relativePath: "a.txt"), id: nil,
                                      comments: [Comment(timestamp: ts("2026-10-14 22:05"), anchor: FileAnchor(kind: .page, value: "1"), text: text)])
            let back = SidecarFormat.parseDocument(SidecarFormat.render(doc))
            XCTAssertEqual(back.comments[0].text, text, text.debugDescription)
            XCTAssertEqual(back, doc)
        }
    }

    // MARK: Document mutation

    func testDocumentMutations() throws {
        var doc = SidecarFormat.parseDocument(try Fixtures.text("08-raw-lines.md"))
        let first = doc.comments[0]
        let second = doc.comments[1]

        var edited = second
        edited.text = "Second, edited"
        XCTAssertTrue(doc.update(edited))
        XCTAssertEqual(doc.comments[1].text, "Second, edited")
        XCTAssertNotEqual(doc.comments[1].id, second.id, "editing changes the content-derived id")
        XCTAssertFalse(doc.update(second), "the old id is gone")

        XCTAssertEqual(doc.remove(id: first.id)?.text, "First")
        XCTAssertNil(doc.remove(id: first.id))
        XCTAssertEqual(doc.comments.count, 1)
        XCTAssertEqual(doc.items.count, 6, "raw lines untouched")

        try doc.insert(Comment(timestamp: ts("2026-10-14 15:02"), text: "Inserted"), at: 0)
        XCTAssertEqual(doc.comments.map(\.firstLine), ["Inserted", "Second, edited"])
        doc.append(Comment(timestamp: ts("2026-10-14 15:09"), text: "Appended"))
        XCTAssertEqual(doc.comments.map(\.firstLine), ["Inserted", "Second, edited", "Appended"])
        XCTAssertThrowsError(try doc.insert(Comment(text: "x"), at: 7))
        XCTAssertThrowsError(try doc.insert(Comment(text: "x"), at: -1))
        XCTAssertEqual(doc.index(of: doc.comments[2].id), 2)

        // Still round-trips after all of that.
        XCTAssertEqual(SidecarFormat.parseDocument(SidecarFormat.render(doc)), doc)
    }

    func testFrontmatterSetters() {
        var doc = SidecarDocument()
        XCTAssertNil(doc.frontmatter)
        doc.id = UUID(uuidString: "11111111-2222-4333-8444-555555555555")
        doc.target = FileRef(relativePath: "a.txt")
        doc.setFrontmatterValue("hello", for: "note")
        XCTAssertEqual(doc.frontmatter, ["target: a.txt", "id: 11111111-2222-4333-8444-555555555555", "note: hello"])
        doc.id = nil
        XCTAssertEqual(doc.frontmatterKeys, ["target", "note"])
        doc.setFrontmatterValue(nil, for: "missing")
        XCTAssertEqual(doc.frontmatterKeys, ["target", "note"])
    }

    func testYAMLScalars() {
        XCTAssertEqual(YAMLScalar.keyValue(of: "target: a b.txt")?.value, "a b.txt")
        XCTAssertEqual(YAMLScalar.keyValue(of: "target:")?.value, "")
        XCTAssertNil(YAMLScalar.keyValue(of: "target:a.txt"), "YAML needs a space after the colon")
        XCTAssertNil(YAMLScalar.keyValue(of: "# comment: x"))
        XCTAssertNil(YAMLScalar.keyValue(of: "no colon"))
        XCTAssertEqual(YAMLScalar.unquote("\"a \\\"q\\\" \\\\ b\""), "a \"q\" \\ b")
        XCTAssertEqual(YAMLScalar.unquote("'it''s'"), "it's")
        XCTAssertEqual(YAMLScalar.unquote("\""), "\"")
        for plain in ["a.txt", "decks/q3 (final).pptx", "日本語.md", "x-y_z.1"] {
            XCTAssertEqual(YAMLScalar.quoteIfNeeded(plain), plain)
        }
        XCTAssertEqual(YAMLScalar.quoteIfNeeded("a: b"), "\"a: b\"")
        XCTAssertEqual(YAMLScalar.quoteIfNeeded("#x"), "\"#x\"")
        XCTAssertEqual(YAMLScalar.quoteIfNeeded("-x"), "\"-x\"")
        XCTAssertEqual(YAMLScalar.quoteIfNeeded(""), "\"\"")
        XCTAssertEqual(YAMLScalar.quoteIfNeeded("true"), "\"true\"")
        XCTAssertEqual(YAMLScalar.quoteIfNeeded("123"), "\"123\"")
        XCTAssertEqual(YAMLScalar.quoteIfNeeded("a \"b\""), "a \"b\"", "a quote mid-string is a valid plain scalar")
        XCTAssertEqual(YAMLScalar.quoteIfNeeded("\"b\""), "\"\\\"b\\\"\"")
        XCTAssertEqual(YAMLScalar.unquote(YAMLScalar.quoteIfNeeded("we\\ird: \"x\" #y")), "we\\ird: \"x\" #y")
    }

    // MARK: Timestamps and anchors

    func testTimestampParsingIsStrict() {
        XCTAssertNotNil(SidecarFormat.timestamp(from: "2026-10-14 22:05"))
        XCTAssertNil(SidecarFormat.timestamp(from: "2026-10-14 22:05:00"))
        XCTAssertNil(SidecarFormat.timestamp(from: "2026-13-14 22:05"))
        XCTAssertNil(SidecarFormat.timestamp(from: "2026-02-30 22:05"))
        XCTAssertNil(SidecarFormat.timestamp(from: "2026-1-4 2:05"))
        XCTAssertNil(SidecarFormat.timestamp(from: ""))
        XCTAssertEqual(SidecarFormat.string(fromTimestamp: ts("2026-10-14 22:05")), "2026-10-14 22:05")
    }

    func testFileAnchorParsing() {
        XCTAssertEqual(FileAnchor(parsing: "slide 7"), FileAnchor(kind: .slide, value: "7"))
        XCTAssertEqual(FileAnchor(parsing: "  Cell  Q3!B12 "), FileAnchor(kind: .cell, value: "Q3!B12"))
        XCTAssertEqual(FileAnchor(parsing: "region 1 2 3 4"), FileAnchor(kind: .region, value: "1 2 3 4"))
        XCTAssertNil(FileAnchor(parsing: "slide"))
        XCTAssertNil(FileAnchor(parsing: "slide "))
        XCTAssertNil(FileAnchor(parsing: "foo 7"))
        XCTAssertNil(FileAnchor(parsing: ""))
        XCTAssertEqual(FileAnchor(rendered: "(slide 7)"), FileAnchor(kind: .slide, value: "7"))
        XCTAssertEqual(FileAnchor(rendered: "(time 1:23)")?.rendered, "(time 1:23)")
        XCTAssertEqual(FileAnchor(rendered: "(node a (b) c)"), FileAnchor(kind: .node, value: "a (b) c"))
        XCTAssertNil(FileAnchor(rendered: "slide 7"))
        XCTAssertNil(FileAnchor(rendered: "(Slide 7)"))
        XCTAssertNil(FileAnchor(rendered: "(slide 7) x"))
        XCTAssertNil(FileAnchor(rendered: "()"))
        XCTAssertEqual(FileAnchor(kind: .page, value: "3").label, "page 3")
    }
}
