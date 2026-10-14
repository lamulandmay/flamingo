import XCTest
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import FlamingoExtract

final class ImageTests: XCTestCase {
    func testSignIsRecognisedTopToBottomWithIPTCMetadata() throws {
        let e = try ImageExtractor().extract(Fixtures.url("sign.png"))
        XCTAssertEqual(e.title, "Lagoon Sign")
        XCTAssertTrue(e.sections.isEmpty)
        let lines = e.text.components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.prefix(3)), ["Lagoon Sign", "Road sign near the salt flats", "flamingo, signage"])
        let crossing = try XCTUnwrap(lines.firstIndex { $0.localizedCaseInsensitiveContains("flamingo crossing") }, e.text)
        let next = try XCTUnwrap(lines.firstIndex { $0.localizedCaseInsensitiveContains("next 2 miles") }, e.text)
        XCTAssertLessThan(crossing, next)
    }

    func testIconSizedImagesSkipOCR() throws {
        let d = try Fixtures.tempDir(self)
        for (name, w, h) in [("icon.png", 200, 200), ("sliver.png", 1200, 40)] {
            let f = d.appendingPathComponent(name)
            try ImageFixtures.write(ImageFixtures.render(["HELLO"], width: w, height: h, size: 30), to: f, type: .png)
            XCTAssertEqual(try ImageExtractor().extract(f), Extracted(text: ""), name)
        }
    }

    func testOnlyTheFirstGIFFrameIsRead() throws {
        let f = try Fixtures.tempDir(self).appendingPathComponent("anim.gif")
        let frames = [ImageFixtures.render(["ALPHA FRAME"], width: 480, height: 160, size: 48),
                      ImageFixtures.render(["OMEGA FRAME"], width: 480, height: 160, size: 48)]
        let dst = try XCTUnwrap(CGImageDestinationCreateWithURL(f as CFURL, UTType.gif.identifier as CFString, frames.count, nil))
        for frame in frames { CGImageDestinationAddImage(dst, frame, nil) }
        XCTAssertTrue(CGImageDestinationFinalize(dst))
        let text = try ImageExtractor().extract(f).text
        XCTAssertTrue(text.localizedCaseInsensitiveContains("alpha"), text)
        XCTAssertFalse(text.localizedCaseInsensitiveContains("omega"), text)
    }

    func testCorruptAndTruncatedImagesThrowMalformed() throws {
        let d = try Fixtures.tempDir(self)
        let garbage = d.appendingPathComponent("garbage.png")
        try Data((0..<2048).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: garbage)
        XCTAssertThrowsError(try ImageExtractor().extract(garbage)) { XCTAssertEqual($0 as? ExtractError, .malformed(garbage.path)) }
        let truncated = d.appendingPathComponent("truncated.png")
        try Data(try Data(contentsOf: Fixtures.url("sign.png")).prefix(64)).write(to: truncated)
        XCTAssertThrowsError(try ImageExtractor().extract(truncated))
        XCTAssertNoThrow(try Extract.extract(garbage))
    }

    func testReadingOrderGroupsRowsLeftToRight() {
        let lines: [(box: CGRect, text: String)] = [
            (CGRect(x: 0.1, y: 0.10, width: 0.3, height: 0.05), "bottom"),
            (CGRect(x: 0.6, y: 0.81, width: 0.3, height: 0.05), "top right"),
            (CGRect(x: 0.1, y: 0.80, width: 0.3, height: 0.05), "top left"),
            (CGRect(x: 0.1, y: 0.50, width: 0.3, height: 0.05), "middle"),
        ]
        XCTAssertEqual(ImageExtractor.readingOrder(lines), ["top left", "top right", "middle", "bottom"])
    }

    /// A 1920x1080 screenshot-like image with two columns of text: decode plus accurate OCR.
    /// Target 1 s. Vision is warmed up first: its first request on a machine compiles models.
    func testScreenshotOCRTime() throws {
        let f = try Fixtures.tempDir(self).appendingPathComponent("screenshot.png")
        let lines = (1...24).map { "Quarterly review item \($0): pricing for region \($0 * 7)" }
        try ImageFixtures.write(ImageFixtures.render(lines, width: 1920, height: 1080, size: 26, columns: 2), to: f, type: .png)
        _ = try ImageExtractor().extract(Fixtures.url("sign.png"))
        var e = Extracted.empty
        let seconds = try Fixtures.time { e = try ImageExtractor().extract(f) }
        #if DEBUG
        print("ImageExtractor OCR 1920x1080: \(String(format: "%.2f", seconds)) s, \(e.text.split(separator: "\n").count) lines")
        #endif
        XCTAssertTrue(e.text.contains("Quarterly review item 12"), e.text)
        XCTAssertLessThan(seconds, 2)
    }

    func testRegenerateSignFixture() throws {
        guard ProcessInfo.processInfo.environment["FLAMINGO_REGENERATE_FIXTURES"] == "1" else { throw XCTSkip("set FLAMINGO_REGENERATE_FIXTURES=1") }
        let image = ImageFixtures.render(["FLAMINGO CROSSING", "Next 2 miles"], width: 640, height: 240, size: 48)
        try ImageFixtures.write(image, to: Fixtures.url("sign.png"), type: .png, properties: [
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCObjectName: "Lagoon Sign",
                                             kCGImagePropertyIPTCCaptionAbstract: "Road sign near the salt flats",
                                             kCGImagePropertyIPTCKeywords: ["flamingo", "signage"]],
        ])
    }
}

/// Draws black Helvetica text on white with Core Graphics, so fixtures need no AppKit.
private enum ImageFixtures {
    static func render(_ lines: [String], width: Int, height: Int, size: CGFloat, columns: Int = 1) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [kCTFontAttributeName as NSAttributedString.Key: font,
                                                         kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0, alpha: 1)]
        let perColumn = (lines.count + columns - 1) / columns
        let leading = size * 1.6
        let top = (CGFloat(height) + CGFloat(perColumn - 1) * leading - size * 0.7) / 2
        for (i, line) in lines.enumerated() {
            ctx.textPosition = CGPoint(x: CGFloat(i / perColumn) * CGFloat(width) / CGFloat(columns) + size,
                                       y: top - CGFloat(i % perColumn) * leading)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes)), ctx)
        }
        return ctx.makeImage()!
    }

    static func write(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any] = [:]) throws {
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dst, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { throw CocoaError(.fileWriteUnknown) }
    }
}
