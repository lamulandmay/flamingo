import XCTest
import FlamingoCore
@testable import FlamingoExtract

final class DOCXTests: XCTestCase {
    private func report() throws -> Extracted { try DOCXExtractor().extract(Fixtures.url("report.docx")) }

    private func build(_ members: [String: String], _ name: String = "doc.docx") throws -> URL {
        let url = try Fixtures.tempDir(self).appendingPathComponent(name)
        try Fixtures.zip(members, to: url)
        return url
    }

    func testReportSectionsInOrder() throws {
        let e = try report()
        XCTAssertEqual(e.sections.map(\.anchor), [
            "Q3 Field Report", "Overview", "Regional results", "North detail", "Key finding: retention",
            "Next steps", "Appendix",
        ].map { FileAnchor(kind: .node, value: $0) })
        XCTAssertEqual(e.sections.map(\.title), [nil, "Overview", "Regional results", "North detail",
                                                 "Key finding: retention", "Next steps", "Appendix"])
        XCTAssertEqual(e.title, "Q3 Field Report")
        XCTAssertEqual(try Extract.extract(Fixtures.url("report.docx")), e)
    }

    func testReportSectionText() throws {
        let text = try report().sections.map(\.text)
        XCTAssertEqual(text, [
            "Prepared by the field team for the steering group, covering July through September in all regions.\nQuarterly Field Report\nContents",
            "Overview\nSales grew in every region; the revised forecast held.\nTotal:\t42 units, see the regional dashboard",
            "Regional results\nRegion\tQ2\tQ3\nNorth\t120\t140\nEast (new)\t\t88\nSouth\t95\test.\t110\nFigures are in units.",
            "North detail\nNorth signed four new accounts. Churn fell.\nCallout: North doubled its pipeline.",
            "Key finding: retention\nRetention held at 94 percent for Contoso, owner Dana Whitfield.\nOffice move to Seattle confirmed on 14 October 2026.",
            "Next steps\nHire two analysts\nOpen the Q3-Q4 review\nMinor point\nBudget is unchanged.",
            "Appendix\nMethod notes follow the 2025 template.",
        ])
    }

    func testRevisionsFieldsAndTextBoxesReadOnce() throws {
        let e = try report()
        for gone in ["early forecast was wrong", "DOCPROPERTY", "MERGEFORMAT", "PAGE", "moved sentence"] {
            XCTAssertFalse(e.text.contains(gone), gone)
        }
        XCTAssertEqual(e.text.components(separatedBy: "North doubled its pipeline").count - 1, 1)
    }

    func testNotesFollowSectionsOutsideAnySection() throws {
        let e = try report()
        XCTAssertTrue(e.text.hasSuffix("Appendix\nMethod notes follow the 2025 template.\n\n"
                                       + "Source: regional CRM export, 2 October.\nFigures are unaudited."))
        XCTAssertFalse(e.sections.contains { $0.text.contains("CRM export") || $0.text.contains("unaudited") })
    }

    func testMainPartComesFromPackageRelationships() throws {
        let url = try build(DOCXBuilder.package(body: DOCXBuilder.reportBody, main: "word/main.xml",
                                                coreTitle: "Q3 Field Report", notes: true))
        XCTAssertEqual(try DOCXExtractor().extract(url), try report())
    }

    func testWithoutStylesPartOrCoreTitle() throws {
        let e = try DOCXExtractor().extract(build(DOCXBuilder.package(body: DOCXBuilder.reportBody, styles: false)))
        // Built-in ids still mark headings; the custom style based on Heading 2 is unknown now.
        XCTAssertEqual(e.sections.map(\.anchor.value), [
            "Prepared by the field team for the steering group, covering", "Overview", "Regional results",
            "North detail", "Next steps", "Appendix",
        ])
        XCTAssertNil(e.sections[0].title)
        XCTAssertTrue(e.sections[3].text.hasSuffix("pipeline.\nKey finding: retention\nRetention held at 94 percent for Contoso, owner Dana Whitfield.\nOffice move to Seattle confirmed on 14 October 2026."))
        XCTAssertEqual(e.title, "Quarterly Field Report")
    }

    func testTitleFallsBackToFirstHeadingAndEmptyBodyIsEmpty() throws {
        let body = DOCXBuilder.p("Scope", style: "Heading2") + DOCXBuilder.p("Two sites.")
        let e = try DOCXExtractor().extract(build(DOCXBuilder.package(body: body)))
        XCTAssertEqual(e.title, "Scope")
        XCTAssertEqual(e.sections, [Section(anchor: FileAnchor(kind: .node, value: "Scope"), title: "Scope", text: "Scope\nTwo sites.")])

        let empty = try DOCXExtractor().extract(build(DOCXBuilder.package(body: DOCXBuilder.p("") + DOCXBuilder.p(" "))))
        XCTAssertEqual(empty, .empty)
    }

    func testCorruptPackagesThrowOrDegrade() throws {
        let dir = try Fixtures.tempDir(self)
        let plain = dir.appendingPathComponent("plain.docx")
        try Data("not a zip".utf8).write(to: plain)
        XCTAssertThrowsError(try DOCXExtractor().extract(plain)) { XCTAssertEqual($0 as? ExtractError, .malformed(plain.path)) }

        let whole = try Data(contentsOf: Fixtures.url("report.docx"))
        let truncated = dir.appendingPathComponent("truncated.docx")
        try whole.prefix(whole.count / 2).write(to: truncated)
        XCTAssertThrowsError(try DOCXExtractor().extract(truncated))

        let noMain = try build(["[Content_Types].xml": "<Types/>", "docProps/core.xml": "<x/>"], "nomain.docx")
        XCTAssertThrowsError(try DOCXExtractor().extract(noMain))

        var members = DOCXBuilder.report()
        let xml = members["word/document.xml"]!
        members["word/document.xml"] = "<w:document><<<"
        XCTAssertThrowsError(try DOCXExtractor().extract(build(members, "garbage.docx")))

        // XML cut off mid-document keeps what was read before the break.
        members["word/document.xml"] = String(xml[..<xml.range(of: "<w:tbl>")!.lowerBound])
        let partial = try DOCXExtractor().extract(build(members, "cut.docx"))
        XCTAssertEqual(partial.sections.map(\.anchor.value), ["Q3 Field Report", "Overview", "Regional results"])
    }

    func testBenchmarkThreeHundredPages() throws {
        let members = DOCXBuilder.book(paragraphs: 3000, headingEvery: 20, tableEvery: 100)
        let url = try build(members, "book.docx")
        var e = Extracted.empty
        let t = try Fixtures.time { e = try DOCXExtractor().extract(url) }
        print(String(format: "DOCX benchmark: 3,000 paragraphs, 150 headings, 30 tables, %.1f MB document.xml: %.3f s",
                     Double(members["word/document.xml"]!.utf8.count) / 1e6, t))
        XCTAssertEqual(e.sections.count, 150)
        XCTAssertEqual(e.sections[149].title, "Chapter 149")
        XCTAssertTrue(e.text.contains("Row 9\tcell 9.1\tcell 9.2\tcell 9.3"))
        XCTAssertLessThan(t, 2)
    }

    /// Rewrites the committed fixture: `FLAMINGO_REGENERATE_FIXTURES=1 scripts/test.sh --filter DOCXTests`.
    func testRegenerateFixture() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FLAMINGO_REGENERATE_FIXTURES"] == "1")
        try Fixtures.zip(DOCXBuilder.report(), to: Fixtures.url("report.docx"))
    }
}

/// Writes packages shaped like Word's output: content types, package and part rels, styles with
/// Word's built-in heading definitions, core and app properties, footnotes and endnotes.
enum DOCXBuilder {
    static let ns = #"xmlns:wpc="http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:o="urn:schemas-microsoft-com:office:office" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math" xmlns:v="urn:schemas-microsoft-com:vml" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:w10="urn:schemas-microsoft-com:office:word" xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml" xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" mc:Ignorable="w14""#
    static let decl = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"

    /// The committed `report.docx`.
    static func report() -> [String: String] {
        package(body: reportBody, coreTitle: "Q3 Field Report", notes: true)
    }

    static func package(body: String, main: String = "word/document.xml", styles: Bool = true,
                        coreTitle: String? = nil, notes: Bool = false) -> [String: String] {
        let dir = (main as NSString).deletingLastPathComponent
        let ct = "application/vnd.openxmlformats-officedocument.wordprocessingml"
        var overrides = [("/\(main)", "\(ct).document.main+xml"),
                         ("/docProps/core.xml", "application/vnd.openxmlformats-package.core-properties+xml"),
                         ("/docProps/app.xml", "application/vnd.openxmlformats-officedocument.extended-properties+xml")]
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        var partRels = [("rId8", "\(rel)/hyperlink", "https://example.com/dashboard\" TargetMode=\"External")]
        var members: [String: String] = [
            main: decl + "<w:document \(ns)><w:body>\(body)<w:sectPr><w:footnotePr><w:pos w:val=\"pageBottom\"/></w:footnotePr><w:pgSz w:w=\"12240\" w:h=\"15840\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/><w:cols w:space=\"720\"/></w:sectPr></w:body></w:document>",
            "_rels/.rels": decl + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="\#(main)"/></Relationships>"#,
            "docProps/core.xml": decl + #"<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\#(coreTitle.map { "<dc:title>\($0)</dc:title>" } ?? "")<dc:creator>Field Team</dc:creator><cp:lastModifiedBy>Field Team</cp:lastModifiedBy><cp:revision>3</cp:revision><dcterms:created xsi:type="dcterms:W3CDTF">2026-10-01T09:00:00Z</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">2026-10-02T09:00:00Z</dcterms:modified></cp:coreProperties>"#,
            "docProps/app.xml": decl + #"<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Template>Normal.dotm</Template><Application>Microsoft Office Word</Application><DocSecurity>0</DocSecurity></Properties>"#,
        ]
        if styles {
            members["\(dir)/styles.xml"] = stylesXML
            overrides.append(("/\(dir)/styles.xml", "\(ct).styles+xml"))
            partRels.append(("rId1", "\(rel)/styles", "styles.xml"))
        }
        if notes {
            members["\(dir)/footnotes.xml"] = notesXML("footnote", "Source: regional CRM export, 2 October.")
            members["\(dir)/endnotes.xml"] = notesXML("endnote", "Figures are unaudited.")
            overrides += [("/\(dir)/footnotes.xml", "\(ct).footnotes+xml"), ("/\(dir)/endnotes.xml", "\(ct).endnotes+xml")]
            partRels += [("rId6", "\(rel)/footnotes", "footnotes.xml"), ("rId7", "\(rel)/endnotes", "endnotes.xml")]
        }
        members["[Content_Types].xml"] = decl + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>"#
            + overrides.map { #"<Override PartName="\#($0.0)" ContentType="\#($0.1)"/>"# }.joined() + "</Types>"
        members[OOXMLPath.rels(for: main)] = decl + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + partRels.map { #"<Relationship Id="\#($0.0)" Type="\#($0.1)" Target="\#($0.2)"/>"# }.joined() + "</Relationships>"
        return members
    }

    /// A one-run paragraph, optionally styled.
    static func p(_ text: String, style: String? = nil) -> String {
        let ppr = style.map { "<w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr>" } ?? ""
        return "<w:p w:rsidR=\"00A1B2C3\" w:rsidRDefault=\"00A1B2C3\">\(ppr)" + (text.isEmpty ? "" : "<w:r><w:t xml:space=\"preserve\">\(text)</w:t></w:r>") + "</w:p>"
    }

    static func cell(_ paragraphs: String) -> String {
        #"<w:tc><w:tcPr><w:tcW w:w="3000" w:type="dxa"/></w:tcPr>\#(paragraphs)</w:tc>"#
    }

    static func table(_ rows: [[String]]) -> String {
        #"<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="0" w:type="auto"/><w:tblLook w:val="04A0"/></w:tblPr><w:tblGrid><w:gridCol w:w="3000"/><w:gridCol w:w="3000"/><w:gridCol w:w="3000"/></w:tblGrid>"#
            + rows.map { "<w:tr w:rsidR=\"00A1B2C3\">" + $0.joined() + "</w:tr>" }.joined() + "</w:tbl>"
    }

    static let textBox = #"<w:p><w:r><w:t xml:space="preserve">Callout: North doubled its pipeline.</w:t></w:r></w:p>"#

    static let reportBody: String = [
        p("Prepared by the field team for the steering group, covering July through September in all regions."),
        p("Quarterly Field Report", style: "Title"),
        p("Contents", style: "TOCHeading"),
        p("Overview", style: "Heading1"),
        #"<w:p w:rsidR="00A1B2C3" w:rsidRDefault="00A1B2C3"><w:r><w:t xml:space="preserve">Sales grew in every region; the </w:t></w:r><w:del w:id="1" w:author="Dana Whitfield" w:date="2026-10-01T09:00:00Z"><w:r w:rsidDel="00D4E5F6"><w:delText xml:space="preserve">early forecast was wrong</w:delText></w:r></w:del><w:ins w:id="2" w:author="Dana Whitfield" w:date="2026-10-01T09:00:00Z"><w:r><w:t>revised forecast held</w:t></w:r></w:ins><w:r><w:t>.</w:t></w:r><w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr><w:footnoteReference w:id="1"/></w:r><w:moveFrom w:id="3" w:author="Dana Whitfield" w:date="2026-10-01T09:00:00Z"><w:r><w:t>A moved sentence.</w:t></w:r></w:moveFrom></w:p>"#,
        #"<w:p w:rsidR="00A1B2C3" w:rsidRDefault="00A1B2C3"><w:pPr><w:tabs><w:tab w:val="left" w:pos="2880"/></w:tabs></w:pPr><w:r><w:t>Total:</w:t></w:r><w:r><w:tab/><w:t xml:space="preserve">42 units, see </w:t></w:r><w:hyperlink r:id="rId8" w:history="1"><w:r><w:rPr><w:rStyle w:val="Hyperlink"/></w:rPr><w:t>the regional dashboard</w:t></w:r></w:hyperlink><w:r><w:rPr><w:rStyle w:val="EndnoteReference"/></w:rPr><w:endnoteReference w:id="1"/></w:r></w:p>"#,
        p("Regional results", style: "Heading2"),
        table([
            [cell(p("Region")), cell(p("Q2")), cell(p("Q3"))],
            [cell(p("North")), cell(p("120")), cell(p("140"))],
            [cell(p("East") + p("(new)")), cell(p("")), cell(p("88"))],
            [cell(p("")), cell(p("")), cell(p(""))],
            [cell(p("South")), cell(table([[cell(p("95")), cell(p("est."))]]) + p("")), cell(p("110"))],
        ]),
        p("Figures are in units."),
        p("North detail", style: "Heading3"),
        ##"<w:p w:rsidR="00A1B2C3" w:rsidRDefault="00A1B2C3"><w:r><w:t xml:space="preserve">North signed four new accounts. </w:t></w:r><w:r><mc:AlternateContent><mc:Choice Requires="wps"><w:drawing><wp:anchor distT="45720" distB="45720" distL="114300" distR="114300" simplePos="0" relativeHeight="251659264" behindDoc="0" locked="0" layoutInCell="1" allowOverlap="1"><wp:simplePos x="0" y="0"/><wp:positionH relativeFrom="column"><wp:posOffset>3200400</wp:posOffset></wp:positionH><wp:positionV relativeFrom="paragraph"><wp:posOffset>0</wp:posOffset></wp:positionV><wp:extent cx="2286000" cy="457200"/><wp:effectExtent l="0" t="0" r="0" b="0"/><wp:wrapSquare wrapText="bothSides"/><wp:docPr id="1" name="Text Box 1"/><wp:cNvGraphicFramePr/><a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"><wps:wsp><wps:cNvSpPr txBox="1"><a:spLocks noChangeArrowheads="1"/></wps:cNvSpPr><wps:spPr bwMode="auto"><a:xfrm><a:off x="0" y="0"/><a:ext cx="2286000" cy="457200"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></wps:spPr><wps:txbx><w:txbxContent>\##(textBox)</w:txbxContent></wps:txbx><wps:bodyPr rot="0" vert="horz" wrap="square" anchor="t" anchorCtr="0"><a:noAutofit/></wps:bodyPr></wps:wsp></a:graphicData></a:graphic></wp:anchor></w:drawing></mc:Choice><mc:Fallback><w:pict><v:shapetype id="_x0000_t202" coordsize="21600,21600" o:spt="202" path="m,l,21600r21600,l21600,xe"><v:stroke joinstyle="miter"/><v:path gradientshapeok="t" o:connecttype="rect"/></v:shapetype><v:shape id="Text Box 1" o:spid="_x0000_s1026" type="#_x0000_t202" style="position:absolute;margin-left:252pt;width:180pt;height:36pt;z-index:251659264"><v:textbox><w:txbxContent>\##(textBox)</w:txbxContent></v:textbox><w10:wrap type="square"/></v:shape></w:pict></mc:Fallback></mc:AlternateContent></w:r><w:r><w:t>Churn fell.</w:t></w:r></w:p>"##,
        p("Key finding: retention", style: "KeyFinding"),
        #"<w:p w:rsidR="00A1B2C3" w:rsidRDefault="00A1B2C3"><w:r><w:t xml:space="preserve">Retention held at 94 percent for </w:t></w:r><w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> DOCPROPERTY Client \* MERGEFORMAT </w:instrText></w:r><w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>Contoso</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r><w:r><w:t xml:space="preserve">, owner </w:t></w:r><w:sdt><w:sdtPr><w:alias w:val="Owner"/><w:tag w:val="owner"/><w:id w:val="-1730838563"/><w:placeholder><w:docPart w:val="DefaultPlaceholder_-1854013440"/></w:placeholder></w:sdtPr><w:sdtContent><w:r><w:t>Dana Whitfield</w:t></w:r></w:sdtContent></w:sdt><w:r><w:t>.</w:t></w:r></w:p>"#,
        #"<w:p w:rsidR="00A1B2C3" w:rsidRDefault="00A1B2C3"><w:r><w:t xml:space="preserve">Office move to </w:t></w:r><w:smartTag w:uri="urn:schemas-microsoft-com:office:smarttags" w:element="City"><w:r><w:t>Seattle</w:t></w:r></w:smartTag><w:r><w:t xml:space="preserve"> confirmed on </w:t></w:r><w:fldSimple w:instr=" DATE \@ &quot;d MMMM yyyy&quot; "><w:r><w:t>14 October 2026</w:t></w:r></w:fldSimple><w:r><w:t>.</w:t></w:r></w:p>"#,
        p("", style: "Heading1"),
        #"<w:p w:rsidR="00A1B2C3" w:rsidRDefault="00A1B2C3"><w:pPr><w:pStyle w:val="Heading1"/><w:pPrChange w:id="4" w:author="Dana Whitfield" w:date="2026-10-01T09:00:00Z"><w:pPr><w:pStyle w:val="Heading4"/></w:pPr></w:pPrChange></w:pPr><w:r><w:t>Next steps</w:t></w:r></w:p>"#,
        #"<w:p w:rsidR="00A1B2C3" w:rsidRDefault="00A1B2C3"><w:r><w:t>Hire two analysts</w:t></w:r><w:r><w:br/><w:t xml:space="preserve">Open the Q3</w:t></w:r><w:r><w:noBreakHyphen/><w:t>Q4 review</w:t></w:r><w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>"#,
        p("Minor point", style: "Heading4"),
        p("Budget is unchanged."),
        #"<w:p w:rsidR="00A1B2C3" w:rsidRDefault="00A1B2C3"><w:pPr><w:keepNext/><w:outlineLvl w:val="0"/></w:pPr><w:r><w:t>Appendix</w:t></w:r></w:p>"#,
        p("Method notes follow the 2025 template."),
    ].joined()

    static func notesXML(_ kind: String, _ text: String) -> String {
        decl + "<w:\(kind)s \(ns)>"
            + #"<w:\#(kind) w:type="separator" w:id="-1"><w:p><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:r><w:separator/></w:r></w:p></w:\#(kind)>"#
            + #"<w:\#(kind) w:type="continuationSeparator" w:id="0"><w:p><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:r><w:continuationSeparator/></w:r></w:p></w:\#(kind)>"#
            + #"<w:\#(kind) w:id="1"><w:p><w:pPr><w:pStyle w:val="FootnoteText"/></w:pPr><w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr><w:\#(kind)Ref/></w:r><w:r><w:t xml:space="preserve"> \#(text)</w:t></w:r></w:p></w:\#(kind)>"#
            + "</w:\(kind)s>"
    }

    static let stylesXML = decl + "<w:styles \(ns)>" + #"<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:asciiTheme="minorHAnsi" w:hAnsiTheme="minorHAnsi"/><w:sz w:val="22"/><w:lang w:val="en-US"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="259" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:latentStyles w:defLockedState="0" w:defUIPriority="99" w:defSemiHidden="0" w:defUnhideWhenUsed="0" w:defQFormat="0" w:count="376"><w:lsdException w:name="Normal" w:uiPriority="0" w:qFormat="1"/><w:lsdException w:name="heading 1" w:uiPriority="9" w:qFormat="1"/><w:lsdException w:name="heading 2" w:semiHidden="1" w:uiPriority="9" w:unhideWhenUsed="1" w:qFormat="1"/><w:lsdException w:name="Title" w:uiPriority="10" w:qFormat="1"/></w:latentStyles>"#
        + #"<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>"#
        + [(1, 32), (2, 26), (3, 24), (4, 22)].map { n, size in
            #"<w:style w:type="paragraph" w:styleId="Heading\#(n)"><w:name w:val="heading \#(n)"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:link w:val="Heading\#(n)Char"/><w:uiPriority w:val="9"/><w:qFormat/><w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="240" w:after="0"/><w:outlineLvl w:val="\#(n - 1)"/></w:pPr><w:rPr><w:rFonts w:asciiTheme="majorHAnsi" w:hAnsiTheme="majorHAnsi"/><w:sz w:val="\#(size)"/></w:rPr></w:style>"#
        }.joined()
        + #"<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:link w:val="TitleChar"/><w:uiPriority w:val="10"/><w:qFormat/><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/><w:contextualSpacing/></w:pPr><w:rPr><w:kern w:val="28"/><w:sz w:val="56"/></w:rPr></w:style>"#
        + #"<w:style w:type="paragraph" w:styleId="TOCHeading"><w:name w:val="TOC Heading"/><w:basedOn w:val="Heading1"/><w:next w:val="Normal"/><w:uiPriority w:val="39"/><w:unhideWhenUsed/><w:qFormat/><w:pPr><w:outlineLvl w:val="9"/></w:pPr></w:style>"#
        + #"<w:style w:type="paragraph" w:customStyle="1" w:styleId="KeyFinding"><w:name w:val="Key Finding"/><w:basedOn w:val="Heading2"/><w:next w:val="Normal"/><w:qFormat/><w:rPr><w:color w:val="C00000"/></w:rPr></w:style>"#
        + #"<w:style w:type="paragraph" w:styleId="FootnoteText"><w:name w:val="footnote text"/><w:basedOn w:val="Normal"/><w:link w:val="FootnoteTextChar"/><w:uiPriority w:val="99"/><w:semiHidden/><w:unhideWhenUsed/><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:rPr><w:sz w:val="20"/></w:rPr></w:style>"#
        + #"<w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont"><w:name w:val="Default Paragraph Font"/><w:uiPriority w:val="1"/><w:semiHidden/><w:unhideWhenUsed/></w:style>"#
        + #"<w:style w:type="character" w:customStyle="1" w:styleId="Heading1Char"><w:name w:val="Heading 1 Char"/><w:basedOn w:val="DefaultParagraphFont"/><w:link w:val="Heading1"/><w:uiPriority w:val="9"/><w:rPr><w:sz w:val="32"/></w:rPr></w:style>"#
        + #"<w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:basedOn w:val="DefaultParagraphFont"/><w:uiPriority w:val="99"/><w:unhideWhenUsed/><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>"#
        + #"<w:style w:type="character" w:styleId="FootnoteReference"><w:name w:val="footnote reference"/><w:basedOn w:val="DefaultParagraphFont"/><w:uiPriority w:val="99"/><w:semiHidden/><w:unhideWhenUsed/><w:rPr><w:vertAlign w:val="superscript"/></w:rPr></w:style>"#
        + #"<w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:uiPriority w:val="99"/><w:semiHidden/><w:unhideWhenUsed/><w:tblPr><w:tblInd w:w="0" w:type="dxa"/><w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>"#
        + #"<w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:basedOn w:val="TableNormal"/><w:uiPriority w:val="39"/><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr></w:style>"#
        + "</w:styles>"

    /// A long Word-like document: verbose run properties and revision ids on every paragraph,
    /// a Heading 1–3 every `headingEvery` paragraphs (titled `Chapter N`), a 10×4 table every `tableEvery`.
    static func book(paragraphs: Int, headingEvery: Int, tableEvery: Int) -> [String: String] {
        let rpr = #"<w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/><w:color w:val="1F1F1F"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US"/></w:rPr>"#
        var body = ""
        body.reserveCapacity(paragraphs * 1_500)
        for i in 0..<paragraphs {
            if i % headingEvery == 0 {
                body += #"<w:p w:rsidR="00B1C2D3" w:rsidRDefault="00B1C2D3" w:rsidP="00E4F5A6"><w:pPr><w:pStyle w:val="Heading\#(i / headingEvery % 3 + 1)"/></w:pPr><w:r w:rsidRPr="00C7D8E9">\#(rpr)<w:t>Chapter \#(i / headingEvery)</w:t></w:r></w:p>"#
                continue
            }
            body += #"<w:p w:rsidR="00B1C2D3" w:rsidRDefault="00B1C2D3" w:rsidP="00E4F5A6"><w:pPr><w:spacing w:after="120" w:line="276" w:lineRule="auto"/><w:jc w:val="both"/></w:pPr>"#
            for run in 0..<3 {
                body += #"<w:r w:rsidRPr="00C7D8E9">\#(rpr)<w:t xml:space="preserve">Paragraph \#(i) part \#(run) reviews the regional pipeline, the hiring plan, and the open risks for the quarter ahead. </w:t></w:r>"#
            }
            body += "</w:p>"
            if i % tableEvery == tableEvery - 1 {
                body += table((0..<10).map { r in
                    [cell(p("Row \(r)"))] + (1...3).map { c in cell(p("cell \(r).\(c)")) }
                })
            }
        }
        return package(body: body)
    }
}
