import Foundation
import PDFKit
import FlamingoCore

/// PDFKit: one `.page` section per page (1-based, as `PDFView` navigates), titled from the
/// outline. Each call opens its own `PDFDocument`, so concurrent calls share nothing.
/// A locked PDF that the empty password doesn't open yields only its title.
public struct PDFExtractor: Extractor {
    public static let extensions: Set<String> = ["pdf"]
    /// Seconds spent reading page text before the rest of the pages are left unread.
    static let timeBudget: TimeInterval = 4
    static let maxOCRPagesPerPass = 8
    public init() {}

    public func extract(_ url: URL) throws -> Extracted { try extract(url, resuming: [], processedPages: 0) }

    /// Continues a previous bounded pass for the same file version. The index persists page
    /// sections and completed-page count so another pass starts after the last completed page.
    public func extract(_ url: URL, resuming previous: [Section], processedPages: Int) throws -> Extracted {
        guard let doc = PDFDocument(url: url) else { throw ExtractError.malformed(url.path) }
        let unlocked = !doc.isLocked || doc.unlock(withPassword: "")
        let infoTitle = Self.title(doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
        guard unlocked else {
            var out = Extracted(text: "", sections: [], title: infoTitle)
            out.coverage = ExtractionCoverage(.failed, reason: "PDF requires a password.", processedUnits: 0, totalUnits: doc.pageCount)
            return out
        }

        let titles = Self.outlineTitles(doc)
        var budget = Extract.maxTextLength
        let deadline = Date(timeIntervalSinceNow: Self.timeBudget)
        var sections: [Section] = []
        sections.reserveCapacity(doc.pageCount)
        let completedBefore = min(max(processedPages, 0), min(previous.count, doc.pageCount))
        var completed = completedBefore, ocrPages = 0
        for i in 0..<doc.pageCount {
            if i < completedBefore {
                sections.append(previous[i]); budget -= previous[i].text.utf8.count
                continue
            }
            // Check between pages; native PDF parsing and one OCR request are indivisible.
            guard budget > 0, (i == completedBefore || Date() < deadline), ocrPages < Self.maxOCRPagesPerPass else {
                sections.append(Section(anchor: FileAnchor(kind: .page, value: String(i + 1)), title: titles[i], text: ""))
                continue
            }
            // Once a page was skipped, leave later pages pending too: coverage is a prefix.
            guard i == completed else {
                sections.append(Section(anchor: FileAnchor(kind: .page, value: String(i + 1)), title: titles[i], text: ""))
                continue
            }
            let page = doc.page(at: i)
            var text = autoreleasepool { Self.clean(page?.string) ?? "" }
            if text.isEmpty, let page {
                // Render inside the OCR slot so a waiting thread doesn't hold a page bitmap.
                do {
                    text = try ImageExtractor.withOCRSlot { () throws -> String in
                        guard let image = Self.ocrImage(page) else { return "" }
                        ocrPages += 1
                        return try ImageExtractor.recognizeText(in: image, timeout: max(15, deadline.timeIntervalSinceNow)).joined(separator: "\n")
                    }
                } catch {
                    sections.append(Section(anchor: FileAnchor(kind: .page, value: String(i + 1)), title: titles[i], text: ""))
                    continue
                }
            }
            budget -= text.utf8.count
            completed = i + 1
            sections.append(Section(anchor: FileAnchor(kind: .page, value: String(i + 1)), title: titles[i], text: text))
        }
        let firstLabel = doc.outlineRoot.flatMap { root in
            (0..<root.numberOfChildren).lazy.compactMap { Self.title(root.child(at: $0)?.label) }.first
        }
        var out = Extracted(sections: sections, title: infoTitle ?? firstLabel)
        if completed < doc.pageCount {
            out.coverage = ExtractionCoverage(.partial, reason: budget <= 0 ? "PDF text budget reached." : "PDF extraction is continuing in bounded passes.",
                                             processedUnits: completed, totalUnits: doc.pageCount)
        } else {
            out.coverage = ExtractionCoverage(.complete, processedUnits: completed, totalUnits: doc.pageCount)
        }
        return out
    }

    private static func ocrImage(_ page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(2, 1800 / max(box.width, box.height))
        let width = max(1, Int((box.width * scale).rounded(.up)))
        let height = max(1, Int((box.height * scale).rounded(.up)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale); context.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    /// Page index to the label of the first outline item, in depth-first pre-order, that points
    /// at it, so a parent beats its children and earlier entries beat later ones. The visit
    /// budget keeps a malformed, cyclic outline from spinning forever.
    private static func outlineTitles(_ doc: PDFDocument) -> [Int: String] {
        guard let root = doc.outlineRoot else { return [:] }
        var titles: [Int: String] = [:]
        var stack = children(of: root)
        var budget = 10_000
        while let item = stack.popLast(), budget > 0 {
            budget -= 1
            if let page = (item.destination ?? (item.action as? PDFActionGoTo)?.destination)?.page,
               case let i = doc.index(for: page), (0..<doc.pageCount).contains(i), titles[i] == nil,
               let label = title(item.label) {
                titles[i] = label
            }
            stack.append(contentsOf: children(of: item))
        }
        return titles
    }

    /// Children last-first, ready to pop from a stack in reading order.
    private static func children(of item: PDFOutline) -> [PDFOutline] {
        (0..<item.numberOfChildren).reversed().compactMap { item.child(at: $0) }
    }

    /// `clean`, on one line: outline labels and Info titles sometimes carry line breaks.
    static func title(_ s: String?) -> String? {
        clean(s).map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    }

    /// Trimmed, CRLF and CR as LF, NULs removed. Nil when nothing is left.
    static func clean(_ s: String?) -> String? {
        guard var t = s else { return nil }
        if t.utf8.contains(0x0D) { t = t.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
        if t.utf8.contains(0) { t = t.replacingOccurrences(of: "\0", with: "") }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
