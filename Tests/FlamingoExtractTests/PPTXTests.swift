import XCTest
import FlamingoCore
@testable import FlamingoExtract

final class PPTXTests: XCTestCase {
    private func fixture() throws -> Extracted { try PPTXExtractor().extract(Fixtures.url("deck.pptx")) }

    func testSlidesFollowPresentationOrderNotFileNames() throws {
        let e = try fixture()
        XCTAssertEqual(e.sections.map(\.anchor), (1...5).map { FileAnchor(kind: .slide, value: "\($0)") })
        XCTAssertEqual(e.sections.map(\.title),
                       ["Flamingo Field Guide", "Where flamingos live", "Diet & feeding", "Population by region", nil])
        XCTAssertEqual(e.title, "Flamingo Field Guide 2026", "core.xml title wins over the first slide's")
    }

    func testSlideTextIsTitleThenShapesInReadingOrder() throws {
        let s = try fixture().sections
        XCTAssertEqual(s[0].text, "Flamingo Field Guide\nNotes from the lagoon")
        XCTAssertEqual(s[2].text, "Diet & feeding\nFilter feeders, head upside down\nBlue-green algae\nBrine shrimp\nCarotenoids turn them pink",
                       "positioned shapes sort by y, groups recurse, the connector adds nothing")
        XCTAssertEqual(s[4].text, "Backup: survey methodology\nSample sizes per colony\n\nOnly if asked.",
                       "hidden slide kept; one branch of mc:AlternateContent")
    }

    func testNotesFollowSlideTextAfterBlankLine() throws {
        let s = try fixture().sections
        XCTAssertEqual(s[1].text, """
            Where flamingos live
            Shallow coastal lagoons
            Salt flats
            and estuaries
            Alkaline lakes
            Lake Natron, Tanzania

            Mention the Camargue colony.
            Ask who has seen one in the wild.
            """)
        XCTAssertFalse(s[2].text.hasSuffix("\n"), "an empty notes body adds nothing")
    }

    func testTableRowsAreLinesAndCellsAreTabSeparated() throws {
        XCTAssertEqual(try fixture().sections[3].text, """
            Population by region
            Region\tCount\tTrend (5 yr)
            Africa\t2,000,000\tStable
            South America\t600,000\tRising
            Source: field counts

            Counts are estimates.
            """)
    }

    func testFootersSlideNumbersAndLayoutTextAreSkipped() throws {
        let text = try fixture().text
        XCTAssertEqual(text.components(separatedBy: "Sample sizes per colony").count, 2)
        for absent in ["Internal draft", "10/14/2026", "Click to edit", "Second level", "‹#›"] {
            XCTAssertFalse(text.contains(absent), absent)
        }
    }

    func testTitleFallsBackToFirstSlideTitleAndOnlyTheFirstTitleIsPulled() throws {
        let url = try Fixtures.tempDir(self).appendingPathComponent("untitled.pptx")
        try DeckBuilder(title: " ", slides: [.init(file: 1, shapes: S.sp(2, "Title 1", ph: "ctrTitle", S.t("Solo  act"))
                                                         + S.sp(3, "Title 2", ph: "title", S.t("Encore")))]).write(to: url)
        let e = try PPTXExtractor().extract(url)
        XCTAssertEqual(e.title, "Solo act")
        XCTAssertEqual(e.sections.map(\.text), ["Solo act\nEncore"])
    }

    func testPresentationPartFoundThroughPackageRelationships() throws {
        let url = try Fixtures.tempDir(self).appendingPathComponent("moved.pptx")
        var deck = DeckBuilder(title: "Moved", slides: [
            .init(file: 2, shapes: S.sp(2, "Title 1", ph: "title", S.t("First")), notes: ["Spoken"]),
            .init(file: 1, shapes: S.sp(2, "Title 1", ph: "title", S.t("Second"))),
        ])
        deck.dir = "show"
        deck.presentationName = "main.xml"
        try deck.write(to: url)
        let e = try PPTXExtractor().extract(url)
        XCTAssertEqual(e.sections.map(\.title), ["First", "Second"])
        XCTAssertEqual(e.sections.map(\.text), ["First\n\nSpoken", "Second"])
        XCTAssertEqual(e.title, "Moved")
    }

    func testCorruptFilesThrowAndBrokenSlidesKeepTheirNumber() throws {
        let d = try Fixtures.tempDir(self)
        let garbage = d.appendingPathComponent("garbage.pptx")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: garbage)
        XCTAssertThrowsError(try PPTXExtractor().extract(garbage)) { XCTAssertEqual($0 as? ExtractError, .malformed(garbage.path)) }

        let whole = try Data(contentsOf: Fixtures.url("deck.pptx"))
        let truncated = d.appendingPathComponent("truncated.pptx")
        try whole.prefix(whole.count / 2).write(to: truncated)
        XCTAssertThrowsError(try PPTXExtractor().extract(truncated))

        let word = d.appendingPathComponent("word.pptx")
        try Fixtures.zip(["[Content_Types].xml": "<Types/>", "word/document.xml": "<w:document/>"], to: word)
        XCTAssertThrowsError(try PPTXExtractor().extract(word)) { XCTAssertEqual($0 as? ExtractError, .malformed(word.path)) }

        let broken = d.appendingPathComponent("broken-slide.pptx")
        var members = DeckBuilder(title: "", slides: (1...3).map {
            .init(file: $0, shapes: S.sp(2, "Title 1", ph: "title", S.t("Slide \($0)")))
        }).members()
        members["ppt/slides/slide2.xml"] = "<p:sld><p:cSld><<<"
        try Fixtures.zip(members, to: broken)
        let e = try PPTXExtractor().extract(broken)
        XCTAssertEqual(e.sections.map(\.anchor.value), ["1", "2", "3"])
        XCTAssertEqual(e.sections.map(\.title), ["Slide 1", nil, "Slide 3"])
    }

    func testBenchmark200SlidesWithNotes() throws {
        let url = try Fixtures.tempDir(self).appendingPathComponent("big.pptx")
        let n = 200
        let slides = (1...n).map { i in
            DeckBuilder.Slide(
                file: (i * 37) % n + 1, // file names shuffled against presentation order
                shapes: S.sp(2, "Title 1", ph: "title", S.t("Slide \(i): quarterly flamingo census"))
                    + S.sp(3, "Content Placeholder 2", idx: 1, (1...6).map { S.t("Point \($0) about colony \(i), with enough words to look like a real bullet") })
                    + S.sp(4, "TextBox 3", at: (838200, 6000000), S.t("Source: survey \(i)")),
                notes: (1...3).map { "Speaker note \($0) for slide \(i), a sentence or two of what to say out loud." })
        }
        try DeckBuilder(title: "Census", slides: slides).write(to: url)

        var e = Extracted.empty
        let seconds = try Fixtures.time { e = try PPTXExtractor().extract(url) }
        print(String(format: "PPTX benchmark: %d slides with notes in %.3f s", n, seconds))
        XCTAssertEqual(e.sections.count, n)
        XCTAssertEqual(e.sections[136].title, "Slide 137: quarterly flamingo census")
        XCTAssertTrue(e.sections[136].text.hasSuffix("Speaker note 3 for slide 137, a sentence or two of what to say out loud."))
        XCTAssertLessThan(seconds, 2)
    }

    func testCommittedFixtureMatchesBuilder() throws {
        let url = try Fixtures.tempDir(self).appendingPathComponent("deck.pptx")
        try DeckBuilder.fixture.write(to: url)
        XCTAssertEqual(try PPTXExtractor().extract(url), try fixture())
    }

    /// `FLAMINGO_REGENERATE_FIXTURES=1 scripts/test.sh --filter PPTXTests` rewrites Fixtures/deck.pptx.
    func testRegenerateFixture() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FLAMINGO_REGENERATE_FIXTURES"] == "1")
        try DeckBuilder.fixture.write(to: Fixtures.url("deck.pptx"))
    }
}

// MARK: - Deck builder

/// Writes decks shaped like PowerPoint's output: content types, package and part relationships,
/// app and core properties, a slide master, layout, theme, and notes master (whose prompt text
/// must never be extracted), and a notes slide for each slide that has notes.
private struct DeckBuilder {
    struct Slide {
        /// `slideN.xml`; differs from the presentation position on purpose.
        var file: Int
        /// `p:spTree` children after its group properties.
        var shapes: String
        /// Paragraphs of the notes body; nil means no notes slide.
        var notes: [String]?
        var hidden = false
    }

    var title: String
    /// In presentation order.
    var slides: [Slide]
    var dir = "ppt"
    var presentationName = "presentation.xml"

    /// The committed `Fixtures/deck.pptx`.
    static let fixture = DeckBuilder(title: "Flamingo Field Guide 2026", slides: [
        Slide(file: 1, shapes: S.sp(2, "Title 1", ph: "ctrTitle", S.t("Flamingo Field Guide"))
            + S.sp(3, "Subtitle 2", ph: "subTitle", idx: 1, S.t("Notes from the lagoon"))
            + S.sp(4, "Date Placeholder 3", ph: "dt", idx: 10, S.p(S.fld("10/14/2026", type: "datetime1")))
            + S.sp(5, "Footer Placeholder 4", ph: "ftr", idx: 11, S.t("Internal draft"))
            + S.sp(6, "Slide Number Placeholder 5", ph: "sldNum", idx: 12, S.p(S.fld("1", type: "slidenum")))),
        Slide(file: 3, shapes: S.sp(2, "Title 1", ph: "title", S.p(S.r("Where flamingos"), S.br, S.r("live")))
            + S.sp(3, "Content Placeholder 2", idx: 1, S.t("Shallow coastal lagoons"), S.p(S.r("Salt flats"), S.br, S.r("and estuaries")),
                   S.p(), S.t("Alkaline lakes"), S.p(S.r("Lake Natron, "), S.r("Tanzania"), lvl: 1))
            + S.sp(4, "Slide Number Placeholder 3", ph: "sldNum", idx: 12, S.p(S.fld("2", type: "slidenum"))),
              notes: ["Mention the Camargue colony.", "Ask who has seen one in the wild."]),
        Slide(file: 2, shapes: S.sp(2, "Title 1", ph: "title", S.t("Diet & feeding"))
            + S.group(3, "Group 2", at: (838200, 2000000),
                      S.sp(4, "TextBox 3", at: (0, 2000000), S.t("Brine shrimp"))
                      + S.sp(5, "TextBox 4", at: (0, 1000000), S.t("Blue-green algae"))
                      + S.group(6, "Group 5", at: (0, 3000000), S.sp(7, "TextBox 6", at: (0, 0), S.t("Carotenoids turn them pink"))))
            + S.connector(8, at: (838200, 1500000))
            + S.sp(9, "TextBox 8", at: (838200, 1300000), S.t("Filter feeders, head upside down")),
              notes: [""]),
        Slide(file: 4, shapes: S.sp(2, "Title 1", ph: "title", S.t("Population by region"))
            + S.sp(3, "TextBox 2", at: (838200, 5200000), S.t("Source: field counts"))
            + S.table(4, at: (838200, 1800000), [["Region", "Count", "Trend\n(5 yr)"], ["Africa", "2,000,000", "Stable"],
                                                 ["", "", ""], ["South America", "600,000", "Rising"]])
            + S.sp(5, "Slide Number Placeholder 4", ph: "sldNum", idx: 12, S.p(S.fld("4", type: "slidenum"))),
              notes: ["Counts are estimates."]),
        Slide(file: 5, shapes: S.sp(2, "Content Placeholder 1", idx: 1, S.p())
            + S.sp(3, "TextBox 2", at: (838200, 2000000), S.t("Backup: survey methodology"))
            + S.alternate(S.sp(4, "TextBox 3", at: (838200, 3000000), S.t("Sample sizes per colony")),
                          fallback: S.sp(4, "TextBox 3", at: (838200, 3000000), S.t("Sample sizes per colony"))),
              notes: ["Only if asked."], hidden: true),
    ])

    func write(to url: URL) throws { try Fixtures.zip(members(), to: url) }

    func members() -> [String: String] {
        var m: [String: String] = [:]
        var overrides = ["/\(dir)/\(presentationName)": "presentationml.presentation.main",
                         "/\(dir)/slideMasters/slideMaster1.xml": "presentationml.slideMaster",
                         "/\(dir)/slideLayouts/slideLayout1.xml": "presentationml.slideLayout",
                         "/\(dir)/notesMasters/notesMaster1.xml": "presentationml.notesMaster",
                         "/\(dir)/theme/theme1.xml": "theme", "/\(dir)/theme/theme2.xml": "theme",
                         "/\(dir)/presProps.xml": "presentationml.presProps", "/\(dir)/viewProps.xml": "presentationml.viewProps",
                         "/\(dir)/tableStyles.xml": "presentationml.tableStyles", "/docProps/app.xml": "extended-properties"]

        m["_rels/.rels"] = S.rels([("rId3", "officeDocument/2006/relationships/extended-properties", "docProps/app.xml"),
                                   ("rId2", "package/2006/relationships/metadata/core-properties", "docProps/core.xml"),
                                   ("rId1", "officeDocument/2006/relationships/officeDocument", "\(dir)/\(presentationName)")])
        m["docProps/core.xml"] = S.decl + """
            <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\(S.esc(title))</dc:title><dc:creator>Flamingo Tests</dc:creator><cp:lastModifiedBy>Flamingo Tests</cp:lastModifiedBy><cp:revision>3</cp:revision><dcterms:created xsi:type="dcterms:W3CDTF">2026-10-14T09:00:00Z</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">2026-10-14T10:00:00Z</dcterms:modified></cp:coreProperties>
            """
        let noted = slides.filter { $0.notes != nil }.count
        m["docProps/app.xml"] = S.decl + """
            <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><TotalTime>12</TotalTime><Application>Microsoft Office PowerPoint</Application><PresentationFormat>Widescreen</PresentationFormat><Slides>\(slides.count)</Slides><Notes>\(noted)</Notes><HiddenSlides>\(slides.filter(\.hidden).count)</HiddenSlides><AppVersion>16.0000</AppVersion></Properties>
            """

        // Presentation relationships go by file number, the way PowerPoint numbers them.
        let byFile = slides.map(\.file).sorted()
        func slideRel(_ file: Int) -> String { "rId\(2 + byFile.firstIndex(of: file)!)" }
        let after = 2 + slides.count
        var presRels = [("rId1", "officeDocument/2006/relationships/slideMaster", "slideMasters/slideMaster1.xml")]
        presRels += byFile.map { (slideRel($0), "officeDocument/2006/relationships/slide", "slides/slide\($0).xml") }
        presRels += [("rId\(after)", "officeDocument/2006/relationships/notesMaster", "notesMasters/notesMaster1.xml"),
                     ("rId\(after + 1)", "officeDocument/2006/relationships/presProps", "presProps.xml"),
                     ("rId\(after + 2)", "officeDocument/2006/relationships/viewProps", "viewProps.xml"),
                     ("rId\(after + 3)", "officeDocument/2006/relationships/theme", "theme/theme1.xml"),
                     ("rId\(after + 4)", "officeDocument/2006/relationships/tableStyles", "tableStyles.xml")]
        m["\(dir)/_rels/\(presentationName).rels"] = S.rels(presRels)
        let ids = slides.map { "<p:sldId id=\"\(255 + $0.file)\" r:id=\"\(slideRel($0.file))\"/>" }.joined()
        m["\(dir)/\(presentationName)"] = S.decl + """
            <p:presentation \(S.ns) saveSubsetFonts="1"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:notesMasterIdLst><p:notesMasterId r:id="rId\(after)"/></p:notesMasterIdLst><p:sldIdLst>\(ids)</p:sldIdLst><p:sldSz cx="12192000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/><p:defaultTextStyle><a:lvl1pPr marL="0" algn="l" defTabSz="914400"><a:defRPr sz="1800"/></a:lvl1pPr></p:defaultTextStyle></p:presentation>
            """

        var notesNumber = 0
        for s in slides {
            let path = "\(dir)/slides/slide\(s.file).xml"
            overrides["/\(path)"] = "presentationml.slide"
            m[path] = S.decl + "<p:sld \(S.ns)\(s.hidden ? " show=\"0\"" : "")><p:cSld>\(S.tree(s.shapes))</p:cSld>\(S.clrMapOvr)</p:sld>"
            var rels = [("rId1", "officeDocument/2006/relationships/slideLayout", "../slideLayouts/slideLayout1.xml")]
            if let notes = s.notes {
                notesNumber += 1
                let notesPath = "\(dir)/notesSlides/notesSlide\(notesNumber).xml"
                overrides["/\(notesPath)"] = "presentationml.notesSlide"
                rels.append(("rId2", "officeDocument/2006/relationships/notesSlide", "../notesSlides/notesSlide\(notesNumber).xml"))
                m[notesPath] = S.decl + "<p:notes \(S.ns)><p:cSld>" + S.tree(
                    S.sp(2, "Slide Image Placeholder 1", ph: "sldImg", nil)
                    + S.sp(3, "Notes Placeholder 2", ph: "body", idx: 1, notes.map { $0.isEmpty ? S.p() : S.t($0) })
                    + S.sp(4, "Slide Number Placeholder 3", ph: "sldNum", idx: 5, S.p(S.fld("\(s.file)", type: "slidenum"))))
                    + "</p:cSld>" + S.clrMapOvr + "</p:notes>"
                m["\(dir)/notesSlides/_rels/notesSlide\(notesNumber).xml.rels"] = S.rels([
                    ("rId1", "officeDocument/2006/relationships/notesMaster", "../notesMasters/notesMaster1.xml"),
                    ("rId2", "officeDocument/2006/relationships/slide", "../slides/slide\(s.file).xml")])
            }
            m["\(dir)/slides/_rels/slide\(s.file).xml.rels"] = S.rels(rels)
        }

        m["\(dir)/slideLayouts/slideLayout1.xml"] = S.decl + """
            <p:sldLayout \(S.ns) type="title" preserve="1"><p:cSld name="Title Slide">\(S.tree(
                S.sp(2, "Title 1", ph: "ctrTitle", at: (1524000, 1122363), S.t("Click to edit Master title style"))
                + S.sp(3, "Subtitle 2", ph: "subTitle", idx: 1, at: (1524000, 3602038), S.t("Click to edit Master subtitle style"))))</p:cSld>\(S.clrMapOvr)</p:sldLayout>
            """
        m["\(dir)/slideLayouts/_rels/slideLayout1.xml.rels"] = S.rels([("rId1", "officeDocument/2006/relationships/slideMaster", "../slideMasters/slideMaster1.xml")])
        m["\(dir)/slideMasters/slideMaster1.xml"] = S.decl + """
            <p:sldMaster \(S.ns)><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg>\(S.tree(
                S.sp(2, "Title Placeholder 1", ph: "title", at: (838200, 365125), S.t("Click to edit Master title style"))
                + S.sp(3, "Text Placeholder 2", ph: "body", idx: 1, at: (838200, 1825625), S.t("Click to edit Master text styles"), S.p(S.r("Second level"), lvl: 1))
                + S.sp(4, "Date Placeholder 3", ph: "dt", idx: 2, at: (838200, 6356350), S.p(S.fld("10/14/2026", type: "datetimeFigureOut")))
                + S.sp(5, "Footer Placeholder 4", ph: "ftr", idx: 3, at: (4038600, 6356350), S.p())
                + S.sp(6, "Slide Number Placeholder 5", ph: "sldNum", idx: 4, at: (8610600, 6356350), S.p(S.fld("‹#›", type: "slidenum")))))</p:cSld>\(S.clrMap)<p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle><a:lvl1pPr algn="l"><a:defRPr sz="4400"/></a:lvl1pPr></p:titleStyle><p:bodyStyle><a:lvl1pPr marL="228600" indent="-228600"><a:buFont typeface="Arial"/><a:buChar char="•"/><a:defRPr sz="2800"/></a:lvl1pPr></p:bodyStyle><p:otherStyle><a:lvl1pPr><a:defRPr sz="1800"/></a:lvl1pPr></p:otherStyle></p:txStyles></p:sldMaster>
            """
        m["\(dir)/slideMasters/_rels/slideMaster1.xml.rels"] = S.rels([("rId1", "officeDocument/2006/relationships/slideLayout", "../slideLayouts/slideLayout1.xml"),
                                                                     ("rId2", "officeDocument/2006/relationships/theme", "../theme/theme1.xml")])
        m["\(dir)/notesMasters/notesMaster1.xml"] = S.decl + """
            <p:notesMaster \(S.ns)><p:cSld>\(S.tree(
                S.sp(2, "Slide Image Placeholder 1", ph: "sldImg", idx: 2, at: (685800, 1143000), nil)
                + S.sp(3, "Notes Placeholder 2", ph: "body", idx: 3, at: (685800, 4400550), S.t("Click to edit Master text styles"))))</p:cSld>\(S.clrMap)</p:notesMaster>
            """
        m["\(dir)/notesMasters/_rels/notesMaster1.xml.rels"] = S.rels([("rId1", "officeDocument/2006/relationships/theme", "../theme/theme2.xml")])
        m["\(dir)/theme/theme1.xml"] = S.theme("Office Theme")
        m["\(dir)/theme/theme2.xml"] = S.theme("Office Theme")
        m["\(dir)/presProps.xml"] = S.decl + "<p:presentationPr \(S.ns)/>"
        m["\(dir)/viewProps.xml"] = S.decl + "<p:viewPr \(S.ns)><p:normalViewPr><p:restoredLeft sz=\"15620\"/><p:restoredTop sz=\"94660\"/></p:normalViewPr><p:gridSpacing cx=\"76200\" cy=\"76200\"/></p:viewPr>"
        m["\(dir)/tableStyles.xml"] = S.decl + "<a:tblStyleLst xmlns:a=\"\(S.drawingML)\" def=\"{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}\"/>"

        let types = overrides.sorted { $0.key < $1.key }.map {
            "<Override PartName=\"\($0.key)\" ContentType=\"application/vnd.openxmlformats-officedocument.\($0.value)+xml\"/>"
        }.joined()
        m["[Content_Types].xml"] = S.decl + """
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>\(types)<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>
            """
        return m
    }
}

/// PresentationML snippets for `DeckBuilder`.
private enum S {
    static let decl = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    static let drawingML = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let ns = "xmlns:a=\"\(drawingML)\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
    static let clrMap = "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
    static let clrMapOvr = "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>"
    static let br = "<a:br><a:rPr lang=\"en-US\" dirty=\"0\"/></a:br>"

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func rels(_ list: [(id: String, type: String, target: String)]) -> String {
        decl + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + list.map { "<Relationship Id=\"\($0.id)\" Type=\"http://schemas.openxmlformats.org/\($0.type)\" Target=\"\($0.target)\"/>" }.joined()
            + "</Relationships>"
    }

    static func tree(_ shapes: String) -> String {
        "<p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>\(shapes)</p:spTree>"
    }

    static func r(_ text: String) -> String { "<a:r><a:rPr lang=\"en-US\" dirty=\"0\"/><a:t>\(esc(text))</a:t></a:r>" }
    static func fld(_ text: String, type: String) -> String {
        "<a:fld id=\"{B6F15528-21DE-4FAA-801E-634DDDAF4B2B}\" type=\"\(type)\"><a:rPr lang=\"en-US\"/><a:t>\(esc(text))</a:t></a:fld>"
    }
    static func p(_ fragments: String..., lvl: Int = 0) -> String {
        "<a:p>\(lvl > 0 ? "<a:pPr lvl=\"\(lvl)\"/>" : "")\(fragments.joined())<a:endParaRPr lang=\"en-US\" dirty=\"0\"/></a:p>"
    }
    /// A paragraph with one run.
    static func t(_ text: String) -> String { p(r(text)) }

    static func xfrm(_ at: (x: Int, y: Int), child: Bool = false) -> String {
        "<a:xfrm><a:off x=\"\(at.x)\" y=\"\(at.y)\"/><a:ext cx=\"4572000\" cy=\"914400\"/>"
            + (child ? "<a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"4572000\" cy=\"914400\"/>" : "") + "</a:xfrm>"
    }

    /// A placeholder when `ph` or `idx` is given, else a text box. nil paragraphs means no text body.
    static func sp(_ id: Int, _ name: String, ph: String? = nil, idx: Int? = nil, at: (x: Int, y: Int)? = nil, _ paragraphs: [String]?) -> String {
        let placeholder = ph == nil && idx == nil ? "<p:nvPr/>"
            : "<p:nvPr><p:ph\(ph.map { " type=\"\($0)\"" } ?? "")\(idx.map { " idx=\"\($0)\"" } ?? "")/></p:nvPr>"
        let locks = placeholder == "<p:nvPr/>" ? "<p:cNvSpPr txBox=\"1\"/>" : "<p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr>"
        let spPr = at.map { "<p:spPr>\(xfrm($0))<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr>" } ?? "<p:spPr/>"
        let body = paragraphs.map { "<p:txBody><a:bodyPr/><a:lstStyle/>\($0.isEmpty ? p() : $0.joined())</p:txBody>" } ?? ""
        return "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/>\(locks)\(placeholder)</p:nvSpPr>\(spPr)\(body)</p:sp>"
    }

    static func sp(_ id: Int, _ name: String, ph: String? = nil, idx: Int? = nil, at: (x: Int, y: Int)? = nil, _ paragraphs: String...) -> String {
        sp(id, name, ph: ph, idx: idx, at: at, paragraphs)
    }

    static func group(_ id: Int, _ name: String, at: (x: Int, y: Int), _ children: String) -> String {
        "<p:grpSp><p:nvGrpSpPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr>\(xfrm(at, child: true))</p:grpSpPr>\(children)</p:grpSp>"
    }

    static func connector(_ id: Int, at: (x: Int, y: Int)) -> String {
        "<p:cxnSp><p:nvCxnSpPr><p:cNvPr id=\"\(id)\" name=\"Straight Connector \(id - 1)\"/><p:cNvCxnSpPr/><p:nvPr/></p:nvCxnSpPr><p:spPr>\(xfrm(at))<a:prstGeom prst=\"line\"><a:avLst/></a:prstGeom></p:spPr></p:cxnSp>"
    }

    /// Cells hold paragraphs separated by "\n".
    static func table(_ id: Int, at: (x: Int, y: Int), _ rows: [[String]]) -> String {
        let grid = (rows.first ?? []).map { _ in "<a:gridCol w=\"2032000\"/>" }.joined()
        let body = rows.map { row in
            "<a:tr h=\"370840\">" + row.map { cell in
                "<a:tc><a:txBody><a:bodyPr/><a:lstStyle/>\(cell.isEmpty ? p() : cell.split(separator: "\n").map { t(String($0)) }.joined())</a:txBody><a:tcPr/></a:tc>"
            }.joined() + "</a:tr>"
        }.joined()
        return "<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id=\"\(id)\" name=\"Table \(id - 1)\"/><p:cNvGraphicFramePr><a:graphicFrameLocks noGrp=\"1\"/></p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x=\"\(at.x)\" y=\"\(at.y)\"/><a:ext cx=\"6096000\" cy=\"1483360\"/></p:xfrm><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/table\"><a:tbl><a:tblPr firstRow=\"1\" bandRow=\"1\"><a:tableStyleId>{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}</a:tableStyleId></a:tblPr><a:tblGrid>\(grid)</a:tblGrid>\(body)</a:tbl></a:graphicData></a:graphic></p:graphicFrame>"
    }

    /// The wrapper PowerPoint writes around shapes using newer features.
    static func alternate(_ choice: String, fallback: String) -> String {
        "<mc:AlternateContent xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\"><mc:Choice xmlns:a14=\"http://schemas.microsoft.com/office/drawing/2010/main\" Requires=\"a14\">\(choice)</mc:Choice><mc:Fallback>\(fallback)</mc:Fallback></mc:AlternateContent>"
    }

    static func theme(_ name: String) -> String {
        let colors = [("dk1", "<a:sysClr val=\"windowText\" lastClr=\"000000\"/>"), ("lt1", "<a:sysClr val=\"window\" lastClr=\"FFFFFF\"/>"),
                      ("dk2", "<a:srgbClr val=\"44546A\"/>"), ("lt2", "<a:srgbClr val=\"E7E6E6\"/>"),
                      ("accent1", "<a:srgbClr val=\"4472C4\"/>"), ("accent2", "<a:srgbClr val=\"ED7D31\"/>"),
                      ("accent3", "<a:srgbClr val=\"A5A5A5\"/>"), ("accent4", "<a:srgbClr val=\"FFC000\"/>"),
                      ("accent5", "<a:srgbClr val=\"5B9BD5\"/>"), ("accent6", "<a:srgbClr val=\"70AD47\"/>"),
                      ("hlink", "<a:srgbClr val=\"0563C1\"/>"), ("folHlink", "<a:srgbClr val=\"954F72\"/>")]
            .map { "<a:\($0.0)>\($0.1)</a:\($0.0)>" }.joined()
        let fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let three = { (s: String) in String(repeating: s, count: 3) }
        let fonts = "<a:latin typeface=\"Calibri\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/>"
        return decl + "<a:theme xmlns:a=\"\(drawingML)\" name=\"\(name)\"><a:themeElements><a:clrScheme name=\"Office\">\(colors)</a:clrScheme>"
            + "<a:fontScheme name=\"Office\"><a:majorFont>\(fonts)</a:majorFont><a:minorFont>\(fonts)</a:minorFont></a:fontScheme>"
            + "<a:fmtScheme name=\"Office\"><a:fillStyleLst>\(three(fill))</a:fillStyleLst><a:lnStyleLst>\(three("<a:ln w=\"6350\">\(fill)</a:ln>"))</a:lnStyleLst>"
            + "<a:effectStyleLst>\(three("<a:effectStyle><a:effectLst/></a:effectStyle>"))</a:effectStyleLst><a:bgFillStyleLst>\(three(fill))</a:bgFillStyleLst></a:fmtScheme>"
            + "</a:themeElements></a:theme>"
    }
}
