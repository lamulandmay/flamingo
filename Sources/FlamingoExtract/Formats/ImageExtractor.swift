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
            do {
                lines += try Self.withOCRSlot {
                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: min(Self.maxOCRSide, max(width, height)),
                    ]
                    guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                        throw ExtractError.malformed(url.path)
                    }
                    return try Self.recognizeText(in: image)
                }
            } catch let stalled as OCRStalled {
                // Keep the metadata; a failed read is retried later with backoff.
                var out = Extracted(text: lines.joined(separator: "\n"), title: meta.title)
                out.coverage = ExtractionCoverage(.failed, reason: stalled.reason)
                return out
            }
        }
        return Extracted(text: lines.joined(separator: "\n"), title: meta.title)
    }

    /// At most four images decoded and in Vision at once. With eight extraction threads all
    /// on images, each held a decoded bitmap (up to 64 MB at 4096 px) while Vision worked;
    /// four slots read 300 photos as fast as eight did (20 s) with a 20% smaller peak
    /// footprint, and on a mixed batch the other threads get on with documents meanwhile.
    /// Two slots halved photo throughput. Wrap decoding and `recognizeText` together; never nest.
    static let ocrSlots = DispatchSemaphore(value: 4)

    static func withOCRSlot<T>(_ body: () throws -> T) rethrows -> T {
        ocrSlots.wait()
        defer { ocrSlots.signal() }
        return try body()
    }

    /// Vision didn't answer in time. Its request may still be stuck inside Vision.
    struct OCRStalled: Error { var reason: String }

    /// The longest one request may hold an extraction thread. The first request of a fresh
    /// executable compiles Vision's models (~25 s), so this is generous.
    static let ocrWatchdog: TimeInterval = 90

    /// Set while an abandoned request is still inside Vision. A home-folder index once sat
    /// for 87 minutes with every extraction thread parked in Vision's capacity queue behind
    /// a request that never returned; while one is stuck, others fail at once instead.
    static let ocrStuck = Locked(false)

    /// Accurate Vision OCR, lines in reading order. Runs on its own thread so a request that
    /// never returns costs that thread, not the index: after `ocrWatchdog` (or `timeout`, if
    /// sooner, plus a grace period for cancellation) the caller gets `OCRStalled`.
    static func recognizeText(in image: CGImage, timeout: TimeInterval? = nil) throws -> [String] {
        if ocrStuck.withLock({ $0 }) { throw OCRStalled(reason: "Text recognition is stuck; will retry.") }
        final class Call: @unchecked Sendable {
            var result: Result<[String], Error>?
            var abandoned = false
        }
        let call = Locked(Call())
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            let result = Result { try recognize(image, timeout: timeout) }
            call.withLock { c in
                c.result = result
                if c.abandoned { ocrStuck.withLock { $0 = false } }
            }
            finished.signal()
        }
        thread.qualityOfService = Thread.current.qualityOfService
        thread.start()
        let limit = min(timeout.map { $0 + 10 } ?? ocrWatchdog, ocrWatchdog)
        if finished.wait(timeout: .now() + limit) == .timedOut {
            let late = call.withLock { c -> Result<[String], Error>? in
                if c.result == nil { c.abandoned = true; ocrStuck.withLock { $0 = true } }
                return c.result
            }
            guard let late else { throw OCRStalled(reason: "Text recognition took over \(Int(limit)) s; will retry.") }
            return try late.get()
        }
        return try call.withLock { $0.result! }.get()
    }

    private static func recognize(_ image: CGImage, timeout: TimeInterval?) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let cancelled = Locked(false)
        let cancellation = timeout.map { interval -> DispatchWorkItem in
            let item = DispatchWorkItem { cancelled.withLock { $0 = true }; request.cancel() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + interval, execute: item)
            return item
        }
        defer { cancellation?.cancel() }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard !cancelled.withLock({ $0 }) else { throw ExtractError.unreadable("OCR request exceeded its time budget.") }
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
