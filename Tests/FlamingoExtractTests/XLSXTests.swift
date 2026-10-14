import XCTest
import FlamingoCore
@testable import FlamingoExtract

final class XLSXTests: XCTestCase {
    private func model() throws -> Extracted { try XLSXExtractor().extract(Fixtures.url("model.xlsx")) }
    private func sheet(_ e: Extracted, _ name: String) -> String? { e.sections.first { $0.title == name }?.text }

    func testSheetsComeInWorkbookOrderWithNameAnchors() throws {
        let e = try model()
        XCTAssertEqual(e.sections.map(\.title), ["Q3 Model", "Assumptions", "Données"])
        XCTAssertEqual(e.sections.map(\.anchor), ["Q3 Model", "Assumptions", "Données"].map { FileAnchor(kind: .sheet, value: $0) })
        XCTAssertEqual(e.title, "Q3 Planning Model")
        XCTAssertTrue(e.text.hasPrefix("Metric\tQ1\tQ2\tQ3\tTotal\n"))
        XCTAssertTrue(e.text.contains("\n\nStart date\t2025-01-01\n"))
    }

    func testCellValuesRowsAndGaps() throws {
        XCTAssertEqual(sheet(try model(), "Q3 Model"), """
            Metric\tQ1\tQ2\tQ3\tTotal
            Revenue\t1200\t1350\t1525.5\t4075.5
            Gross margin\t0.42\t0.4\t0.385
            Notes\t\t\t\tsee Assumptions
            Closed\tTRUE\t#DIV/0!\tup
            Far\taway
            """)
    }

    func testDatesUseTheCellStyle() throws {
        XCTAssertEqual(sheet(try model(), "Assumptions"), """
            Start date\t2025-01-01
            Review at\t2025-09-30 18:00
            Churn\t0.035
            Runway\t18
            Headcount\t42
            """)
    }

    func testSharedStringsSkipPhoneticRuns() throws {
        XCTAssertEqual(sheet(try model(), "Données"), "Région\tChiffre d’affaires\nÎle-de-France\t98000\n東京\t51000.25")
    }

    func testFallbacksPrefixesMissingReferencesAndNonWorksheets() throws {
        let f = try Fixtures.tempDir(self).appendingPathComponent("edge.xlsx")
        try Fixtures.zip(Self.edgeMembers, to: f)
        let e = try XLSXExtractor().extract(f)
        XCTAssertNil(e.title)
        XCTAssertEqual(e.sections.map(\.title), ["Plain", "Chart", "Empty", "Missing"])
        XCTAssertEqual(e.sections.map(\.anchor.value), ["Plain", "Chart", "Empty", "Missing"])
        XCTAssertEqual(e.sections[0].text, "a\t1\t2.5\nline one  line two\t\tb\n2024-06-19\t12:00\t2024-06-19 06:30")
        XCTAssertEqual(e.sections[1...].map(\.text), ["", "", ""])
    }

    func testFormatDetectionAndNumbers() {
        for code in ["m/d/yyyy", "d\\ mmm\\ yyyy\\ h:mm", "[$-409]mmmm d, yyyy;@", "[h]:mm:ss", "hh:mm AM/PM", "YYYY-MM-DD"] {
            XCTAssertTrue(XLSXExtractor.isDateFormat(code), code)
        }
        for code in ["General", "0.00%", "[Red]#,##0.00\" days\"", "#,##0\\ \"dhs\"", "_-* #,##0.00_-;\\-* #,##0.00_-", "@", "0.00E+00"] {
            XCTAssertFalse(XLSXExtractor.isDateFormat(code), code)
        }
        XCTAssertEqual([42, -1250, 0.1, 1525.5, 1e20, 0.1 + 0.2].map(XLSXExtractor.number),
                       ["42", "-1250", "0.1", "1525.5", "1e+20", "0.30000000000000004"])
        XCTAssertEqual(XLSXExtractor.isoDate(1, date1904: false), "1900-01-01")
        XCTAssertEqual(XLSXExtractor.isoDate(61, date1904: false), "1900-03-01")
        XCTAssertEqual(XLSXExtractor.isoDate(2_958_465.999, date1904: false), "9999-12-31 23:59")
        XCTAssertEqual(XLSXExtractor.isoDate(0, date1904: true), "00:00")
        XCTAssertEqual(XLSXExtractor.isoDate(1, date1904: true), "1904-01-02")
        XCTAssertNil(XLSXExtractor.isoDate(-1, date1904: false))
        XCTAssertEqual(["A1", "Z9", "AA1", "AB12", "XFD1048576", "1"].map(XLSXExtractor.column), [0, 25, 26, 27, 16383, nil])
    }

    func testCorruptFilesThrowOrKeepWhatParsed() throws {
        let d = try Fixtures.tempDir(self)
        let junk = d.appendingPathComponent("junk.xlsx")
        try Data((0..<2048).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: junk)
        XCTAssertThrowsError(try XLSXExtractor().extract(junk)) { XCTAssertEqual($0 as? ExtractError, .malformed(junk.path)) }

        let truncated = d.appendingPathComponent("truncated.xlsx")
        let bytes = try Data(contentsOf: Fixtures.url("model.xlsx"))
        try bytes.prefix(bytes.count / 2).write(to: truncated)
        XCTAssertThrowsError(try XLSXExtractor().extract(truncated))

        let noBook = d.appendingPathComponent("nobook.xlsx")
        try Fixtures.zip(["[Content_Types].xml": "<Types/>", "word/document.xml": "<document/>"], to: noBook)
        XCTAssertThrowsError(try XLSXExtractor().extract(noBook)) { XCTAssertEqual($0 as? ExtractError, .malformed(noBook.path)) }

        let cut = d.appendingPathComponent("cut.xlsx")
        var members = Self.modelMembers
        let q3 = members["xl/worksheets/sheet3.xml"]!
        members["xl/worksheets/sheet3.xml"] = String(q3[..<q3.range(of: "<row r=\"3\"")!.upperBound])
        try Fixtures.zip(members, to: cut)
        let e = try XLSXExtractor().extract(cut)
        XCTAssertEqual(sheet(e, "Q3 Model"), "Metric\tQ1\tQ2\tQ3\tTotal\nRevenue\t1200\t1350\t1525.5\t4075.5")
        XCTAssertEqual(sheet(e, "Assumptions")?.hasPrefix("Start date\t2025-01-01"), true)
    }

    /// The sheet is also too big to unzip whole, so only its start is read.
    func testSheetStopsAtCellCap() throws {
        let f = try Fixtures.tempDir(self).appendingPathComponent("big.xlsx")
        let rows = (1...6000).map { r in
            "<row r=\"\(r)\">" + (0..<10).map { c in "<c r=\"\(Self.letters(c))\(r)\"><v>\(r * 10 + c)</v></c>" }.joined() + "</row>"
        }
        let filler = "<extLst><ext uri=\"{flamingo}\">\(String(repeating: "A", count: XLSXExtractor.maxSheetBytes))</ext></extLst>"
        let sheet = Self.worksheet(rows.joined()).replacingOccurrences(of: "</worksheet>", with: filler + "</worksheet>")
        try Fixtures.zip(Self.workbook(sheets: [sheet]), to: f)
        let lines = try XLSXExtractor().extract(f).sections[0].text.split(separator: "\n")
        XCTAssertEqual(lines.count, XLSXExtractor.maxCellsPerSheet / 10)
        XCTAssertEqual(lines.last, "50000\t50001\t50002\t50003\t50004\t50005\t50006\t50007\t50008\t50009")
    }

    func testBenchmarkTwentySheets() throws {
        let f = try Fixtures.tempDir(self).appendingPathComponent("bench.xlsx")
        let strings = (0..<1000).map { "<si><t>item \($0) forecast</t></si>" }.joined()
        let sheets = (0..<20).map { s in
            Self.worksheet((1...2000).map { r in
                "<row r=\"\(r)\">" + (0..<10).map { c in
                    let ref = "\(Self.letters(c))\(r)"
                    return c % 2 == 0 ? "<c r=\"\(ref)\" t=\"s\"><v>\((r * 7 + c + s) % 1000)</v></c>"
                                      : "<c r=\"\(ref)\"><v>\(r * c)\(r % 2 == 0 ? ".25" : "")</v></c>"
                }.joined() + "</row>"
            }.joined())
        }
        try Fixtures.zip(Self.workbook(sheets: sheets, sharedStrings: strings), to: f)
        var e = Extracted.empty
        let t = try Fixtures.time { e = try XLSXExtractor().extract(f) }
        print("XLSX benchmark: 20 sheets x 2,000 rows x 10 columns in \(String(format: "%.3f", t)) s")
        XCTAssertEqual(e.sections.count, 20)
        XCTAssertEqual(e.sections.map { $0.text.split(separator: "\n").count }, Array(repeating: 2000, count: 20))
        XCTAssertTrue(e.sections[19].text.hasSuffix("\nitem 19 forecast\t2000.25\titem 21 forecast\t6000.25\titem 23 forecast\t10000.25\titem 25 forecast\t14000.25\titem 27 forecast\t18000.25"))
        XCTAssertLessThan(t, 2)
    }

    /// Rewrites the committed fixture from `modelMembers` when `FLAMINGO_REGENERATE_FIXTURES=1`.
    func testRegenerateFixture() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FLAMINGO_REGENERATE_FIXTURES"] == "1")
        try Fixtures.zip(Self.modelMembers, to: Fixtures.url("model.xlsx"))
    }

    // MARK: - Builders

    static func letters(_ col: Int) -> String {
        col < 26 ? String(UnicodeScalar(65 + col)!) : letters(col / 26 - 1) + letters(col % 26)
    }

    static let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    static let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    static func worksheet(_ rows: String) -> String {
        #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
            + #"<worksheet xmlns="\#(main)" xmlns:r="\#(rel)"><sheetData>\#(rows)</sheetData></worksheet>"#
    }

    /// A minimal workbook with worksheets `Sheet1`... in file order.
    static func workbook(sheets: [String], sharedStrings: String? = nil) -> [String: String] {
        var m = [
            "_rels/.rels": #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="\#(rel)/officeDocument" Target="xl/workbook.xml"/></Relationships>"#,
            "xl/workbook.xml": #"<workbook xmlns="\#(main)" xmlns:r="\#(rel)"><sheets>"#
                + sheets.indices.map { #"<sheet name="Sheet\#($0 + 1)" sheetId="\#($0 + 1)" r:id="rId\#($0 + 1)"/>"# }.joined()
                + "</sheets></workbook>",
            "xl/_rels/workbook.xml.rels": #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
                + sheets.indices.map { #"<Relationship Id="rId\#($0 + 1)" Type="\#(rel)/worksheet" Target="worksheets/sheet\#($0 + 1).xml"/>"# }.joined()
                + #"<Relationship Id="rIdS" Type="\#(rel)/sharedStrings" Target="sharedStrings.xml"/></Relationships>"#,
        ]
        for (i, s) in sheets.enumerated() { m["xl/worksheets/sheet\(i + 1).xml"] = s }
        if let sharedStrings { m["xl/sharedStrings.xml"] = #"<sst xmlns="\#(main)">\#(sharedStrings)</sst>"# }
        return m
    }

    /// No root rels, the 1904 date system, an `x:`-prefixed worksheet without cell references,
    /// a chartsheet, an empty worksheet, and a sheet whose part is missing.
    static let edgeMembers: [String: String] = [
        "xl/workbook.xml": #"""
            <workbook xmlns="\#(main)" xmlns:r="\#(rel)"><workbookPr date1904="1"/><sheets>
            <sheet name="Plain" sheetId="1" r:id="rId1"/><sheet name="Chart" sheetId="2" r:id="rId2"/>
            <sheet name="Empty" sheetId="3" r:id="rId3"/><sheet name="Missing" sheetId="4" r:id="rId4"/></sheets></workbook>
            """#,
        "xl/_rels/workbook.xml.rels": #"""
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="\#(rel)/worksheet" Target="/xl/worksheets/plain.xml"/>
            <Relationship Id="rId2" Type="\#(rel)/chartsheet" Target="chartsheets/sheet1.xml"/>
            <Relationship Id="rId3" Type="\#(rel)/worksheet" Target="worksheets/empty.xml"/>
            <Relationship Id="rId4" Type="\#(rel)/worksheet" Target="worksheets/gone.xml"/>
            <Relationship Id="rId5" Type="\#(rel)/styles" Target="styles.xml"/></Relationships>
            """#,
        "xl/styles.xml": #"<styleSheet xmlns="\#(main)"><cellXfs count="2"><xf numFmtId="0"/><xf numFmtId="22"/></cellXfs></styleSheet>"#,
        "xl/worksheets/plain.xml": #"""
            <x:worksheet xmlns:x="\#(main)"><x:sheetData>
            <x:row><x:c t="inlineStr"><x:is><x:t>a</x:t></x:is></x:c><x:c><x:v>1</x:v></x:c><x:c><x:v>2.5</x:v></x:c></x:row>
            <x:row><x:c t="inlineStr"><x:is><x:r><x:t>line one_x000D_
            </x:t></x:r><x:r><x:t>line two</x:t></x:r></x:is></x:c><x:c s="1"/><x:c t="inlineStr"><x:is><x:t>b</x:t></x:is></x:c></x:row>
            <x:row r="9"/>
            <x:row><x:c s="1"><x:v>44000</x:v></x:c><x:c s="1"><x:v>0.5</x:v></x:c><x:c s="1"><x:v>44000.2708333333</x:v></x:c></x:row>
            </x:sheetData></x:worksheet>
            """#,
        "xl/chartsheets/sheet1.xml": #"<chartsheet xmlns="\#(main)" xmlns:r="\#(rel)"><sheetViews><sheetView workbookViewId="0"/></sheetViews><drawing r:id="rId1"/></chartsheet>"#,
        "xl/worksheets/empty.xml": #"<worksheet xmlns="\#(main)"><dimension ref="A1"/><sheetData/></worksheet>"#,
    ]

    /// `Fixtures/model.xlsx`, shaped like Excel's output.
    static let modelMembers: [String: String] = [
        "[Content_Types].xml": #"""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet3.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>
            """#,
        "_rels/.rels": #"""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
            """#,
        "docProps/core.xml": #"""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>Q3 Planning Model</dc:title><dc:creator>Flamingo Tests</dc:creator><cp:lastModifiedBy>Flamingo Tests</cp:lastModifiedBy><dcterms:created xsi:type="dcterms:W3CDTF">2026-10-01T09:00:00Z</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">2026-10-14T09:00:00Z</dcterms:modified></cp:coreProperties>
            """#,
        "docProps/app.xml": #"""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>Microsoft Excel</Application><DocSecurity>0</DocSecurity><ScaleCrop>false</ScaleCrop><HeadingPairs><vt:vector size="2" baseType="variant"><vt:variant><vt:lpstr>Worksheets</vt:lpstr></vt:variant><vt:variant><vt:i4>3</vt:i4></vt:variant></vt:vector></HeadingPairs><TitlesOfParts><vt:vector size="3" baseType="lpstr"><vt:lpstr>Q3 Model</vt:lpstr><vt:lpstr>Assumptions</vt:lpstr><vt:lpstr>Données</vt:lpstr></vt:vector></TitlesOfParts><AppVersion>16.0300</AppVersion></Properties>
            """#,
        "xl/workbook.xml": #"""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" mc:Ignorable="x15" xmlns:x15="http://schemas.microsoft.com/office/spreadsheetml/2010/11/main"><fileVersion appName="xl" lastEdited="7" lowestEdited="7" rupBuild="28629"/><workbookPr defaultThemeVersion="202300"/><bookViews><workbookView xWindow="0" yWindow="500" windowWidth="28800" windowHeight="16000" activeTab="0"/></bookViews><sheets><sheet name="Q3 Model" sheetId="3" r:id="rId3"/><sheet name="Assumptions" sheetId="1" r:id="rId1"/><sheet name="Données" sheetId="2" r:id="rId2"/></sheets><definedNames><definedName name="Churn">Assumptions!$B$3</definedName></definedNames><calcPr calcId="191029"/></workbook>
            """#,
        "xl/_rels/workbook.xml.rels": #"""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet3.xml"/><Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
            """#,
        "xl/styles.xml": #"""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" mc:Ignorable="x14ac x16r2" xmlns:x14ac="http://schemas.microsoft.com/office/spreadsheetml/2009/9/ac" xmlns:x16r2="http://schemas.microsoft.com/office/spreadsheetml/2015/02/main"><numFmts count="2"><numFmt numFmtId="164" formatCode="d\ mmm\ yyyy\ h:mm"/><numFmt numFmtId="165" formatCode="[Red]#,##0.00&quot; days&quot;"/></numFmts><fonts count="2" x14ac:knownFonts="1"><font><sz val="12"/><color theme="1"/><name val="Aptos Narrow"/><family val="2"/><scheme val="minor"/></font><font><b/><sz val="12"/><color theme="1"/><name val="Aptos Narrow"/><family val="2"/><scheme val="minor"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="6"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="14" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="10" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles><dxfs count="0"/><tableStyles count="0" defaultTableStyle="TableStyleMedium2" defaultPivotStyle="PivotStyleLight16"/></styleSheet>
            """#,
        "xl/sharedStrings.xml": #"""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="20" uniqueCount="20"><si><t>Metric</t></si><si><t>Q1</t></si><si><t>Q2</t></si><si><t>Q3</t></si><si><t>Total</t></si><si><t>Revenue</t></si><si><r><rPr><b/><sz val="12"/><color theme="1"/><rFont val="Aptos Narrow"/><family val="2"/><scheme val="minor"/></rPr><t>Gross</t></r><r><rPr><sz val="12"/><color theme="1"/><rFont val="Aptos Narrow"/><family val="2"/><scheme val="minor"/></rPr><t xml:space="preserve"> margin</t></r></si><si><t>Notes</t></si><si><t>Closed</t></si><si><t>Far</t></si><si><t>away</t></si><si><t>Start date</t></si><si><t>Review at</t></si><si><t>Churn</t></si><si><t>Runway</t></si><si><t>Headcount</t></si><si><t>Région</t></si><si><t>Chiffre d’affaires</t></si><si><t>Île-de-France</t></si><si><t>東京</t><rPh sb="0" eb="2"><t>トウキョウ</t></rPh><phoneticPr fontId="1"/></si></sst>
            """#,
        // "Q3 Model": shared, rich-text and inline strings, numbers, formulas with cached values,
        // a boolean, an error, an empty formatted row, a padded gap, and a gap too wide to pad.
        "xl/worksheets/sheet3.xml": #"""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" mc:Ignorable="x14ac" xmlns:x14ac="http://schemas.microsoft.com/office/spreadsheetml/2009/9/ac"><dimension ref="A1:AZ8"/><sheetViews><sheetView tabSelected="1" workbookViewId="0"><selection activeCell="B2" sqref="B2"/></sheetView></sheetViews><sheetFormatPr baseColWidth="10" defaultRowHeight="16" x14ac:dyDescent="0.2"/><cols><col min="1" max="1" width="14" customWidth="1"/></cols><sheetData><row r="1" spans="1:5" x14ac:dyDescent="0.2"><c r="A1" s="5" t="s"><v>0</v></c><c r="B1" s="5" t="s"><v>1</v></c><c r="C1" s="5" t="s"><v>2</v></c><c r="D1" s="5" t="s"><v>3</v></c><c r="E1" s="5" t="s"><v>4</v></c></row><row r="2" spans="1:5" x14ac:dyDescent="0.2"><c r="A2" t="s"><v>5</v></c><c r="B2"><v>1200</v></c><c r="C2"><v>1350</v></c><c r="D2"><v>1525.5</v></c><c r="E2"><f>SUM(B2:D2)</f><v>4075.5</v></c></row><row r="3" spans="1:5" x14ac:dyDescent="0.2"><c r="A3" t="s"><v>6</v></c><c r="B3" s="4"><v>0.42</v></c><c r="C3" s="4"><v>0.4</v></c><c r="D3" s="4"><v>0.38500000000000001</v></c></row><row r="4" spans="1:5" x14ac:dyDescent="0.2"><c r="A4" t="s"><v>7</v></c><c r="B4" s="5"/><c r="E4" t="inlineStr"><is><t>see Assumptions</t></is></c></row><row r="5" ht="8" customHeight="1" x14ac:dyDescent="0.2"/><row r="6" spans="1:5" x14ac:dyDescent="0.2"><c r="A6" t="s"><v>8</v></c><c r="B6" t="b"><v>1</v></c><c r="C6" t="e"><f>B2/0</f><v>#DIV/0!</v></c><c r="D6" t="str"><f>IF(D2&gt;C2,"up","down")</f><v>up</v></c></row><row r="8" spans="1:52" x14ac:dyDescent="0.2"><c r="A8" t="s"><v>9</v></c><c r="AZ8" t="s"><v>10</v></c></row></sheetData><pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/></worksheet>
            """#,
        // "Assumptions": a built-in date format, a custom date-time format, a percentage, and a
        // custom number format whose quoted and bracketed letters must not read as a date.
        "xl/worksheets/sheet1.xml": #"""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><dimension ref="A1:B5"/><sheetViews><sheetView workbookViewId="0"/></sheetViews><sheetFormatPr baseColWidth="10" defaultRowHeight="16"/><sheetData><row r="1" spans="1:2"><c r="A1" t="s"><v>11</v></c><c r="B1" s="1"><v>45658</v></c></row><row r="2" spans="1:2"><c r="A2" t="s"><v>12</v></c><c r="B2" s="2"><v>45930.75</v></c></row><row r="3" spans="1:2"><c r="A3" t="s"><v>13</v></c><c r="B3" s="4"><v>3.5000000000000003E-2</v></c></row><row r="4" spans="1:2"><c r="A4" t="s"><v>14</v></c><c r="B4" s="3"><v>18</v></c></row><row r="5" spans="1:2"><c r="A5" t="s"><v>15</v></c><c r="B5"><v>42</v></c></row></sheetData><pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/></worksheet>
            """#,
        // "Données": non-ASCII shared strings, one with a phonetic guide.
        "xl/worksheets/sheet2.xml": #"""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><dimension ref="A1:B3"/><sheetViews><sheetView workbookViewId="0"/></sheetViews><sheetFormatPr baseColWidth="10" defaultRowHeight="16"/><sheetData><row r="1" spans="1:2"><c r="A1" t="s"><v>16</v></c><c r="B1" t="s"><v>17</v></c></row><row r="2" spans="1:2"><c r="A2" t="s"><v>18</v></c><c r="B2"><v>98000</v></c></row><row r="3" spans="1:2"><c r="A3" t="s"><v>19</v></c><c r="B3"><v>51000.25</v></c></row></sheetData><pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/></worksheet>
            """#,
    ]
}
