import Foundation

/// Subsequence matching for quick open: `q3mod` finds `finance/q3-model.xlsx`.
/// Matches in the file name beat matches in folders; word starts and runs score higher.
enum FuzzyMatch {
    static func rank(_ query: String, in paths: [String], limit: Int) -> [String] {
        let limit = max(0, limit)
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return Array(paths.prefix(limit)) }
        var scored: [(path: String, score: Int)] = []
        for p in paths {
            if let s = score(q, path: p) { scored.append((p, s)) }
        }
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.path.count != $1.path.count { return $0.path.count < $1.path.count }
            return $0.path < $1.path
        }
        return scored.prefix(limit).map(\.path)
    }

    static func score(_ q: [Character], path: String) -> Int? {
        let name = (path as NSString).lastPathComponent
        if let s = score(q, in: Array(name)) { return s + 50 }
        return score(q, in: Array(path))
    }

    /// Best alignment over every starting position of the first character.
    static func score(_ q: [Character], in original: [Character]) -> Int? {
        let s = original.map { Character($0.lowercased()) }
        guard s.count >= q.count else { return nil }
        var best: Int?
        for start in s.indices where s[start] == q[0] {
            guard let v = greedy(q, s, original, from: start) else { break }
            best = max(best ?? v, v)
        }
        guard var b = best else { return nil }
        let joined = String(s), needle = String(q)
        if joined.hasPrefix(needle) { b += 25 } else if joined.contains(needle) { b += 12 }
        return b - s.count / 8
    }

    private static func greedy(_ q: [Character], _ s: [Character], _ original: [Character], from start: Int) -> Int? {
        var qi = 0, prev = -2, total = 0
        var i = start
        while i < s.count, qi < q.count {
            if s[i] == q[qi] {
                var bonus = 1
                if i == prev + 1 { bonus += 5 }
                if i == 0 || isBoundary(s[i - 1]) { bonus += 8 }
                else if original[i].isUppercase, original[i - 1].isLowercase { bonus += 6 }
                total += bonus
                prev = i
                qi += 1
            }
            i += 1
        }
        return qi == q.count ? total : nil
    }

    private static func isBoundary(_ c: Character) -> Bool {
        c == "/" || c == "-" || c == "_" || c == " " || c == "." || c == "(" || c == "["
    }
}
