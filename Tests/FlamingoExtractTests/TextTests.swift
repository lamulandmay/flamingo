import AppKit
import XCTest
import FlamingoCore
@testable import FlamingoExtract

final class TextTests: XCTestCase {
    private func line(_ n: Int) -> FileAnchor { FileAnchor(kind: .line, value: String(n)) }

    private func write(_ name: String, _ contents: String) throws -> URL {
        try write(name, Data(contents.utf8))
    }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = try Fixtures.tempDir(self).appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: Markdown

    func testMarkdownHeadingsAnchorsAndFrontMatterTitle() throws {
        let e = try TextExtractor().extract(Fixtures.url("notes.md"))
        XCTAssertEqual(e.title, "Field Notes")
        XCTAssertEqual(e.sections.map(\.title), [nil, "Overview", "Details", "Setext Title",
                                                 "Paragraph after a thematic break. Second line of it", "C#"])
        XCTAssertEqual(e.sections.map(\.anchor), [line(1), line(7), line(16), line(26), line(33), line(37)])

        let preamble = e.sections[0].text
        XCTAssertTrue(preamble.hasPrefix("---\ntitle: \"Field Notes\"\n"))
        XCTAssertTrue(preamble.hasSuffix("Opening words before any heading."))

        let overview = e.sections[1].text
        XCTAssertTrue(overview.hasPrefix("# Overview #\n\nThe plan in one paragraph."))
        XCTAssertTrue(overview.contains("# not a heading inside a backtick fence\nlet x = 1\n```"))
        XCTAssertTrue(overview.hasSuffix("```"), "trailing blank lines are trimmed")

        let details = e.sections[2].text
        for kept in ["## nor inside a tilde fence", "    # nor in indented code", "#hashtag is not a heading"] {
            XCTAssertTrue(details.contains(kept), kept)
        }
        XCTAssertEqual(e.sections[3].text, "Setext Title\n============\n\nText under the setext heading.\n\n---")
        XCTAssertEqual(e.sections[5].text, "### C# ##\n\nClosing hashes are dropped, the one in C# stays.")
        XCTAssertEqual(e.text, try String(contentsOf: Fixtures.url("notes.md"), encoding: .utf8))
    }

    func testMarkdownTitleFallsBackToFirstLevelOneHeading() throws {
        let e = try TextExtractor().extract(write("a.markdown", "## Intro\n\ntext\n\n#\n\n# Real Title\nbody\n"))
        XCTAssertEqual(e.title, "Real Title")
        XCTAssertEqual(e.sections.map(\.title), ["Intro", nil, "Real Title"])
        XCTAssertEqual(e.sections.map(\.anchor), [line(1), line(5), line(7)])

        let noTitle = try TextExtractor().extract(write("b.md", "---\ndate: 2026-10-14\n---\n## Only level two\n"))
        XCTAssertNil(noTitle.title)
        XCTAssertEqual(noTitle.sections.map(\.anchor), [line(1), line(4)])
        XCTAssertEqual(noTitle.sections[0].text, "---\ndate: 2026-10-14\n---")
    }

    func testMarkdownBlankPreambleCRLFAndUnclosedFence() throws {
        let e = try TextExtractor().extract(write("c.md", "\n  \n# A\r\nx\r\n  ## B ##\r\n```\r\n# inside\r\n"))
        XCTAssertEqual(e.sections.map(\.title), ["A", "B"])
        XCTAssertEqual(e.sections.map(\.anchor), [line(3), line(5)])
        XCTAssertEqual(e.sections[1].text, "  ## B ##\n```\n# inside")
        XCTAssertFalse(e.text.contains("\r"))

        let rules = try TextExtractor().extract(write("d.md", "intro\n\n***\n- item\n---\n> quote\n---\n"))
        XCTAssertEqual(rules.sections.count, 1, "rules after lists and quotes are not setext underlines")
        XCTAssertNil(rules.title)
    }

    func testMarkdownBenchmark() throws {
        let url = try Fixtures.tempDir(self).appendingPathComponent("big.md")
        let sentence = "Flamingos filter-feed on brine shrimp and blue-green algae in alkaline lakes. "
        let paragraph = String(repeating: sentence, count: 4) + "\n"
        var doc = "---\ntitle: Benchmark\n---\n"
        for k in 1...2000 {
            doc += "## Heading \(k)\n\n"
            for _ in 0..<8 { doc += paragraph }
            doc += "\n```python\n# a comment, not a heading\nprint(\(k))\n```\n\n"
        }
        try Data(doc.utf8).write(to: url)
        XCTAssertGreaterThanOrEqual(doc.utf8.count, 5_000_000)

        var e = Extracted.empty
        let t = try Fixtures.time { e = try TextExtractor().extract(url) }
        print(String(format: "TextExtractor markdown: %.1f MB, %d sections in %.3f s",
                     Double(doc.utf8.count) / 1_000_000, e.sections.count, t))
        XCTAssertEqual(e.sections.count, 2001)
        XCTAssertEqual(e.sections[2000].title, "Heading 2000")
        XCTAssertEqual(e.title, "Benchmark")
        XCTAssertLessThan(t, 1.0)
    }

    // MARK: Plain text and code

    func testCodeIsOneSectionWithTheWholeFile() throws {
        let url = Fixtures.url("sample.py")
        let e = try TextExtractor().extract(url)
        XCTAssertEqual(e.sections.count, 1)
        XCTAssertEqual(e.sections[0].anchor, line(1))
        XCTAssertNil(e.sections[0].title)
        XCTAssertNil(e.title)
        XCTAssertEqual(e.text, try String(contentsOf: url, encoding: .utf8))
        XCTAssertTrue(e.text.contains("def count(path):"))
    }

    func testEmptyAndBlankFilesHaveNoSections() throws {
        for (name, contents) in [("empty.txt", ""), ("blank.md", " \n\n\t\n"), ("blank.html", "\n"), ("empty.swift", "")] {
            let e = try TextExtractor().extract(write(name, contents))
            XCTAssertEqual(e, Extracted(text: ""), name)
        }
        let tagsOnly = try TextExtractor().extract(write("t.html", "<html><head><title>Only a title</title></head><body> </body></html>"))
        XCTAssertEqual(tagsOnly.text, "")
        XCTAssertTrue(tagsOnly.sections.isEmpty)
        XCTAssertEqual(tagsOnly.title, "Only a title")
    }

    func testExtensionlessAndUnknownFilesReadAsPlainText() throws {
        let makefile = try write("Makefile", "build:\r\n\tswift build\r\n")
        let e = try Extract.extract(makefile)
        XCTAssertEqual(e.text, "build:\n\tswift build\n")
        XCTAssertEqual(e.sections, [Section(anchor: line(1), text: "build:\n\tswift build\n")])

        let odd = try TextExtractor().extract(write("notes.unknownext", "# not markdown here\nplain"))
        XCTAssertEqual(odd.sections.count, 1)
        XCTAssertNil(odd.title)
    }

    func testExtensionsCoverTextFormatsOnly() {
        let ext = TextExtractor.extensions
        for e in ["txt", "md", "mdx", "swift", "py", "tsx", "yaml", "ipynb", "html", "xhtml", "rtf", "rtfd", "vtt", "tf"] {
            XCTAssertTrue(ext.contains(e), e)
        }
        for e in ["pdf", "docx", "pptx", "xlsx", "key", "pages", "numbers", "png", "jpg", "heic", "mp3", "mp4", "mov",
                  "usdz", "obj", "stl", "glb", "gltf", "zip"] {
            XCTAssertFalse(ext.contains(e), e)
        }
        XCTAssertEqual(ext, Set(ext.map { $0.lowercased() }))
    }

    // MARK: Decoding

    func testDecodingBOMsLatin1AndWindows1252() throws {
        let latin1 = try XCTUnwrap("café naïve\r\nzweite Zeile\rend".data(using: .isoLatin1))
        XCTAssertEqual(try TextExtractor().extract(write("l.txt", latin1)).text, "café naïve\nzweite Zeile\nend")

        let quotes = Data([0x93]) + Data("smart".utf8) + Data([0x94, 0x20, 0x80])
        XCTAssertEqual(try TextExtractor().extract(write("q.txt", quotes)).text, "\u{201C}smart\u{201D} €")

        let sample = "héllo\r\nwörld 日本"
        for enc in [String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian, .utf8] {
            let bom: [UInt8] = switch enc {
            case .utf16LittleEndian: [0xFF, 0xFE]
            case .utf16BigEndian: [0xFE, 0xFF]
            case .utf32LittleEndian: [0xFF, 0xFE, 0, 0]
            case .utf32BigEndian: [0, 0, 0xFE, 0xFF]
            default: [0xEF, 0xBB, 0xBF]
            }
            let data = Data(bom) + (try XCTUnwrap(sample.data(using: enc)))
            XCTAssertEqual(try TextExtractor().extract(write("u.txt", data)).text, "héllo\nwörld 日本", "\(enc)")
        }
    }

    func testHTMLDeclaredCharset() throws {
        var data = Data("<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=Shift_JIS\"></head><body><p>".utf8)
        data += try XCTUnwrap("日本語のページ".data(using: .shiftJIS))
        data += Data("</p></body></html>".utf8)
        XCTAssertEqual(try TextExtractor().extract(write("sjis.html", data)).text, "日本語のページ")
    }

    func testBinaryUnderATextExtensionThrows() throws {
        let video = try write("clip.ts", Data([0x47, 0x40, 0x00, 0x10, 0x00, 0x00, 0xB0, 0x0D] + Array(repeating: 0xFF, count: 180)))
        XCTAssertThrowsError(try TextExtractor().extract(video)) { XCTAssertEqual($0 as? ExtractError, .malformed(video.path)) }
        XCTAssertThrowsError(try TextExtractor().extract(URL(fileURLWithPath: "/nonexistent/\(UUID()).txt"))) {
            guard case .unreadable = $0 as? ExtractError else { return XCTFail("\($0)") }
        }
    }

    func testReadStopsAtEightMegabytesWithoutBreakingUTF8() throws {
        let limit = TextExtractor.readLimit
        var data = Data(repeating: UInt8(ascii: "a"), count: limit - 1)
        data += Data("é and more past the limit".utf8)
        let e = try TextExtractor().extract(write("big.log", data))
        XCTAssertEqual(e.text.utf8.count, limit - 1)
        XCTAssertTrue(e.text.utf8.allSatisfy { $0 == UInt8(ascii: "a") }, "decoded as UTF-8, split character dropped")
    }

    // MARK: HTML

    func testHTMLTextTitleAndEntities() throws {
        let e = try TextExtractor().extract(Fixtures.url("page.html"))
        XCTAssertEqual(e.title, "Flamingo & Friends")
        XCTAssertEqual(e.sections.count, 1)
        XCTAssertEqual(e.sections[0].anchor, line(1))
        for gone in ["secretScriptValue", "not text", "injectedByScript", "pink", "hidden-style-rule", "a comment", "DOCTYPE", "Flamingo &"] {
            XCTAssertFalse(e.text.contains(gone), gone)
        }
        XCTAssertEqual(e.text, """
            Colony report

            Café — open at 9 <sharp>. Wrapped source lines collapse.

            It’s bold and linked.

            First item
            Second item

            Colony\tCount
            Lake Natron\t2,500

            keep   this
              spacing

            Line one
            Line two
            """)
    }

    func testHTMLTitleFallsBackToFirstH1() throws {
        let html = "<body><H2>Sub</H2><h1 class=x>The &ldquo;Main&rdquo;\n Heading</h1><h1>Second</h1><p>a &amp;amp; b &bogus; c&nbsp;d &#x1F9A9;</p></body>"
        let e = try TextExtractor().extract(write("h.htm", html))
        XCTAssertEqual(e.title, "The \u{201C}Main\u{201D} Heading")
        XCTAssertEqual(e.text, "Sub\n\nThe \u{201C}Main\u{201D} Heading\n\nSecond\n\na &amp; b &bogus; c\u{00A0}d \u{1F9A9}")
    }

    func testHTMLTruncatedMarkupDoesNotCrash() throws {
        for html in ["<p>unterminated <b class=\"x", "<script>never closed", "<!-- open comment", "a < b and c <", "<title>t"] {
            XCTAssertNoThrow(try TextExtractor().extract(write("x.html", html)), html)
        }
        XCTAssertEqual(try TextExtractor().extract(write("lt.html", "a < b and 3<4")).text, "a < b and 3<4")
    }

    // MARK: Notebooks

    func testNotebookCellsInOrderWithoutOutputs() throws {
        let nb = """
            {"cells": [
              {"cell_type": "markdown", "metadata": {}, "source": ["# Sighting analysis\\n", "\\n", "Counts by colony."]},
              {"cell_type": "code", "execution_count": 1, "metadata": {},
               "outputs": [{"output_type": "stream", "name": "stdout", "text": ["OUTPUT_SHOULD_NOT_APPEAR\\n"]}],
               "source": ["import pandas as pd\\n", "# comment in code\\n", "df = pd.read_csv('s.csv')\\n"]},
              {"cell_type": "code", "metadata": {}, "outputs": [], "source": []},
              {"cell_type": "markdown", "metadata": {}, "source": "## Next steps\\nMore data."}
            ], "metadata": {}, "nbformat": 4, "nbformat_minor": 5}
            """
        let url = try write("a.ipynb", nb)
        let e = try TextExtractor().extract(url)
        XCTAssertEqual(e.title, "Sighting analysis")
        XCTAssertEqual(e.sections.count, 1)
        XCTAssertEqual(e.text, "# Sighting analysis\n\nCounts by colony.\n\nimport pandas as pd\n# comment in code\ndf = pd.read_csv('s.csv')\n\n## Next steps\nMore data.")
        XCTAssertFalse(e.text.contains("OUTPUT_SHOULD_NOT_APPEAR"))

        let truncated = try write("t.ipynb", Data(nb.utf8.prefix(120)))
        XCTAssertThrowsError(try TextExtractor().extract(truncated)) { XCTAssertEqual($0 as? ExtractError, .malformed(truncated.path)) }
    }

    // MARK: Rich text

    func testRTFTextAndTitle() throws {
        let e = try TextExtractor().extract(Fixtures.url("memo.rtf"))
        XCTAssertEqual(e.title, "Q3 Memo")
        XCTAssertEqual(e.sections.count, 1)
        XCTAssertEqual(e.text, "Quarterly memo\nCafé budget review — naïve estimates.\nLine one\nLine two after a soft break\nColony\tCount\nNatron\t2500")
    }

    func testRTFOffTheMainThreadConcurrently() throws {
        let url = Fixtures.url("memo.rtf")
        let expected = try TextExtractor().extract(url)
        let results = Locked<[Extracted?]>(Array(repeating: nil, count: 24))
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global(qos: .utility).async {
            DispatchQueue.concurrentPerform(iterations: 24) { k in
                let e = try? TextExtractor().extract(url)
                results.withLock { $0[k] = e }
            }
            done.leave()
        }
        // Blocks the main thread without spinning its run loop: if the RTF reader needed the
        // main thread this would time out instead of passing.
        XCTAssertEqual(done.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(results.withLock { $0 }, Array(repeating: expected, count: 24) as [Extracted?])
    }

    func testRTFDPackage() throws {
        let s = NSMutableAttributedString(string: "Before the picture ")
        let wrapper = FileWrapper(regularFileWithContents: Data("attached".utf8))
        wrapper.preferredFilename = "note.txt"
        s.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        s.append(NSAttributedString(string: " after it."))
        let url = try Fixtures.tempDir(self).appendingPathComponent("Pictures.rtfd")
        let package = try XCTUnwrap(s.rtfdFileWrapper(from: NSRange(location: 0, length: s.length), documentAttributes: [:]))
        try package.write(to: url, options: .atomic, originalContentsURL: nil)

        let e = try TextExtractor().extract(url)
        XCTAssertEqual(e.text, "Before the picture  after it.")
        XCTAssertEqual(try Extract.extract(url).text, e.text)
    }

    func testCorruptRTFThrowsOrComesBackEmpty() throws {
        let rtf = try Data(contentsOf: Fixtures.url("memo.rtf"))
        for (name, data) in [("garbage.rtf", Data((0..<2048).map { UInt8(truncatingIfNeeded: $0 &* 31) })),
                             ("half.rtf", rtf.prefix(rtf.count / 2)), ("empty.rtf", Data())] {
            let url = try write(name, data)
            do {
                let e = try TextExtractor().extract(url)
                XCTAssertFalse(e.text.contains("\\rtf"), name)
            } catch {
                XCTAssertEqual(error as? ExtractError, .malformed(url.path), name)
            }
        }
        XCTAssertThrowsError(try TextExtractor().extract(write("plain.rtf", "this is not rtf at all")))
    }
}
