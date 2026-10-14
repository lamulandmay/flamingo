import XCTest
import FlamingoCore
@testable import FlamingoExtract

final class SpotlightTests: XCTestCase {
    private func lines(_ e: Extracted) -> [String] { e.text.components(separatedBy: "\n") }

    func testLegacyWordDocument() throws {
        let e = try SpotlightExtractor().extract(Fixtures.url("legacy.doc"))
        XCTAssertEqual(e.title, "Flamingo Field Notes")
        XCTAssertTrue(e.sections.isEmpty)
        // Office.mdimporter separates paragraphs with CR; they come back as lines.
        XCTAssertFalse(e.text.contains("\r"))
        XCTAssertTrue(e.text.hasPrefix("Pink plumage comes from carotenoids in brine shrimp.\nCafé naïve"), e.text)
        XCTAssertTrue(lines(e).contains("Café naïve résumé — 日本語 “quoted” 🦩"), e.text)
        XCTAssertTrue(lines(e).contains(#"Last line has "double quotes" and a back\slash."#), e.text)
        XCTAssertTrue(lines(e).contains("Ada Lovelace"), e.text)
        XCTAssertTrue(lines(e).contains("Migration survey"), e.text)
        XCTAssertTrue(lines(e).contains { $0.contains("(.doc)") }, "kind line: \(e.text)")
    }

    func testNonASCIITitleAndAuthor() throws {
        let e = try SpotlightExtractor().extract(Fixtures.url("notes.odt"))
        XCTAssertEqual(e.title, "Flamant rose — フラミンゴ")
        XCTAssertEqual(Array(lines(e).prefix(3)), ["Les flamants roses filtrent la vase.", "フラミンゴは片足で立つ。", "Zoë Ångström"])
    }

    func testDispatcherFallsBackToSpotlight() throws {
        XCTAssertEqual(try Extract.extract(Fixtures.url("notes.odt")).title, "Flamant rose — フラミンゴ")
    }

    func testUnsupportedBinaryIsEmpty() throws {
        let f = try Fixtures.tempDir(self).appendingPathComponent("blob.xyzzy")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7919) }).write(to: f)
        XCTAssertEqual(try SpotlightExtractor().extract(f), .empty)
    }

    func testTruncatedDocumentDoesNotThrow() throws {
        let f = try Fixtures.tempDir(self).appendingPathComponent("cut.doc")
        try Data(contentsOf: Fixtures.url("legacy.doc")).prefix(3000).write(to: f)
        let e = try SpotlightExtractor().extract(f)
        XCTAssertFalse(e.text.contains("brine shrimp"))
    }

    func testMissingFileThrowsUnreadable() {
        let path = "/nonexistent/\(UUID()).doc"
        XCTAssertThrowsError(try SpotlightExtractor().extract(URL(fileURLWithPath: path))) {
            XCTAssertEqual($0 as? ExtractError, .unreadable(path))
        }
    }

    func testParsesHeaderWithBracesAndSkipsUnparseableEntries() {
        let output = """
            Imported '/tmp/odd {name}.doc' of type 'com.microsoft.word.doc' with plugIn /System/Library/Spotlight/Office.mdimporter.
            5 attributes returned
            {
                kMDItemAuthors =     (
                    "Zo\\U00eb",
                    Bob
                );
                kMDItemBlob = {length = 3, bytes = 0x010203};
                kMDItemKind =     {
                    "" = "Rich Text Document";
                };
                kMDItemTextContent = "One\\ntwo \\Ud83e\\Udda9\\n";
                kMDItemTitle = "<null>";
            }

            """
        let a = SpotlightExtractor.parseImport(Data(output.utf8))
        XCTAssertEqual(Set(a.keys), ["kMDItemAuthors", "kMDItemKind", "kMDItemTextContent", "kMDItemTitle"])
        let e = SpotlightExtractor.extracted(a, fileName: "odd {name}.doc")
        XCTAssertNil(e.title)
        XCTAssertEqual(e.text, "One\ntwo 🦩\nZoë, Bob\nRich Text Document")
    }

    func testKindAloneIsEmptyAndTitleEqualToFileNameIsDropped() {
        let kindOnly: [String: Any] = ["kMDItemKind": ["": "Document", "en": "Document"]]
        XCTAssertEqual(SpotlightExtractor.extracted(kindOnly, fileName: "a.bin"), .empty)
        let named: [String: Any] = ["kMDItemTitle": "report", "kMDItemTextContent": "x"]
        XCTAssertNil(SpotlightExtractor.extracted(named, fileName: "report.doc").title)
        let uti: [String: Any] = ["kMDItemKind": ["": "com.apple.iwork.keynote.alt-document"], "kMDItemTextContent": "x"]
        XCTAssertEqual(SpotlightExtractor.extracted(uti, fileName: "a.key").text, "x")
    }

    /// Eight concurrent extractions, as the indexer runs them. Target: 100 ms per warm extraction.
    func testConcurrentExtractionsAndCost() throws {
        let d = try Fixtures.tempDir(self)
        let files = try (0..<8).map { i -> URL in
            let f = d.appendingPathComponent("copy\(i).odt")
            try FileManager.default.copyItem(at: Fixtures.url("notes.odt"), to: f)
            return f
        }
        let cold = try Fixtures.time { _ = try SpotlightExtractor().extract(files[0]) }
        let results = Locked<[Int: Extracted]>([:])
        let parallel = Fixtures.time {
            DispatchQueue.concurrentPerform(iterations: files.count) { i in
                let e = try? SpotlightExtractor().extract(files[i])
                results.withLock { $0[i] = e }
            }
        }
        for i in files.indices { XCTAssertEqual(results.withLock { $0[i] }?.title, "Flamant rose — フラミンゴ", "copy \(i)") }
        let warm = try Fixtures.time { for f in files { _ = try SpotlightExtractor().extract(f) } } / Double(files.count)
        #if DEBUG
        print(String(format: "Spotlight: first %.0f ms, warm %.0f ms each, 8 concurrent %.0f ms", cold * 1000, warm * 1000, parallel * 1000))
        #endif
        XCTAssertLessThan(warm, 0.2)
    }
}

final class IWorkTests: XCTestCase {
    private let fakeDeck: [String: String] = [
        "Index/Document.iwa": "x", "Index/Metadata.iwa": "x",
        "Index/Slide-101.iwa": "x", "Index/Slide-102.iwa": "x", "Index/Slide-240.iwa": "x",
        "Index/TemplateSlide-7.iwa": "x", "Index/TemplateSlide-8.iwa": "x",
        "Data/st-A-1.jpg": "x", "Data/st-B-2.jpg": "x", "Data/st-C-3.jpg": "x", "Data/st-D-4.jpg": "x",
        "Metadata/Properties.plist": "x",
    ]

    func testSingleFileDeckGetsOneEmptySectionPerSlide() throws {
        let f = try Fixtures.tempDir(self).appendingPathComponent("deck.key")
        try Fixtures.zip(fakeDeck, to: f)
        let e = try IWorkExtractor().extract(f)
        XCTAssertEqual(e.sections, (1...3).map { Section(anchor: FileAnchor(kind: .slide, value: "\($0)"), text: "") })
    }

    func testPackageDecks() throws {
        let d = try Fixtures.tempDir(self)
        let modern = d.appendingPathComponent("modern.key")
        for (name, body) in fakeDeck {
            let f = modern.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(body.utf8).write(to: f)
        }
        XCTAssertEqual(IWorkExtractor.slideCount(modern), 3)

        let older = d.appendingPathComponent("older.key")
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        try Fixtures.zip(["Index/Document.iwa": "x", "Index/Slide.iwa": "x", "Index/Slide-2.iwa": "x"],
                         to: older.appendingPathComponent("Index.zip"))
        XCTAssertEqual(IWorkExtractor.slideCount(older), 2)
        XCTAssertEqual(try IWorkExtractor().extract(older).sections.map(\.anchor.value), ["1", "2"])
    }

    /// `.key` is also the extension of PEM private keys and API key files.
    func testKeyFileThatIsNotADeckIsEmpty() throws {
        let f = try Fixtures.tempDir(self).appendingPathComponent("server.key")
        try Data("-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\n-----END PRIVATE KEY-----\n".utf8).write(to: f)
        XCTAssertEqual(try Extract.extract(f), .empty)
    }

    func testPagesAndNumbersHaveNoSections() throws {
        let f = try Fixtures.tempDir(self).appendingPathComponent("doc.pages")
        try Fixtures.zip(fakeDeck, to: f)
        XCTAssertEqual(try IWorkExtractor().extract(f).sections, [])
    }

    /// Apple's own templates stand in for real documents, which can't be made without the apps.
    func testRealKeynoteThemeAndNumbersTemplate() throws {
        let theme = URL(fileURLWithPath: "/Applications/Keynote.app/Contents/SharedSupport/Templates/Gradient/Wide.kth")
        let template = URL(fileURLWithPath: "/Applications/Numbers.app/Contents/SharedSupport/Templates/21_Financial_Statement/Traditional.nmbtemplate")
        let fm = FileManager.default
        guard fm.fileExists(atPath: theme.path), fm.fileExists(atPath: template.path) else {
            throw XCTSkip("Keynote and Numbers templates not installed")
        }
        let d = try Fixtures.tempDir(self)
        let deck = d.appendingPathComponent("theme.key"), sheet = d.appendingPathComponent("statement.numbers")
        try fm.copyItem(at: theme, to: deck)
        try fm.copyItem(at: template, to: sheet)

        XCTAssertEqual(try IWorkExtractor().extract(deck).sections.map(\.anchor), [FileAnchor(kind: .slide, value: "1")])
        let numbers = try IWorkExtractor().extract(sheet)
        XCTAssertTrue(numbers.text.hasPrefix("Balance Sheet\n"), String(numbers.text.prefix(80)))
        XCTAssertEqual(numbers.sections, [])
    }
}
