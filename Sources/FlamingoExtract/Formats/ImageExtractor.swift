import Foundation
import ImageIO
import Vision
import FlamingoCore

/// Images: descriptive metadata (IPTC, TIFF, EXIF, PNG text) plus Vision OCR of the primary image
/// (a GIF's first frame) when it's larger than an icon. Section-less; `title` is the IPTC object name.
///
/// OCR is `.accurate`, the only level that reads CJK, Cyrillic, Arabic, and the rest (`.fast` knows
/// six Latin-script languages). The first time an executable uses it, Vision compiles its models,
/// ~12 s on the first image and ~12 s more on the first with text, cached per executable name in
/// `~/Library/Caches/<name>/com.apple.e5rt.e5bundlecache`. After that an image takes ~0.1 s. Vision
/// runs one request at a time, so warming up in the background wouldn't let other OCR through.
public struct ImageExtractor: Extractor {
    public static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp"]
    public init() {}

    /// Below either bound the image is an icon or a UI sliver, and OCR isn't worth its cost.
    static let minLongSide = 256, minShortSide = 48
    /// OCR runs on a copy downsampled to at most this many pixels on the long side.
    static let maxOCRSide = 4096

    public func extract(_ url: URL) throws -> Extracted {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              case let index = CGImageSourceGetPrimaryImageIndex(source),
              let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { throw ExtractError.malformed(url.path) }

        let meta = Self.metadata(props)
        var lines = meta.lines
        if max(width, height) >= Self.minLongSide, min(width, height) >= Self.minShortSide {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: min(Self.maxOCRSide, max(width, height)),
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                throw ExtractError.malformed(url.path)
            }
            lines += try Self.recognizeText(in: image)
        }
        return Extracted(text: lines.joined(separator: "\n"), title: meta.title)
    }

    /// Accurate Vision OCR, lines in reading order.
    static func recognizeText(in image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { o in o.topCandidates(1).first.map { (o.boundingBox, $0.string) } }
        return readingOrder(lines)
    }

    /// Orders lines top to bottom (Vision boxes are normalised with the origin bottom-left).
    /// Lines whose vertical centres are within half a line height of a row's first line share
    /// that row and read left to right.
    static func readingOrder(_ lines: [(box: CGRect, text: String)]) -> [String] {
        var rows: [[(box: CGRect, text: String)]] = []
        for line in lines.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let first = rows.last?.first, abs(first.box.midY - line.box.midY) < min(first.box.height, line.box.height) / 2 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text) }
    }

    /// IPTC object name, caption and keywords, TIFF description, EXIF user comment, PNG title and
    /// description: trimmed, deduplicated, in that order. The title is the IPTC object name.
    static func metadata(_ props: [CFString: Any]) -> (title: String?, lines: [String]) {
        func dict(_ key: CFString) -> [CFString: Any] { props[key] as? [CFString: Any] ?? [:] }
        let iptc = dict(kCGImagePropertyIPTCDictionary), tiff = dict(kCGImagePropertyTIFFDictionary)
        let exif = dict(kCGImagePropertyExifDictionary), png = dict(kCGImagePropertyPNGDictionary)
        let keywords = (iptc[kCGImagePropertyIPTCKeywords] as? [String])?.joined(separator: ", ") ?? iptc[kCGImagePropertyIPTCKeywords]
        let values: [Any?] = [
            iptc[kCGImagePropertyIPTCObjectName], iptc[kCGImagePropertyIPTCCaptionAbstract], keywords,
            tiff[kCGImagePropertyTIFFImageDescription], exif[kCGImagePropertyExifUserComment],
            png[kCGImagePropertyPNGTitle], png[kCGImagePropertyPNGDescription],
        ]
        var lines: [String] = []
        for case let s as String in values {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            if !t.isEmpty, !lines.contains(t) { lines.append(t) }
        }
        let title = (iptc[kCGImagePropertyIPTCObjectName] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title?.isEmpty == false ? title : nil, lines)
    }
}
