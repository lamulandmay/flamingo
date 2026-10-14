import Foundation
import FlamingoCore

/// Subsequence matching with bonuses for prefixes, word starts and runs. A contiguous
/// substring always outranks a scattered match.
enum FuzzyMatch {
    /// Lowercases character by character so indices line up with the original.
    static func fold(_ s: String) -> [Character] {
        s.map { ch in
            let l = ch.lowercased()
            return l.count == 1 ? Character(l) : ch
        }
    }

    /// Higher is better; nil when `query` isn't a subsequence of `candidate`.
    /// Both folded arrays must come from `fold`; `original` is the unfolded candidate.
    /// Characters from `stemEnd` on (the extension) match but earn no word-start bonus.
    static func score(_ query: [Character], _ candidate: [Character], original: [Character], stemEnd: Int? = nil) -> Int? {
        guard !query.isEmpty else { return 0 }
        guard query.count <= candidate.count else { return nil }
        let stemEnd = stemEnd ?? candidate.count
        var best: Int?

        var start = 0
        while start + query.count <= candidate.count {
            if candidate[start] == query[0], Array(candidate[start..<start + query.count]) == query {
                // A run that starts in the extension is only as good as a scattered match.
                var s = (start < stemEnd ? 1000 : 0) + query.count * 8 - start
                if start == 0 { s += 40 } else if start < stemEnd, isWordStart(original, start) { s += 20 }
                best = max(best ?? .min, s)
            }
            start += 1
        }

        var qi = 0, prev = -2, s = 0
        for i in candidate.indices where qi < query.count {
            guard candidate[i] == query[qi] else { continue }
            var bonus = 1
            if i == prev + 1 { bonus += 4 }
            if i == 0 { bonus += 8 } else if i < stemEnd, isWordStart(original, i) { bonus += 6 }
            s += bonus; prev = i; qi += 1
        }
        if qi == query.count { best = max(best ?? .min, s) }

        return best.map { $0 - stemEnd / 4 }
    }

    /// Index of the extension's dot, if the name has one.
    static func stemEnd(_ s: [Character]) -> Int? {
        guard let dot = s.lastIndex(of: "."), dot > 0, s[(dot + 1)...].allSatisfy({ $0 != "/" }) else { return nil }
        return dot
    }

    static func isWordStart(_ s: [Character], _ i: Int) -> Bool {
        guard i > 0 else { return true }
        let p = s[i - 1], c = s[i]
        if " -_./()[]".contains(p) { return true }
        if p.isLowercase && c.isUppercase { return true }
        if p.isLetter && c.isNumber { return true }
        return false
    }
}

/// One row in the `[[` completion list.
struct LinkCandidate: Identifiable, Hashable {
    let ref: FileRef
    /// What goes between the brackets: the basename when it is unique in the vault,
    /// otherwise the relative path, so `Wikilink.resolve` lands on the same file.
    let insertText: String
    var id: String { ref.relativePath }
    var folder: String { (ref.relativePath as NSString).deletingLastPathComponent }
}

/// Ranks vault files against what was typed after `[[`.
struct LinkMatcher {
    private struct Entry {
        let candidate: LinkCandidate
        let name: [Character], nameOriginal: [Character], nameStem: Int?
        let path: [Character], pathOriginal: [Character], pathStem: Int?
        let recency: Int?
    }
    private let entries: [Entry]
    private let recentOrder: [Int]

    static let empty = LinkMatcher(candidates: [])

    init(candidates: [FileRef], recent: [FileRef] = []) {
        var nameCounts: [String: Int] = [:]
        for ref in candidates { nameCounts[ref.name.lowercased(), default: 0] += 1 }
        var rank: [String: Int] = [:]
        for (i, ref) in recent.enumerated() where rank[ref.relativePath] == nil { rank[ref.relativePath] = i }
        let entries = candidates.map { ref in
            let unique = nameCounts[ref.name.lowercased()] == 1
            let name = Array(ref.name), path = Array(ref.relativePath)
            return Entry(candidate: LinkCandidate(ref: ref, insertText: unique ? ref.name : ref.relativePath),
                         name: FuzzyMatch.fold(ref.name), nameOriginal: name, nameStem: FuzzyMatch.stemEnd(name),
                         path: FuzzyMatch.fold(ref.relativePath), pathOriginal: path, pathStem: FuzzyMatch.stemEnd(path),
                         recency: rank[ref.relativePath])
        }
        self.entries = entries
        recentOrder = entries.indices
            .compactMap { i in entries[i].recency.map { (i, $0) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    var isEmpty: Bool { entries.isEmpty }

    /// Matches on the basename; a query containing `/` matches the relative path instead.
    /// An empty query lists recent files first.
    func matches(_ query: String, limit: Int = 8) -> [LinkCandidate] {
        let q = FuzzyMatch.fold(query.trimmingCharacters(in: .whitespaces))
        if q.isEmpty {
            var out = recentOrder.prefix(limit).map { entries[$0].candidate }
            for e in entries where out.count < limit && e.recency == nil { out.append(e.candidate) }
            return out
        }
        let byPath = q.contains("/")
        var scored: [(score: Int, entry: Entry)] = []
        for e in entries {
            let s = byPath ? FuzzyMatch.score(q, e.path, original: e.pathOriginal, stemEnd: e.pathStem)
                           : FuzzyMatch.score(q, e.name, original: e.nameOriginal, stemEnd: e.nameStem)
            guard var s else { continue }
            if let r = e.recency { s += max(0, 30 - r * 3) }
            scored.append((s, e))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.entry.name.count != b.entry.name.count { return a.entry.name.count < b.entry.name.count }
            if a.entry.path.count != b.entry.path.count { return a.entry.path.count < b.entry.path.count }
            return a.entry.candidate.ref.relativePath < b.entry.candidate.ref.relativePath
        }
        return scored.prefix(limit).map(\.entry.candidate)
    }
}

/// The part of a wikilink being typed: everything after an unclosed `[[` up to the cursor.
/// Offsets are UTF-16, matching `NSTextView`.
struct LinkQuery: Equatable {
    /// Offset of the first character after `[[`.
    let start: Int
    let text: String

    static let maxLength = 80

    /// Nil unless the cursor sits at the end of an unclosed `[[target` on the current line.
    /// Once a `#` or `|` is typed the file part is done and completion steps aside.
    static func active(in s: NSString, cursor: Int) -> LinkQuery? {
        guard cursor >= 0, cursor <= s.length else { return nil }
        let line = s.lineRange(for: NSRange(location: cursor, length: 0))
        let before = s.substring(with: NSRange(location: line.location, length: cursor - line.location)) as NSString
        let open = before.range(of: "[[", options: .backwards)
        guard open.location != NSNotFound else { return nil }
        let qStart = open.location + open.length
        let q = before.substring(from: qStart)
        guard q.count <= maxLength, !q.contains(where: { "[]#|".contains($0) }) else { return nil }

        // Mid-word edits (cursor inside an existing name) don't complete.
        let lineEnd = line.location + line.length
        if cursor < lineEnd {
            let next = s.substring(with: NSRange(location: cursor, length: 1))
            if next != "]", let ch = next.first, !ch.isWhitespace { return nil }
        }
        return LinkQuery(start: line.location + qStart, text: q)
    }
}

/// An edit that completes a `LinkQuery`.
struct LinkInsertion: Equatable {
    let range: NSRange
    let replacement: String
    /// Cursor position after the edit.
    let cursor: Int

    /// Replaces the query with the candidate's name and closes the link, unless `]]`
    /// already follows the cursor. A `suffix` of `#` or `|` keeps the cursor inside the
    /// brackets so an anchor or alias can follow.
    static func make(_ candidate: LinkCandidate, query: LinkQuery, in s: NSString, cursor: Int,
                     suffix: String? = nil) -> LinkInsertion {
        let range = NSRange(location: query.start, length: max(0, cursor - query.start))
        let closed = cursor + 2 <= s.length && s.substring(with: NSRange(location: cursor, length: 2)) == "]]"
        let body = candidate.insertText + (suffix ?? "")
        let replacement = closed ? body : body + "]]"
        let bodyEnd = query.start + (body as NSString).length
        return LinkInsertion(range: range, replacement: replacement, cursor: suffix == nil ? bodyEnd + 2 : bodyEnd)
    }
}

/// Ranges of `[[...]]` in a string, for highlighting while typing.
enum WikilinkRanges {
    private static let regex = try! NSRegularExpression(pattern: #"\[\[[^\[\]\n]+?\]\]"#)

    static func find(in s: String) -> [NSRange] {
        regex.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)).map(\.range)
    }
}
