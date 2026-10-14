import XCTest
import CoreText
import PDFKit
import FlamingoCore
@testable import FlamingoExtract

final class PDFTests: XCTestCase {
    func testPaperPagesTitlesAndText() throws {
        let url = Fixtures.url("paper.pdf")
        let e = try PDFExtractor().extract(url)
        XCTAssertEqual(e.title, "Tidal Patterns in Urban Foot Traffic")
        XCTAssertEqual(e.sections.map(\.anchor), (1...4).map { FileAnchor(kind: .page, value: "\($0)") })
        XCTAssertEqual(e.sections.map(\.title), ["Introduction", "Related Work", nil, "Evaluation"])
        let pages = e.sections.map { flat($0.text) }
        XCTAssertTrue(pages[0].hasPrefix("Introduction Pedestrian counts in dense neighbourhoods rise and fall twice a day"), pages[0])
        XCTAssertTrue(pages[1].contains("Earlier sensor studies in Copenhagen"))
        XCTAssertTrue(pages[2].contains("calibrated against 312 hours of manual counts"))
        XCTAssertTrue(pages[3].contains("explained 87 percent of hourly variance"))
        XCTAssertFalse(pages[0].contains("Copenhagen"))
        XCTAssertEqual(e.text, e.sections.map(\.text).joined(separator: "\n\n"))
        XCTAssertEqual(try Extract.extract(url), e)
    }

    func testTitleFallsBackToFirstTopLevelOutlineLabel() throws {
        let d = try Fixtures.tempDir(self)
        let withOutline = d.appendingPathComponent("a.pdf"), bare = d.appendingPathComponent("b.pdf")
        try PDFBuilder.make(pages: ["One", "Two"], title: nil,
                            outline: [.init("  Overview\r\n", page: 2, [.init("Detail,\r\n  continued", page: 1)])]).write(to: withOutline)
        try PDFBuilder.make(pages: ["One"], title: nil, outline: []).write(to: bare)
        let a = try PDFExtractor().extract(withOutline)
        XCTAssertEqual(a.title, "Overview")
        XCTAssertEqual(a.sections.map(\.title), ["Detail, continued", "Overview"])
        let b = try PDFExtractor().extract(bare)
        XCTAssertNil(b.title)
        XCTAssertEqual(b.sections, [Section(anchor: .init(kind: .page, value: "1"), text: "One")])
    }

    func testPasswordLockedPDFYieldsNoText() throws {
        let doc = try XCTUnwrap(PDFDocument(url: Fixtures.url("paper.pdf")))
        let f = try Fixtures.tempDir(self).appendingPathComponent("locked.pdf")
        XCTAssertTrue(doc.write(to: f, withOptions: [.userPasswordOption: "s3cret", .ownerPasswordOption: "owner"]))
        let e = try PDFExtractor().extract(f)
        XCTAssertEqual(e.text, "")
        XCTAssertEqual(e.sections, [])
    }

    func testOwnerPasswordOnlyStillExtracts() throws {
        let doc = try XCTUnwrap(PDFDocument(url: Fixtures.url("paper.pdf")))
        let f = try Fixtures.tempDir(self).appendingPathComponent("owner.pdf")
        XCTAssertTrue(doc.write(to: f, withOptions: [.ownerPasswordOption: "owner"]))
        let e = try PDFExtractor().extract(f)
        XCTAssertEqual(e.sections.count, 4)
        XCTAssertTrue(flat(e.text).contains("explained 87 percent"))
    }

    func testCorruptAndTruncatedFilesThrowOrComeBackPartial() throws {
        let d = try Fixtures.tempDir(self)
        let junk = d.appendingPathComponent("junk.pdf"), empty = d.appendingPathComponent("empty.pdf")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7919) }).write(to: junk)
        try Data().write(to: empty)
        for f in [junk, empty] {
            XCTAssertThrowsError(try PDFExtractor().extract(f)) { XCTAssertEqual($0 as? ExtractError, .malformed(f.path)) }
        }
        let whole = try Data(contentsOf: Fixtures.url("paper.pdf"))
        for fraction in [0.1, 0.5, 0.9] {
            let f = d.appendingPathComponent("cut-\(fraction).pdf")
            try whole.prefix(Int(Double(whole.count) * fraction)).write(to: f)
            if let e = try? PDFExtractor().extract(f) { XCTAssertLessThanOrEqual(e.sections.count, 4) }
        }
        XCTAssertNoThrow(try Extract.extract(junk))
    }

    func testCleanNormalisesLineEndingsAndNULs() {
        XCTAssertEqual(PDFExtractor.clean(" a\r\nb\rc\0d\n "), "a\nb\ncd")
        XCTAssertNil(PDFExtractor.clean("\0 \r\n"))
        XCTAssertNil(PDFExtractor.clean(nil))
        XCTAssertEqual(PDFExtractor.title(" Results\r\n and\tDiscussion\0 "), "Results and Discussion")
    }

    /// PDFKit off the main thread, many documents at once: each result must match the serial one.
    func testConcurrentExtractionOffMainThread() throws {
        let d = try Fixtures.tempDir(self)
        var urls = [Fixtures.url("paper.pdf")]
        for n in 0..<5 {
            let f = d.appendingPathComponent("doc\(n).pdf")
            try PDFBuilder.make(pages: (1...(n + 3)).map { "Document \(n) page \($0). " + PDFBuilder.filler(seed: n * 10 + $0) },
                                title: "Doc \(n)", outline: [.init("Start \(n)", page: 1)]).write(to: f)
            urls.append(f)
        }
        let serial = try urls.map { try PDFExtractor().extract($0) }
        let results = Locked<[Int: Extracted]>([:])
        let mainHits = Locked(0)
        let done = expectation(description: "parallel")
        DispatchQueue.global(qos: .utility).async {
            DispatchQueue.concurrentPerform(iterations: 48) { i in
                if Thread.isMainThread { mainHits.withLock { $0 += 1 } }
                if let e = try? PDFExtractor().extract(urls[i % urls.count]) { results.withLock { $0[i] = e } }
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        XCTAssertEqual(mainHits.withLock { $0 }, 0)
        let got = results.withLock { $0 }
        XCTAssertEqual(got.count, 48)
        for (i, e) in got { XCTAssertEqual(e, serial[i % urls.count], "iteration \(i)") }
        XCTAssertEqual(serial[3].sections.count, 5)
        XCTAssertEqual(serial[3].title, "Doc 2")
    }

    func testBenchmark100Pages() throws {
        let f = try Fixtures.tempDir(self).appendingPathComponent("long.pdf")
        let pages = (1...100).map { "Page \($0). " + PDFBuilder.filler(seed: $0) }
        let outline = stride(from: 1, through: 100, by: 10).map { PDFBuilder.Entry("Chapter \($0 / 10 + 1)", page: $0) }
        try PDFBuilder.make(pages: pages, title: "Long", outline: outline).write(to: f)
        var e = Extracted.empty
        let t = try Fixtures.time { e = try PDFExtractor().extract(f) }
        print(String(format: "PDF benchmark: 100 pages, %d chars in %.3f s", e.text.count, t))
        XCTAssertEqual(e.sections.count, 100)
        XCTAssertEqual(e.sections[10].title, "Chapter 2")
        XCTAssertTrue(e.sections[99].text.hasPrefix("Page 100."))
        XCTAssertLessThan(t, 2)
    }

    /// Rewrites the committed fixture. Run with `FLAMINGO_REGENERATE_FIXTURES=1`.
    func testRegenerateFixture() throws {
        guard ProcessInfo.processInfo.environment["FLAMINGO_REGENERATE_FIXTURES"] == "1" else {
            throw XCTSkip("set FLAMINGO_REGENERATE_FIXTURES=1 to rewrite paper.pdf")
        }
        try PDFBuilder.paper().write(to: Fixtures.url("paper.pdf"))
    }

    private func flat(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Text PDFs drawn with CoreText into a CoreGraphics PDF context, which also writes the Info
/// title and the outline. (PDFKit on macOS 27 drops an outline added to a document it opened from
/// data or a URL, so it can't be used to add one after the fact.)
enum PDFBuilder {
    struct Entry {
        var label: String, page: Int, children: [Entry]
        init(_ label: String, page: Int, _ children: [Entry] = []) { self.label = label; self.page = page; self.children = children }
        /// The `CGPDFContextSetOutline` form; destinations are one-based page numbers.
        var dictionary: [String: Any] {
            var d: [String: Any] = [kCGPDFOutlineTitle as String: label, kCGPDFOutlineDestination as String: page]
            if !children.isEmpty { d[kCGPDFOutlineChildren as String] = children.map(\.dictionary) }
            return d
        }
    }

    /// The committed `paper.pdf`: four pages, an Info title, and a nested outline that names
    /// pages 1, 2 and 4. Page 3 continues page 2 and has no entry. "Motivation" and "Results"
    /// point at pages their parents already claimed, so the parent's label must win.
    static func paper() throws -> Data {
        let pages = [
            """
            Introduction

            Pedestrian counts in dense neighbourhoods rise and fall twice a day, much like tides. \
            We model hourly foot traffic on 41 shopping corridors as the sum of a commuter wave, a \
            lunchtime swell and a slow evening ebb, and ask how much of the variance that shape explains.
            """,
            """
            Related Work

            Earlier sensor studies in Copenhagen and Melbourne fitted daily profiles per street but \
            treated each corridor independently. Gravity models of retail catchment explain where \
            people go, not when.
            """,
            """
            Infrared beam counters were mounted at both ends of each corridor and calibrated against \
            312 hours of manual counts. Days with sensor faults or street closures were dropped, \
            leaving 9,840 corridor-days.
            """,
            """
            Evaluation

            Across 41 corridors the tidal model explained 87 percent of hourly variance, against 64 \
            percent for a per-street daily mean. Residuals were largest on market days and during \
            school holidays.
            """,
        ]
        let outline: [Entry] = [
            .init("Introduction", page: 1, [.init("Motivation", page: 1), .init("Related Work", page: 2)]),
            .init("Evaluation", page: 4, [.init("Results", page: 4)]),
        ]
        return try make(pages: pages, title: "Tidal Patterns in Urban Foot Traffic", outline: outline)
    }

    /// About 2,500 characters of deterministic prose, different per seed.
    static func filler(seed: Int) -> String {
        let words = ["corridor", "tide", "sensor", "evening", "commuter", "variance", "market", "street",
                     "hourly", "counts", "model", "swell", "ebb", "residual", "holiday", "catchment"]
        var x = UInt64(seed) &* 6364136223846793005 &+ 1442695040888963407
        return (0..<360).map { _ in
            x = x &* 6364136223846793005 &+ 1442695040888963407
            return words[Int(x >> 60)]
        }.joined(separator: " ")
    }

    static func make(pages: [String], title: String?, outline: [Entry]) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let info = title.map { [kCGPDFContextTitle as String: $0] as CFDictionary }
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, info) else { throw CocoaError(.fileWriteUnknown) }
        let font = CTFontCreateWithName("Helvetica" as CFString, 11, nil)
        for text in pages {
            ctx.beginPDFPage(nil)
            let s = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let framesetter = CTFramesetterCreateWithAttributedString(s)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                                 CGPath(rect: box.insetBy(dx: 72, dy: 72), transform: nil), nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
        }
        if !outline.isEmpty { CGPDFContextSetOutline(ctx, [kCGPDFOutlineChildren as String: outline.map(\.dictionary)] as CFDictionary) }
        ctx.closePDF()
        return data as Data
    }
}
