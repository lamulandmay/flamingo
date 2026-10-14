import Foundation

/// Fuzzy subsequence matching for the command palette: file names, paths, command titles.
///
/// `score` is `nil` unless every character of the query appears in the candidate in order,
/// case-insensitively (whitespace in the query is ignored). Otherwise it is the score of the
/// best alignment: 4 per matched character; +16 for a match at the very start; +10 at a word
/// boundary (after space, `-`, `_`, `.`, `/`); +8 at a lower→Upper camel transition; +8 per
/// consecutive pair; +24 when the query occurs verbatim as a contiguous substring; −3 to open
/// a gap and −1 for each further skipped character; −1 per character before the first match,
/// capped at 12. Higher is better.
///
///     Fuzzy.score("q3", "q3-model.xlsx")     // 56: start 16, one pair 8, 2×4, substring 24
///     Fuzzy.score("model", "q3-model.xlsx")  // 83: boundary 10, four pairs 32, 5×4, substring 24, first match 3 late
///     Fuzzy.score("qmx", "q3-model.xlsx")    // 37: start 16, boundaries 10+10, 3×4; gaps "3-" (−4) and "odel." (−7)
///     Fuzzy.score("xq", "q3-model.xlsx")     // nil: not a subsequence
///
/// The palette scores every file in the vault on each keystroke, so the hot path works on
/// lowercased UTF-8 byte tables prepared once per show (`FileTable`), skips candidates whose
/// 64-bit character-class mask cannot contain the query, and runs the alignment on raw
/// pointers with two reusable rows. No regex, no NSString.
enum Fuzzy {
    // MARK: Public

    /// Best alignment score of `query` in `candidate`, or `nil` when `query` is not a
    /// case-insensitive subsequence of `candidate`. An empty query scores 0 everywhere.
    static func score(_ query: String, _ candidate: String) -> Int? {
        score(Query(query), candidate)
    }

    /// Character offsets (into `candidate`) matched by the best alignment, in order; `nil` when
    /// there is no match. Shares `score`'s alignment, so highlighting agrees with ranking.
    static func matches(_ query: String, _ candidate: String) -> [Int]? {
        let q = Query(query)
        if q.bytes.isEmpty { return [] }
        let c = Candidate(candidate, mapping: true)
        guard q.mask & ~c.mask == 0, q.bytes.count <= c.bytes.count else { return nil }
        let m = q.bytes.count, n = c.bytes.count
        return q.bytes.withUnsafeBufferPointer { qb in
            c.bytes.withUnsafeBufferPointer { cb in
                c.flags.withUnsafeBufferPointer { fb in
                    withUnsafeTemporaryAllocation(of: Int32.self, capacity: m * n) { rows -> [Int]? in
                        guard let rows = rows.baseAddress, let qp = qb.baseAddress, let cp = cb.baseAddress,
                              let fp = fb.baseAddress,
                              align(qp, m, cp, fp, n, rows: rows, rowCount: m) != nil else { return nil }
                        let positions = traceback(qp, m, cp, fp, n, rows: rows)
                        guard let map = c.charIndex else { return positions }
                        var out: [Int] = []
                        for p in positions {
                            let ch = map[p]
                            if out.last != ch { out.append(ch) }
                        }
                        return out
                    }
                }
            }
        }
    }

    // MARK: Prepared forms

    /// A query lowercased to UTF-8 with whitespace removed. Prepare once per keystroke.
    struct Query {
        let bytes: [UInt8]
        let mask: UInt64

        init(_ text: String) {
            var out: [UInt8] = []
            out.reserveCapacity(text.utf8.count)
            for ch in text where !ch.isWhitespace {
                out.append(contentsOf: ch.lowercased().utf8)
            }
            bytes = out
            mask = Fuzzy.mask(of: out[...])
        }

        var isEmpty: Bool { bytes.isEmpty }
    }

    /// One candidate lowercased to UTF-8 with per-byte boundary flags.
    struct Candidate {
        let bytes: [UInt8]
        let flags: [UInt8]
        let mask: UInt64
        /// Character offset each byte came from; only built when `mapping` is requested.
        let charIndex: [Int]?

        init(_ text: String, mapping: Bool = false) {
            var b: [UInt8] = [], f: [UInt8] = []
            var map: [Int]? = mapping ? [] : nil
            b.reserveCapacity(text.utf8.count)
            f.reserveCapacity(text.utf8.count)
            Fuzzy.append(text, to: &b, flags: &f, charIndex: &map)
            bytes = b
            flags = f
            charIndex = map
            mask = Fuzzy.mask(of: b[...])
        }
    }

    /// Scores a prepared query against one string. Commands and other short lists.
    static func score(_ q: Query, _ candidate: String) -> Int? {
        if q.bytes.isEmpty { return 0 }
        let c = Candidate(candidate)
        guard q.mask & ~c.mask == 0, q.bytes.count <= c.bytes.count else { return nil }
        let m = q.bytes.count, n = c.bytes.count
        return q.bytes.withUnsafeBufferPointer { qb in
            c.bytes.withUnsafeBufferPointer { cb in
                c.flags.withUnsafeBufferPointer { fb in
                    withUnsafeTemporaryAllocation(of: Int32.self, capacity: 2 * n) { rows -> Int? in
                        guard let rows = rows.baseAddress, let qp = qb.baseAddress, let cp = cb.baseAddress,
                              let fp = fb.baseAddress else { return nil }
                        return align(qp, m, cp, fp, n, rows: rows, rowCount: 2).map { Int($0) }
                    }
                }
            }
        }
    }

    /// Every file of a vault as one contiguous lowercased byte table. Build once per file list
    /// (the palette caches it against `AppState.files`), then `rank` per keystroke.
    final class FileTable {
        struct Match {
            let index: Int
            let score: Int
        }

        /// The list this table was built from.
        let paths: [String]
        private var bytes: [UInt8] = []
        private var flags: [UInt8] = []
        /// `count + 1` offsets into `bytes`; file `i` is `start[i] ..< start[i + 1]`.
        private var start: [Int32] = []
        /// Offset of the file name (after the last `/`) within `bytes`.
        private var nameStart: [Int32] = []
        private var masks: [UInt64] = []
        private var longest = 0

        /// Weight of a match on the whole relative path next to one on the name alone.
        static func pathWeight(_ score: Int32) -> Int32 { score * 2 / 3 }

        init(paths: [String]) {
            self.paths = paths
            var total = 0
            for p in paths { total += p.utf8.count }
            bytes.reserveCapacity(total)
            flags.reserveCapacity(total)
            start.reserveCapacity(paths.count + 1)
            nameStart.reserveCapacity(paths.count)
            masks.reserveCapacity(paths.count)
            var none: [Int]? = nil
            for p in paths {
                let s = bytes.count
                start.append(Int32(s))
                Fuzzy.append(p, to: &bytes, flags: &flags, charIndex: &none)
                let e = bytes.count
                var ns = s
                var m: UInt64 = 0
                for i in s..<e {
                    let b = bytes[i]
                    m |= 1 << Fuzzy.bit(b)
                    if b == 0x2F { ns = i + 1 }
                }
                nameStart.append(Int32(ns))
                masks.append(m)
                longest = max(longest, e - s)
            }
            start.append(Int32(bytes.count))
        }

        var count: Int { paths.count }

        /// The best `limit` files for `q`: scored on the name, and on the whole path at
        /// `pathWeight`, whichever is higher. Ties: shorter name, then alphabetical.
        func rank(_ q: Query, limit: Int) -> [Match] {
            guard !q.bytes.isEmpty, limit > 0, !paths.isEmpty else { return [] }
            let m = q.bytes.count
            // No alignment can score above this; weighted, it bounds what a path pass can add.
            let pathCeiling = FileTable.pathWeight(Int32(22 * m + 22))
            var top: [(score: Int32, nameLength: Int32, index: Int32)] = []
            top.reserveCapacity(limit + 1)
            // Score of the current last place once `top` is full; below it nothing gets in.
            var floor = Int32.min
            let rows = UnsafeMutablePointer<Int32>.allocate(capacity: 2 * max(longest, 1))
            defer { rows.deallocate() }
            q.bytes.withUnsafeBufferPointer { qb in
                bytes.withUnsafeBufferPointer { bb in
                    flags.withUnsafeBufferPointer { fb in
                        masks.withUnsafeBufferPointer { mb in
                            guard let qp = qb.baseAddress, let bp = bb.baseAddress, let fp = fb.baseAddress,
                                  let mp = mb.baseAddress else { return }
                            let qmask = q.mask
                            var i = 0
                            while i < paths.count {
                                defer { i &+= 1 }
                                if qmask & ~mp[i] != 0 { continue }
                                let s = Int(start[i]), e = Int(start[i &+ 1]), ns = Int(nameStart[i])
                                var best = Fuzzy.align(qp, m, bp + ns, fp + ns, e - ns, rows: rows, rowCount: 2)
                                // The path pass runs only while it could still beat the name and the last place.
                                if best == nil || best! < pathCeiling, pathCeiling >= floor,
                                   let p = Fuzzy.align(qp, m, bp + s, fp + s, e - s, rows: rows, rowCount: 2) {
                                    let weighted = FileTable.pathWeight(p)
                                    if best == nil || weighted > best! { best = weighted }
                                }
                                guard let score = best, score >= floor else { continue }
                                let hit = (score: score, nameLength: Int32(e - ns), index: Int32(i))
                                if top.count == limit, !isBetter(hit, top[limit - 1]) { continue }
                                var at = top.count
                                while at > 0, isBetter(hit, top[at - 1]) { at -= 1 }
                                top.insert(hit, at: at)
                                if top.count > limit { top.removeLast() }
                                if top.count == limit { floor = top[limit - 1].score }
                            }
                        }
                    }
                }
            }
            return top.map { Match(index: Int($0.index), score: Int($0.score)) }
        }

        private func isBetter(_ a: (score: Int32, nameLength: Int32, index: Int32),
                              _ b: (score: Int32, nameLength: Int32, index: Int32)) -> Bool {
            if a.score != b.score { return a.score > b.score }
            if a.nameLength != b.nameLength { return a.nameLength < b.nameLength }
            return nameIsOrderedBefore(Int(a.index), Int(b.index))
        }

        private func nameIsOrderedBefore(_ a: Int, _ b: Int) -> Bool {
            let sa = Int(nameStart[a]), ea = Int(start[a + 1])
            let sb = Int(nameStart[b]), eb = Int(start[b + 1])
            var i = sa, j = sb
            while i < ea, j < eb {
                if bytes[i] != bytes[j] { return bytes[i] < bytes[j] }
                i += 1; j += 1
            }
            return (ea - sa) < (eb - sb)
        }
    }

    // MARK: Scoring constants

    static let matchBase: Int32 = 4
    static let bonusStart: Int32 = 16
    static let bonusBoundary: Int32 = 10
    static let bonusCamel: Int32 = 8
    static let bonusConsecutive: Int32 = 8
    static let bonusSubstring: Int32 = 24
    static let gapOpen: Int32 = 3
    static let gapExtend: Int32 = 1
    static let leadCap: Int32 = 12

    private static let flagBoundary: UInt8 = 1
    private static let flagCamel: UInt8 = 2
    /// "No alignment ends here." Far below any real score even after gap decay.
    private static let neg: Int32 = -1_000_000_000
    private static let invalid: Int32 = -500_000_000

    // MARK: Alignment

    /// Score of the best alignment of the `m` query bytes at `q` in the `n` candidate bytes at
    /// `c`, or `nil`. `f` carries `c`'s flags. `rows` holds `rowCount * n` cells: two rows
    /// suffice for the score; `m` rows keep the whole matrix for `traceback`.
    ///
    /// Cell `(j, i)` is the best score with `q[j]` matched at `c[i]`. It extends the previous
    /// row either from `i - 1` (a consecutive pair) or from any earlier cell through a gap,
    /// whose cost is tracked as a running maximum so each row is a single pass.
    static func align(_ q: UnsafePointer<UInt8>, _ m: Int, _ c: UnsafePointer<UInt8>, _ f: UnsafePointer<UInt8>, _ n: Int,
                      rows: UnsafeMutablePointer<Int32>, rowCount: Int) -> Int32? {
        guard m > 0, m <= n else { return nil }
        if m > 1, !isSubsequence(q, m, c, n) { return nil }
        var prev = rows
        let q0 = q[0]
        var best = neg
        var i = 0
        while i < n {
            if c[i] == q0 {
                let v = matchBase &+ bonus(at: i, f) &- (i < 12 ? Int32(i) : leadCap)
                prev[i] = v
                if v > best { best = v }
            } else {
                prev[i] = neg
            }
            i &+= 1
        }
        if m == 1 {
            // Every single-byte match is also a substring match.
            return best > invalid ? best &+ bonusSubstring : nil
        }
        var j = 1
        while j < m {
            let cur = rows + (j % rowCount) * n
            let qj = q[j]
            var gap = neg
            i = 0
            while i < n {
                if i >= 2 {
                    if gap > invalid { gap &-= gapExtend }
                    let opened = prev[i &- 2]
                    if opened > invalid, opened &- gapOpen > gap { gap = opened &- gapOpen }
                }
                if c[i] == qj {
                    var v = gap
                    if i >= 1 {
                        let run = prev[i &- 1]
                        if run > invalid, run &+ bonusConsecutive > v { v = run &+ bonusConsecutive }
                    }
                    cur[i] = v > invalid ? v &+ matchBase &+ bonus(at: i, f) : neg
                } else {
                    cur[i] = neg
                }
                i &+= 1
            }
            prev = cur
            j &+= 1
        }
        best = neg
        i = 0
        while i < n {
            if prev[i] > best { best = prev[i] }
            i &+= 1
        }
        guard best > invalid else { return nil }
        return best &+ (containsSubstring(c, n, q, m) ? bonusSubstring : 0)
    }

    /// Matched byte offsets of the best alignment. `rows` must hold the full matrix written
    /// by `align(rowCount: m)`.
    private static func traceback(_ q: UnsafePointer<UInt8>, _ m: Int, _ c: UnsafePointer<UInt8>,
                                  _ f: UnsafePointer<UInt8>, _ n: Int, rows: UnsafePointer<Int32>) -> [Int] {
        let last = rows + (m - 1) * n
        var i = 0
        var best = neg
        for k in 0..<n where last[k] > best { best = last[k]; i = k }
        var out = [Int](repeating: 0, count: m)
        out[m - 1] = i
        var j = m - 1
        while j > 0 {
            let cur = rows + j * n
            let above = rows + (j - 1) * n
            let v = cur[i] - matchBase - bonus(at: i, f)
            var next = -1
            if i >= 1, above[i - 1] > invalid, above[i - 1] + bonusConsecutive == v {
                next = i - 1
            } else {
                var k = i - 2
                while k >= 0 {
                    let p = above[k]
                    if p > invalid, p - gapOpen - Int32(i - k - 2) * gapExtend == v { next = k; break }
                    k -= 1
                }
            }
            if next < 0 { break }
            i = next
            j -= 1
            out[j] = i
        }
        return out
    }

    @inline(__always)
    private static func bonus(at i: Int, _ f: UnsafePointer<UInt8>) -> Int32 {
        if i == 0 { return bonusStart }
        let flag = f[i]
        if flag & flagBoundary != 0 { return bonusBoundary }
        if flag & flagCamel != 0 { return bonusCamel }
        return 0
    }

    @inline(__always)
    private static func isSubsequence(_ q: UnsafePointer<UInt8>, _ m: Int, _ c: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        var k = 0
        var want = q[0]
        var i = 0
        while i < n {
            if c[i] == want {
                k &+= 1
                if k == m { return true }
                want = q[k]
            }
            i &+= 1
        }
        return false
    }

    @inline(__always)
    private static func containsSubstring(_ c: UnsafePointer<UInt8>, _ n: Int, _ q: UnsafePointer<UInt8>, _ m: Int) -> Bool {
        if m > n { return false }
        let first = q[0]
        var s = 0
        let last = n &- m
        while s <= last {
            if c[s] == first {
                var t = 1
                while t < m, c[s &+ t] == q[t] { t &+= 1 }
                if t == m { return true }
            }
            s &+= 1
        }
        return false
    }

    // MARK: Preparation

    /// Appends the lowercased UTF-8 of `text` with a flag byte per output byte. ASCII strings
    /// take a byte-wise path; anything else goes character by character so case mapping stays
    /// correct, with only the first byte of each character flagged.
    static func append(_ text: String, to bytes: inout [UInt8], flags: inout [UInt8], charIndex: inout [Int]?) {
        var text = text
        let ascii: Bool = text.withUTF8 { buf in
            for b in buf where b >= 0x80 { return false }
            var prev: UInt8 = 0x2F
            var k = 0
            for b in buf {
                let upper = b >= 0x41 && b <= 0x5A
                var flag: UInt8 = 0
                if isSeparator(prev) {
                    flag = flagBoundary
                } else if upper, prev >= 0x61, prev <= 0x7A {
                    flag = flagCamel
                }
                bytes.append(upper ? b | 0x20 : b)
                flags.append(flag)
                charIndex?.append(k)
                k += 1
                prev = b
            }
            return true
        }
        if ascii { return }
        var prev: Character?
        var k = 0
        for ch in text {
            var flag: UInt8 = 0
            if let prev {
                if isSeparator(prev) {
                    flag = flagBoundary
                } else if ch.isUppercase, prev.isLowercase {
                    flag = flagCamel
                }
            } else {
                flag = flagBoundary
            }
            var firstByte = true
            for b in ch.lowercased().utf8 {
                bytes.append(b)
                flags.append(firstByte ? flag : 0)
                charIndex?.append(k)
                firstByte = false
            }
            k += 1
            prev = ch
        }
    }

    @inline(__always)
    private static func isSeparator(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x2D || b == 0x5F || b == 0x2E || b == 0x2F
    }

    private static func isSeparator(_ ch: Character) -> Bool {
        ch == " " || ch == "-" || ch == "_" || ch == "." || ch == "/"
    }

    /// Character class of a lowercased byte: a–z → 0…25, 0–9 → 26…35, other ASCII → 36…62,
    /// any non-ASCII byte → 63. A candidate can only match a query whose classes it contains.
    @inline(__always)
    static func bit(_ b: UInt8) -> UInt64 {
        if b >= 0x61 && b <= 0x7A { return UInt64(b - 0x61) }
        if b >= 0x30 && b <= 0x39 { return UInt64(26 + b - 0x30) }
        if b < 0x80 { return 36 + UInt64(b % 27) }
        return 63
    }

    static func mask(of bytes: ArraySlice<UInt8>) -> UInt64 {
        var m: UInt64 = 0
        for b in bytes { m |= 1 << bit(b) }
        return m
    }
}
