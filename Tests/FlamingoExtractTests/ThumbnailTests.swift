import XCTest
import AppKit
import CryptoKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers
import FlamingoCore
@testable import FlamingoExtract

/// Thumbnails against a temp vault. Source files are drawn at test time so their pixels are known:
/// PNGs are pink with a white center square, the PDF's first page is white with a blue center.
final class ThumbnailTests: XCTestCase {
    private var root: URL!
    private var thumbs: URL { root.appendingPathComponent(".flamingo/thumbs") }

    override func setUpWithError() throws {
        root = try Fixtures.tempDir(self)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".flamingo"), withIntermediateDirectories: true)
    }

    func testPNGThumbnailIsCachedAtTheDocumentedPath() async throws {
        let file = try png("img/photo.png", 1200, 800)
        let image = try await thumb(file, 64)
        XCTAssertEqual(image.size.width, 64, accuracy: 0.01)
        XCTAssertEqual(image.size.height, 64 * 800 / 1200, accuracy: 0.5)
        assertColor(image, at: CGPoint(x: 0.5, y: 0.5), red: 1, green: 1, blue: 1)
        assertColor(image, at: CGPoint(x: 0.05, y: 0.05), red: 1, green: 0.2, blue: 0.6)

        let expected = try expectedPNG(file, rel: "img/photo.png")
        XCTAssertEqual(Thumbnails.cachedURL(for: file), expected)
        XCTAssertEqual(try contents(thumbs), [expected.lastPathComponent])
        XCTAssertEqual(pixels(expected)?.width, 128)
        XCTAssertEqual(try contents(root), [".flamingo", "img"])
        XCTAssertEqual(try contents(root.appendingPathComponent("img")), ["photo.png"])
    }

    func testPDFThumbnailIsTheFirstPageAndExplicitVaultCreatesTheCache() async throws {
        let bare = try Fixtures.tempDir(self)
        let file = try pdf(bare.appendingPathComponent("docs/report.pdf"), pages: 3)
        let vault = Vault(root: bare)
        let made = await Thumbnails.thumbnail(for: file, in: vault, size: CGSize(width: 100, height: 100))
        let image = try XCTUnwrap(made)
        XCTAssertEqual(image.size.height, 100, accuracy: 0.01)
        XCTAssertEqual(image.size.width, 100 * 612 / 792, accuracy: 0.5)
        assertColor(image, at: CGPoint(x: 0.5, y: 0.5), red: 0, green: 0.3, blue: 1)

        root = bare
        let expected = try expectedPNG(file, rel: "docs/report.pdf")
        XCTAssertEqual(try contents(thumbs), [expected.lastPathComponent])
        XCTAssertEqual(Thumbnails.cachedURL(for: file, in: vault), expected)
        XCTAssertEqual(Thumbnails.cachedURL(for: file), expected, "the .flamingo it created makes the folder a vault")
        XCTAssertEqual(pixels(expected)?.height, 200)
    }

    func testSecondRequestIsServedFromTheDiskCache() async throws {
        let file = try png("a.png", 1600, 1200)
        var t = Date()
        _ = try await thumb(file, 128)
        let first = Date().timeIntervalSince(t)
        let cache = try expectedPNG(file, rel: "a.png")
        let written = try Data(contentsOf: cache)
        let writtenAt = try modified(cache)

        t = Date()
        let again = try await thumb(file, 128)
        let second = Date().timeIntervalSince(t)
        XCTAssertEqual(try Data(contentsOf: cache), written)
        XCTAssertEqual(try modified(cache), writtenAt)
        assertColor(again, at: CGPoint(x: 0.5, y: 0.5), red: 1, green: 1, blue: 1)
        print(String(format: "thumbnail: generated in %.1f ms, from cache in %.1f ms", first * 1000, second * 1000))
        XCTAssertLessThan(second, first)

        // A marker PNG in the cache slot comes back, so the cache is read and Quick Look isn't.
        try solidPNG(width: 256, height: 192, red: 0, green: 1, blue: 0).write(to: cache)
        let marked = try await thumb(file, 128)
        assertColor(marked, at: CGPoint(x: 0.5, y: 0.5), red: 0, green: 1, blue: 0)
        XCTAssertEqual(marked.size.width, 128, accuracy: 0.01)
    }

    func testTouchingTheFileChangesCachedURL() async throws {
        let file = try png("a.png", 400, 300)
        _ = try await thumb(file, 64)
        let before = try XCTUnwrap(Thumbnails.cachedURL(for: file))

        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600.25)], ofItemAtPath: file.path)
        XCTAssertNil(Thumbnails.cachedURL(for: file))
        _ = try await thumb(file, 64)
        let after = try XCTUnwrap(Thumbnails.cachedURL(for: file))
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(after, try expectedPNG(file, rel: "a.png"))
    }

    func testPruneKeepsCurrentThumbnailsAndDropsStaleOnes() async throws {
        let kept = try png("kept.png", 400, 300)
        let edited = try png("edited.png", 400, 300)
        let gone = try png("gone.png", 400, 300)
        for f in [kept, edited, gone] { _ = try await thumb(f, 64) }
        let stale = try XCTUnwrap(Thumbnails.cachedURL(for: edited))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: edited.path)
        try FileManager.default.removeItem(at: gone)

        XCTAssertEqual(Thumbnails.pruneCache(in: Vault(root: root)), 2)
        XCTAssertNotNil(Thumbnails.cachedURL(for: kept))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertEqual(Thumbnails.pruneCache(in: Vault(root: root)), 0)
    }

    func testGenerationGivesUpAtTheTimeout() async throws {
        let file = try png("slow.png", 400, 300)
        let request = { QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: 64, height: 64), scale: 1,
                                                     representationTypes: .thumbnail) }
        let t = Date()
        let none = await Thumbnails.generate(request(), timeout: 0)
        XCTAssertNil(none)
        XCTAssertLessThan(Date().timeIntervalSince(t), 1)
        let some = await Thumbnails.generate(request())
        XCTAssertNotNil(some)
    }

    func testLargerRequestRegeneratesAndSmallerOnesAreDownsampled() async throws {
        let file = try png("wide.png", 1500, 1000)
        _ = try await thumb(file, 32)
        let cache = try expectedPNG(file, rel: "wide.png")
        XCTAssertEqual(pixels(cache)?.width, 64)

        let big = try await thumb(file, 256)
        XCTAssertEqual(pixels(cache)?.width, 512, "overwritten in place at the larger size")
        XCTAssertEqual(try contents(thumbs).count, 1)
        XCTAssertEqual(big.size.width, 256, accuracy: 0.01)
        XCTAssertEqual(big.size.height, 256 * 1000 / 1500, accuracy: 0.5)

        let written = try Data(contentsOf: cache)
        let small = try await thumb(file, 32)
        XCTAssertEqual(try Data(contentsOf: cache), written, "a smaller request reuses the bigger PNG")
        XCTAssertEqual(small.size.width, 32, accuracy: 0.01)
        XCTAssertEqual(small.representations.first?.pixelsWide, 64, "decoded at the requested size")
    }

    func testSmallSourceIsNotRegeneratedForEveryBiggerRequest() async throws {
        let file = try png("icon.png", 40, 30)
        let image = try await thumb(file, 256)
        XCTAssertEqual(image.size.width, 256, accuracy: 0.01)
        XCTAssertEqual(image.size.height, 192, accuracy: 0.01)
        let cache = try expectedPNG(file, rel: "icon.png")
        XCTAssertEqual(pixels(cache)?.width, 40, "Quick Look doesn't upscale")
        let written = try modified(cache)
        _ = try await thumb(file, 256)
        _ = try await thumb(file, 200)
        XCTAssertEqual(try modified(cache), written)
    }

    func testFileOutsideAnyVaultIsCachedInMemoryOnly() async throws {
        let bare = try Fixtures.tempDir(self)
        let file = try png(bare.appendingPathComponent("loose.png"), 300, 300)
        let image = try await thumb(file, 64)
        XCTAssertEqual(image.size, CGSize(width: 64, height: 64))
        XCTAssertNil(Thumbnails.cachedURL(for: file))
        XCTAssertNil(Thumbnails.enclosingVault(of: file))
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: bare.path), ["loose.png"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: bare.deletingLastPathComponent().appendingPathComponent(".flamingo").path))

        let again = try await thumb(file, 64)
        XCTAssertTrue(cgImage(again) === cgImage(image), "served from memory")
    }

    func testMissingAndUnthumbnailableFilesReturnNil() async throws {
        let missing = await Thumbnails.thumbnail(for: root.appendingPathComponent("nope.png"), size: CGSize(width: 64, height: 64))
        XCTAssertNil(missing)
        let outside = await Thumbnails.thumbnail(for: URL(fileURLWithPath: "/nonexistent/x.pdf"), size: CGSize(width: 64, height: 64))
        XCTAssertNil(outside)

        let blob = root.appendingPathComponent("blob.bin")
        var x: UInt32 = 1
        try Data((0..<4096).map { _ in x = x &* 1_664_525 &+ 1_013_904_223; return UInt8(x >> 24) }).write(to: blob)
        let none = await Thumbnails.thumbnail(for: blob, size: CGSize(width: 64, height: 64))
        XCTAssertNil(none, "no icon fallback")
        XCTAssertNil(Thumbnails.cachedURL(for: blob))
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbs.path))
    }

    func testCorruptCacheFileIsRegenerated() async throws {
        let file = try png("a.png", 400, 300)
        let cache = try expectedPNG(file, rel: "a.png")
        try FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
        try Data("not a png".utf8).write(to: cache)
        let image = try await thumb(file, 64)
        assertColor(image, at: CGPoint(x: 0.5, y: 0.5), red: 1, green: 1, blue: 1)
        XCTAssertEqual(pixels(cache)?.width, 128)
    }

    func testConcurrentRequestsShareOneGeneration() async throws {
        let file = try png("big.png", 3000, 2000)
        let images = await withTaskGroup(of: NSImage?.self) { group in
            for _ in 0..<30 { group.addTask { await Thumbnails.thumbnail(for: file, size: CGSize(width: 64, height: 64)) } }
            return await group.reduce(into: [NSImage?]()) { $0.append($1) }
        }
        let cgs = images.compactMap { $0.flatMap(cgImage) }
        XCTAssertEqual(cgs.count, 30)
        XCTAssertEqual(Set(cgs.map(ObjectIdentifier.init)).count, 1, "one generation, shared")
        XCTAssertEqual(try contents(thumbs).count, 1)
    }

    // MARK: - Helpers

    private func thumb(_ url: URL, _ side: CGFloat, file: StaticString = #filePath, line: UInt = #line) async throws -> NSImage {
        let image = await Thumbnails.thumbnail(for: url, size: CGSize(width: side, height: side))
        return try XCTUnwrap(image, file: file, line: line)
    }

    /// Where the cache must put `file`'s thumbnail, from the documented recipe.
    private func expectedPNG(_ file: URL, rel: String) throws -> URL {
        var st = stat()
        XCTAssertEqual(stat(file.path, &st), 0)
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        let hex = SHA256.hash(data: Data("\(rel)\n\(mtime)".utf8)).map { String(format: "%02x", $0) }.joined()
        return thumbs.appendingPathComponent(hex + ".png")
    }

    private func png(_ rel: String, _ w: Int, _ h: Int) throws -> URL {
        try png(root.appendingPathComponent(rel), w, h)
    }

    private func png(_ url: URL, _ w: Int, _ h: Int) throws -> URL {
        let ctx = try bitmap(w, h)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.2, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(XCTUnwrap(ctx.makeImage())).write(to: url)
        return url
    }

    private func solidPNG(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Data {
        let ctx = try bitmap(width, height)
        ctx.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try encode(XCTUnwrap(ctx.makeImage()))
    }

    private func pdf(_ url: URL, pages: Int) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for i in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0.3, blue: 1, alpha: 1))
            if i == 0 { ctx.fill(CGRect(x: 106, y: 196, width: 400, height: 400)) }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    private func bitmap(_ w: Int, _ h: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private func encode(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func cgImage(_ image: NSImage) -> CGImage? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func pixels(_ png: URL) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithURL(png as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    private func contents(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    private func modified(_ url: URL) throws -> Date {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    /// Checks the sRGB color at a fractional position (origin top left) within 0.1 per channel.
    private func assertColor(_ image: NSImage, at p: CGPoint, red: CGFloat, green: CGFloat, blue: CGFloat,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let cg = cgImage(image), let ctx = try? bitmap(1, 1) else { return XCTFail("no pixels", file: file, line: line) }
        let x = CGFloat(cg.width - 1) * p.x, y = CGFloat(cg.height - 1) * (1 - p.y)
        ctx.draw(cg, in: CGRect(x: -x.rounded(), y: -y.rounded(), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let got = (0..<3).map { CGFloat(px[$0]) / 255 }
        for (g, want) in zip(got, [red, green, blue]) where abs(g - want) > 0.1 {
            return XCTFail("color at \(p) is \(got), want \([red, green, blue])", file: file, line: line)
        }
    }
}
