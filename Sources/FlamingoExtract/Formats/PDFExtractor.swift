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
    public init() {}

    public func extract(_ url: URL) throws -> Extracted {
        guard let doc = PDFDocument(url: url) else { throw ExtractError.malformed(url.path) }
        let unlocked = !doc.isLocked || doc.unlock(withPassword: "")
        let infoTitle = Self.title(doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
        guard unlocked else { return Extracted(text: "", sections: [], title: infoTitle) }

        let titles = Self.outlineTitles(doc)
        // Past the index's text cap or the time budget (huge scans cost ~10 ms a page for
        // almost no text), pages keep their anchors and titles but aren't read.
        var budget = Extract.maxTextLength
        let deadline = Date(timeIntervalSinceNow: Self.timeBudget)
        var sections: [Section] = []
        sections.reserveCapacity(doc.pageCount)
        for i in 0..<doc.pageCount {
            if budget > 0, i % 16 == 15, Date() > deadline { budget = 0 }
            let text = budget > 0 ? autoreleasepool { Self.clean(doc.page(at: i)?.string) ?? "" } : ""
            budget -= text.utf8.count
            sections.append(Section(anchor: FileAnchor(kind: .page, value: String(i + 1)), title: titles[i], text: text))
        }
        let firstLabel = doc.outlineRoot.flatMap { root in
            (0..<root.numberOfChildren).lazy.compactMap { Self.title(root.child(at: $0)?.label) }.first
        }
        return Extracted(sections: sections, title: infoTitle ?? firstLabel)
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
