import XCTest
import FlamingoCore
@testable import FlamingoExtract

final class ExtractTests: XCTestCase {
    func testDefaultsRegisterOnceAndKeepCustomPriority() {
        Extract.registerDefaults()
        Extract.registerDefaults()
        let names = Extract.extractors.map { String(describing: $0) }
        XCTAssertEqual(names.count, Set(names).count)
        for e in Extract.defaults { XCTAssertTrue(Extract.extractors.contains { $0 == e }) }
    }

    func testDispatchCallsTheConcreteInit() throws {
        let saved = Extract.extractors
        defer { Extract.extractors = saved }
        Extract.extractors = [Echo.self] + saved
        let f = try Fixtures.tempDir(self).appendingPathComponent("a.echo")
        try Data("x".utf8).write(to: f)
        XCTAssertEqual(try Extract.extract(f).text, "echo")
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try Extract.extract(URL(fileURLWithPath: "/nonexistent/\(UUID()).pptx")))
    }

    func testUnsupportedAndGarbageFilesComeBackEmptyWithoutThrowing() throws {
        let d = try Fixtures.tempDir(self)
        let junk = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7919) })
        for name in ["blob.bin", "broken.pptx", "broken.docx", "broken.xlsx", "broken.pdf", "a.zip", "noext"] {
            let f = d.appendingPathComponent(name)
            try junk.write(to: f)
            XCTAssertNoThrow(try Extract.extract(f), name)
        }
        let empty = d.appendingPathComponent("empty.txt")
        try Data().write(to: empty)
        XCTAssertEqual(try Extract.extract(empty).text, "")
        let folder = d.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(try Extract.extract(folder), .empty)
    }

    func testExtensionlessTextIsSniffed() throws {
        let f = try Fixtures.tempDir(self).appendingPathComponent("Makefile")
        try Data("build:\n\tswift build\n".utf8).write(to: f)
        XCTAssertTrue(TextSniffer.looksLikeText(f))
        let bin = f.deletingLastPathComponent().appendingPathComponent("bin")
        try Data([0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 1]).write(to: bin)
        XCTAssertFalse(TextSniffer.looksLikeText(bin))
    }

    func testInBackground() async throws {
        let f = try Fixtures.tempDir(self).appendingPathComponent("nothing.bin")
        try Data([0, 1, 2]).write(to: f)
        let e = try await Extract.extractInBackground(f)
        XCTAssertEqual(e.text, "")
    }

    func testSectionsInitJoinsText() {
        let e = Extracted(sections: [Section(anchor: .init(kind: .slide, value: "1"), text: "a"),
                                     Section(anchor: .init(kind: .slide, value: "2"), text: ""),
                                     Section(anchor: .init(kind: .slide, value: "3"), text: "b")])
        XCTAssertEqual(e.text, "a\n\nb")
    }
}

final class SupportTests: XCTestCase {
    func testZipListsAndReadsMembers() throws {
        let z = try Fixtures.tempDir(self).appendingPathComponent("t.zip")
        try Fixtures.zip(["a.xml": "<a/>", "dir/b c.xml": "<b>2</b>", "dir/[x].xml": "<x/>", "d/e/f.txt": "f"], to: z)
        let zip = try ZipArchive(z)
        XCTAssertEqual(Set(zip.names), ["a.xml", "dir/b c.xml", "dir/[x].xml", "d/e/f.txt"])
        XCTAssertEqual(zip.read("dir/b c.xml").map { String(decoding: $0, as: UTF8.self) }, "<b>2</b>")
        let many = zip.read(["a.xml", "dir/b c.xml", "dir/[x].xml", "missing.xml"])
        XCTAssertEqual(many.count, 3)
        XCTAssertEqual(many["dir/[x].xml"].map { String(decoding: $0, as: UTF8.self) }, "<x/>")
        XCTAssertThrowsError(try ZipArchive(z.deletingLastPathComponent().appendingPathComponent("nope.zip")))
    }

    func testRelationshipPaths() {
        XCTAssertEqual(OOXMLPath.resolve("../notesSlides/notesSlide1.xml", from: "ppt/slides/slide1.xml"),
                       "ppt/notesSlides/notesSlide1.xml")
        XCTAssertEqual(OOXMLPath.resolve("slides/slide2.xml", from: "ppt/presentation.xml"), "ppt/slides/slide2.xml")
        XCTAssertEqual(OOXMLPath.resolve("/xl/worksheets/sheet1.xml", from: "xl/workbook.xml"), "xl/worksheets/sheet1.xml")
        XCTAssertEqual(OOXMLPath.rels(for: "ppt/presentation.xml"), "ppt/_rels/presentation.xml.rels")
        let rels = OOXMLPath.relationships(Data("""
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>
            <Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://x.org" TargetMode="External"/>
            </Relationships>
            """.utf8), owner: "ppt/presentation.xml")
        XCTAssertEqual(rels["rId2"]?.target, "ppt/slides/slide1.xml")
        XCTAssertEqual(rels["rId2"]?.type, "slide")
        XCTAssertEqual(rels["rId9"]?.external, true)
    }

    func testXMLTree() throws {
        let root = try XCTUnwrap(XML.parse(Data("""
            <p:sld xmlns:p="p" xmlns:a="a" xmlns:r="r"><p:sldId id="256" r:id="rId2"/>
            <a:p><a:r><a:t>Hello </a:t></a:r><a:r><a:t>world &amp; more</a:t></a:r></a:p></p:sld>
            """.utf8)))
        XCTAssertEqual(root.localName, "sld")
        let id = try XCTUnwrap(root.first("sldId"))
        XCTAssertEqual(id.attr("id"), "256")
        XCTAssertEqual(id.prefixedAttr("id"), "rId2")
        XCTAssertEqual(root.descendants("t").map(\.text).joined(), "Hello world & more")
        XCTAssertNil(XML.parse(Data("not xml".utf8)))
        XCTAssertEqual(XML.unescape("a &lt;b&gt; &#65;&#x42; &amp;amp"), "a <b> AB &amp")
    }

    func testSubprocessTimesOut() throws {
        let out = try XCTUnwrap(Subprocess.run("/bin/sleep", ["5"], timeout: 0.3))
        XCTAssertTrue(out.timedOut)
        XCTAssertFalse(out.succeeded)
    }
}

private struct Echo: Extractor {
    static let extensions: Set<String> = ["echo"]
    init() {}
    func extract(_ url: URL) throws -> Extracted { Extracted(text: "echo") }
}
