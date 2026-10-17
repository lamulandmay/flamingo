import Foundation
import FlamingoCore

/// Splits indexed sections into passages for embedding. A passage is about 240 tokens of
/// text (roughly 950 Latin characters or 240 Han characters), cut at a paragraph, line or
/// sentence end, with a little overlap, and carries a header naming its file and section so
/// "the memo about lamp pricing" can match on context the passage itself never repeats.
///
/// Offsets and lengths count Unicode scalars, which is what SQLite's `substr` counts, so a
/// passage can be read back from `sections.text` without loading the whole section.
enum SemanticChunker {
    static let targetUnits = 240.0
    static let overlapUnits = 32.0
    /// Very long files keep their first passages; the rest stays keyword-searchable.
    static let maxChunksPerFile = 160
    static let maxCommentScalars = 1500

    struct Chunk: Equatable {
        var offset: Int
        var length: Int
        var body: String
    }

    /// What a passage header says about its file.
    struct FileContext {
        var path: String
        var title: String?
        var tags: String?

        var name: String { (path as NSString).lastPathComponent }
        var folder: String { (path as NSString).deletingLastPathComponent }
        /// `Pricing memo (pricing-memo.docx)`, or just the name when there is no better title.
        var display: String {
            let stem = (name as NSString).deletingPathExtension
            guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  title != name, title != stem else { return name }
            return title + " (" + name + ")"
        }
    }

    /// Roughly one token per Han/kana/Hangul character, one per four other characters.
    @inline(__always) static func units(_ s: Unicode.Scalar) -> Double {
        switch s.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return 1
        case 0x09, 0x0A, 0x0D, 0x20: return 0.1
        default: return 0.25
        }
    }

    /// Passages of `text`, or none when it has nothing worth embedding.
    static func split(_ text: String) -> [Chunk] {
        let scalars = Array(text.unicodeScalars)
        guard scalars.contains(where: { CharacterSet.letters.contains($0) }) else { return [] }
        var total = 0.0
        for s in scalars { total += units(s) }
        if total <= targetUnits * 1.25 {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [Chunk(offset: 0, length: scalars.count, body: text)]
        }
        var out: [Chunk] = []
        var start = 0
        while start < scalars.count {
            var used = 0.0, end = start
            while end < scalars.count, used < targetUnits { used += units(scalars[end]); end += 1 }
            if end < scalars.count {
                end = boundary(scalars, from: start, to: end)
            }
            let body = String(String.UnicodeScalarView(scalars[start..<end]))
            if body.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) {
                out.append(Chunk(offset: start, length: end - start, body: body))
            }
            guard end < scalars.count else { break }
            // Step back a little, to a word start, so text near the cut appears in both.
            var back = end, overlap = 0.0
            while back > start + 1, overlap < overlapUnits { back -= 1; overlap += units(scalars[back]) }
            while back < end, !(scalars[back - 1] == " " || scalars[back - 1] == "\n" || units(scalars[back - 1]) == 1) { back += 1 }
            start = back > start && back < end ? back : end
        }
        return out
    }

    /// The best cut in `start..<end`, looking back over its last third: after a paragraph
    /// break, then a line break, then a sentence end, then a space.
    static func boundary(_ s: [Unicode.Scalar], from start: Int, to end: Int) -> Int {
        let floor = start + max(1, (end - start) * 2 / 3)
        var line: Int?, sentence: Int?, space: Int?
        var i = end - 1
        while i > floor {
            let c = s[i]
            if c == "\n", i > 0, s[i - 1] == "\n" { return i + 1 }
            if c == "\n", line == nil { line = i + 1 }
            if sentence == nil, i + 1 < s.count {
                if ["。", "！", "？", "；"].contains(c) { sentence = i + 1 }
                else if [".", "!", "?", ";"].contains(c), s[i + 1] == " " || s[i + 1] == "\n" { sentence = i + 1 }
            }
            if space == nil, c == " " || c == "\t" { space = i + 1 }
            i -= 1
        }
        return line ?? sentence ?? space ?? end
    }

    /// `Pricing memo (pricing-memo.docx) › Recommendation`.
    static func sectionHeader(_ file: FileContext, title: String?, anchor: FileAnchor?) -> String {
        var label = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if label.isEmpty, let anchor, anchor.kind != .line { label = anchor.label }
        return label.isEmpty ? file.display : file.display + " › " + label
    }

    /// The header of a file's own row: its name, title, folder and tags.
    static func fileHeader(_ file: FileContext) -> String {
        var s = file.display
        if !file.folder.isEmpty { s += " in " + file.folder }
        if let tags = file.tags, !tags.isEmpty { s += " · " + tags }
        return s
    }

    /// A short card for a file whose text lives in its sections: an outline of section
    /// titles and the opening lines, so a query about the whole document has one target.
    static func card(outline: [String], opening: String) -> String {
        var seen = Set<String>()
        let titles = outline.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.prefix(24)
        var s = ""
        if !titles.isEmpty { s = "Contents: " + titles.joined(separator: "; ") + "\n" }
        let lead = opening.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        s += String(lead.unicodeScalars.prefix(360))
        return s
    }

    /// Spreadsheet sections are tab-separated rows; later passages repeat the header row so
    /// a number keeps its column name.
    static func columnHeader(_ text: String) -> String? {
        guard let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first,
              first.contains("\t") else { return nil }
        return String(first.prefix(300))
    }

    /// FNV-1a over the model id and the exact input, as stored in `embedding_spans.hash`.
    static func hash(_ model: String, _ input: String) -> Int64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in model.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        h = (h ^ 0) &* 0x100000001b3
        for b in input.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int64(bitPattern: h)
    }
}
