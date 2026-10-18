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
struct LinkCandidate: Identifiable, Hashable, Sendable {
    let ref: FileRef
    /// What goes between the brackets: the basename when it is unique in the vault,
    /// otherwise the relative path, so `Wikilink.resolve` lands on the same file.
    let insertText: String
    var id: String { ref.relativePath }
    var folder: String { (ref.relativePath as NSString).deletingLastPathComponent }
}

/// Ranks vault files against what was typed after `[[`.
struct LinkMatcher: Sendable {
    /// The vault's files folded for matching, built once per file list and shared by every
    /// thought field: on a whole disk that is a million rows, too many to rebuild (and to free
    /// on the main thread) each time a file opens.
    final class Table: Sendable {
        struct Entry: Sendable {
            let candidate: LinkCandidate
            /// Folded; `nameOriginal` shares its storage when folding changed nothing.
            let name: [Character], nameOriginal: [Character], nameStem: Int?
            let pathLength: Int
        }
        /// Kept so its buffer can't be reused while this table stands for it (see `isBuilt(from:)`).
        let candidates: [FileRef]
        let entries: [Entry]
        let index: [String: Int]

        init(_ candidates: [FileRef]) {
            var nameCounts: [String: Int] = [:]
            for ref in candidates { nameCounts[ref.name.lowercased(), default: 0] += 1 }
            var index: [String: Int] = [:]
            index.reserveCapacity(candidates.count)
            var entries: [Entry] = []
            entries.reserveCapacity(candidates.count)
            for ref in candidates {
                let unique = nameCounts[ref.name.lowercased()] == 1
                let folded = FuzzyMatch.fold(ref.name), original = Array(ref.name)
                index[ref.relativePath] = entries.count
                entries.append(Entry(candidate: LinkCandidate(ref: ref, insertText: unique ? ref.name : ref.relativePath),
                                     name: folded, nameOriginal: original == folded ? folded : original,
                                     nameStem: FuzzyMatch.stemEnd(original), pathLength: ref.relativePath.count))
            }
            self.candidates = candidates; self.entries = entries; self.index = index
        }

        /// Same array, not just equal contents: comparing a million paths would cost what it saves.
        func isBuilt(from other: [FileRef]) -> Bool {
            other.count == candidates.count && other.withUnsafeBufferPointer { a in
                candidates.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress }
            }
        }

        private static let lock = NSLock()
        nonisolated(unsafe) private static var last: Table?

        /// The table for `candidates`, reusing the last one built when it is the same list.
        static func shared(_ candidates: [FileRef]) -> Table {
            if let hit = lock.withLock({ last.flatMap { $0.isBuilt(from: candidates) ? $0 : nil } }) { return hit }
            let made = Table(candidates)
            let replaced = lock.withLock { () -> Table? in defer { last = made }; return last }
            _ = replaced   // the old table is freed here, off the main thread when built off it
            return made
        }
    }

    private let table: Table
    /// Recent files' rank by entry index, most recent first.
    private let recency: [Int: Int]
    private let recentOrder: [Int]

    static let empty = LinkMatcher(candidates: [])

    init(candidates: [FileRef], recent: [FileRef] = []) {
        table = Table.shared(candidates)
        var recency: [Int: Int] = [:], order: [Int] = []
        for (rank, ref) in recent.enumerated() {
            guard let i = table.index[ref.relativePath], recency[i] == nil else { continue }
            recency[i] = rank; order.append(i)
        }
        self.recency = recency; recentOrder = order
    }

    var isEmpty: Bool { table.entries.isEmpty }

    /// Matches on the basename; a query containing `/` matches the relative path instead.
    /// An empty query lists recent files first.
    func matches(_ query: String, limit: Int = 8) -> [LinkCandidate] {
        let entries = table.entries
        let q = FuzzyMatch.fold(query.trimmingCharacters(in: .whitespaces))
        if q.isEmpty {
            var out = recentOrder.prefix(limit).map { entries[$0].candidate }
            for (i, e) in entries.enumerated() where out.count < limit && recency[i] == nil { out.append(e.candidate) }
            return out
        }
        let byPath = q.contains("/")
        var scored: [(score: Int, index: Int)] = []
        for (i, e) in entries.enumerated() {
            var s: Int?
            if byPath {
                // Paths are folded only for the rare query that names a folder.
                let original = Array(e.candidate.ref.relativePath)
                s = FuzzyMatch.score(q, FuzzyMatch.fold(e.candidate.ref.relativePath), original: original, stemEnd: FuzzyMatch.stemEnd(original))
            } else {
                s = FuzzyMatch.score(q, e.name, original: e.nameOriginal, stemEnd: e.nameStem)
            }
            guard var s else { continue }
            if let r = recency[i] { s += max(0, 30 - r * 3) }
            scored.append((s, i))
        }
        scored.sort { x, y in
            let a = entries[x.index], b = entries[y.index]
            if x.score != y.score { return x.score > y.score }
            if a.name.count != b.name.count { return a.name.count < b.name.count }
            if a.pathLength != b.pathLength { return a.pathLength < b.pathLength }
            return a.candidate.ref.relativePath < b.candidate.ref.relativePath
        }
        return scored.prefix(limit).map { entries[$0.index].candidate }
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
