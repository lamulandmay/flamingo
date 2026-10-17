import Foundation

/// Obsidian-style wikilinks: `[[target]]`, `[[target|alias]]`, `[[target#anchor]]`,
/// `[[target#anchor|alias]]`, and `![[target]]` embeds.
///
/// Two halves:
/// - **Parsing.** `links(in:)` finds every `[[...]]` in a text (skipping Markdown code spans),
///   `parse(_:)` reduces that to de-duplicated bare targets, and `components(of:)` /
///   `anchor(in:)` split one link into target, anchor and alias.
/// - **Resolution.** `Resolver` maps a target to a `FileRef` the way Obsidian users expect:
///   full relative path, then path without extension, then basename, then basename without
///   extension, each repeated case-insensitively. The static `resolve` functions are thin
///   wrappers over `Resolver` for one-off lookups.
public enum Wikilink {

    // MARK: - Link

    /// One `[[...]]` occurrence in a text, as found by `links(in:)`.
    public struct Link: Hashable, Sendable {
        /// The inner text between the brackets exactly as written: untrimmed, alias and anchor included.
        public let raw: String
        /// Bare target: trimmed, without alias or anchor. Empty for self-links such as `[[#heading]]`.
        public let target: String
        /// Text after the first `|`, trimmed. `nil` when there is no alias (or it is blank).
        public let alias: String?
        /// Text after the first `#` and before any `|`, trimmed. `nil` when there is no anchor (or it is blank).
        public let anchor: String?
        /// Range of the whole `[[...]]` in the source string. The `!` of an embed is not included.
        public let range: Range<String.Index>

        /// Creates a link from the inner text of a `[[...]]` and its range in the source string.
        /// `target`, `anchor` and `alias` are derived with `Wikilink.components(of:)`.
        public init(raw: String, range: Range<String.Index>) {
            let parts = Wikilink.components(of: raw)
            self.raw = raw
            self.target = parts.target
            self.anchor = parts.anchor
            self.alias = parts.alias
            self.range = range
        }

        /// The anchor as a `FileAnchor` when it has the `<kind> <value>` form (`slide 3`, `cell Q3!B12`).
        /// `nil` for heading or block anchors and for links without an anchor. See `Wikilink.anchor(in:)`.
        public var fileAnchor: FileAnchor? { Wikilink.anchor(in: raw) }
    }

    // MARK: - Parsing

    /// Every `[[...]]` link in `text`, in order of appearance. Not de-duplicated; links with an
    /// empty target (`[[#heading]]`, `[[]]`) are included.
    ///
    /// Rules:
    /// - The inner text may not contain `[`, `]` or a newline. When a `[[` is not followed by a
    ///   well-formed inner text and `]]`, it is not a link; scanning resumes one character later,
    ///   so `[[a [[b]] c]]` yields exactly one link, `b`, and `[[a]b]]` yields none.
    /// - `![[x]]` embeds count as links to `x`.
    /// - Markdown code spans are skipped. A run of N backticks opens a span closed by the next run
    ///   of exactly N backticks (CommonMark); an unclosed run is literal text.
    public static func links(in text: String) -> [Link] {
        let scalars = text.unicodeScalars
        let end = scalars.endIndex
        var out: [Link] = []
        var i = scalars.startIndex

        while i < end {
            let c = scalars[i]
            if c == "`" {
                let run = backtickRun(from: i, in: scalars)
                if let spanEnd = closingBacktickRun(length: run.length, from: run.end, in: scalars) {
                    i = spanEnd
                } else {
                    i = run.end
                }
                continue
            }
            if c == "[" {
                let second = scalars.index(after: i)
                if second < end, scalars[second] == "[" {
                    let innerStart = scalars.index(after: second)
                    if let close = closingBrackets(from: innerStart, in: scalars) {
                        let raw = String(scalars[innerStart..<close.lowerBound])
                        out.append(Link(raw: raw, range: i..<close.upperBound))
                        i = close.upperBound
                    } else {
                        i = second
                    }
                    continue
                }
            }
            i = scalars.index(after: i)
        }
        return out
    }

    /// Bare non-empty targets (without alias or anchor) in order of first appearance,
    /// de-duplicated by exact string match. Code spans are skipped; see `links(in:)`.
    public static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for link in links(in: text) where !link.target.isEmpty {
            if seen.insert(link.target).inserted { out.append(link.target) }
        }
        return out
    }

    /// Splits raw link text `target#anchor|alias` into its parts.
    ///
    /// The alias is split off first at the first `|` (so an alias may contain `#`), then the
    /// anchor at the first `#`. All parts are trimmed of whitespace; a blank anchor or alias is
    /// reported as `nil`. Surrounding `[[` `]]` and a leading `!` (embed) are accepted and
    /// stripped, so `components(of: "![[q3.pptx#slide 3|Q3]]")` is `("q3.pptx", "slide 3", "Q3")`.
    public static func components(of raw: String) -> (target: String, anchor: String?, alias: String?) {
        var body = Substring(raw.trimmed())
        if body.hasPrefix("![[") { body = body.dropFirst() }
        if body.hasPrefix("[["), body.hasSuffix("]]") { body = body.dropFirst(2).dropLast(2) }

        var alias: String? = nil
        if let pipe = body.firstIndex(of: "|") {
            alias = body[body.index(after: pipe)...].trimmed().nonEmpty
            body = body[..<pipe]
        }
        var anchor: String? = nil
        if let hash = body.firstIndex(of: "#") {
            anchor = body[body.index(after: hash)...].trimmed().nonEmpty
            body = body[..<hash]
        }
        return (body.trimmed(), anchor, alias)
    }

    /// Parses the `#anchor` suffix of a link into a `FileAnchor`.
    ///
    /// Anchor syntax is `<kind> <value>`: a `FileAnchor.Kind` raw value (case-insensitive),
    /// whitespace, then a non-empty value (the rest of the anchor, trimmed). Accepts the same
    /// forms as `components(of:)`, so `"q3.pptx#slide 3"`, `"[[q3.pptx#cell Q3!B12]]"` and
    /// `"deck#page 12|see this"` all work. Heading anchors (`#Intro`), block anchors
    /// (`#^abc`), unknown kinds and links without an anchor give `nil`.
    public static func anchor(in raw: String) -> FileAnchor? {
        guard let anchor = components(of: raw).anchor else { return nil }
        guard let split = anchor.firstIndex(where: { $0.isWhitespace }) else { return nil }
        guard let kind = FileAnchor.Kind(rawValue: anchor[..<split].lowercased()) else { return nil }
        guard let value = anchor[split...].trimmed().nonEmpty else { return nil }
        return FileAnchor(kind: kind, value: value)
    }

    // MARK: - Resolution

    /// Resolves a link target to a file, including confirmed historical paths in the vault.
    /// Builds a `Resolver` per call; use one resolver with a single alias snapshot for batches.
    public static func resolve(_ target: String, in vault: Vault, candidates: [FileRef]) -> FileRef? {
        resolveOnce(target, from: nil, aliases: (try? PathAliases(vault: vault).all()) ?? [:], candidates: candidates)
    }

    /// Like `resolve(_:in:candidates:)`, but when several candidates tie, prefers the one in the
    /// same folder as `source`.
    public static func resolve(_ target: String, from source: FileRef, in vault: Vault, candidates: [FileRef]) -> FileRef? {
        resolveOnce(target, from: source, aliases: (try? PathAliases(vault: vault).all()) ?? [:], candidates: candidates)
    }

    /// One link against a whole vault, as the shell does on every click: instead of indexing
    /// every candidate (8 NFC-normalised, lowercased keys each: 126 ms for 35k files), keep only
    /// the candidates whose name could match the target, plus any under a renamed folder that
    /// aliases might map the target onto, and resolve among those. Every tier key of a matching
    /// candidate ends in the target's last component, so the result is the same as a `Resolver`
    /// over all candidates.
    static func resolveOnce(_ target: String, from source: FileRef?, aliases: [String: String], candidates: [FileRef]) -> FileRef? {
        guard let query = normalizedQuery(target) else { return nil }
        let wanted = Array(lastComponent(of: query.lowercased()).utf8)
        let wantedIsASCII = wanted.allSatisfy { $0 < 0x80 }
        let aliasTargets = Set(((try? PathAliases.validated(aliases)) ?? [:]).values)
        var possible: [FileRef] = []
        for ref in candidates where nameMayMatch(ref.relativePath, wanted: wanted, wantedIsASCII: wantedIsASCII)
            || (!aliasTargets.isEmpty && isUnder(aliasTargets, ref.relativePath)) {
            possible.append(ref)
        }
        let resolver = Resolver(candidates: possible, aliases: aliases)
        return source.map { resolver.resolve(target, from: $0) } ?? resolver.resolve(target)
    }

    /// Conservative: true whenever the candidate's lowercased NFC basename, or that basename
    /// without its extension, could equal `wanted`. Plain ASCII names are checked byte-wise;
    /// anything else takes the exact (slow) path.
    private static func nameMayMatch(_ path: String, wanted: [UInt8], wantedIsASCII: Bool) -> Bool {
        let utf8 = path.utf8
        var start = utf8.endIndex
        var ascii = true
        while start > utf8.startIndex {
            let b = utf8[utf8.index(before: start)]
            if b == UInt8(ascii: "/") { break }
            if b >= 0x80 || b == UInt8(ascii: "\\") { ascii = false }
            start = utf8.index(before: start)
        }
        guard ascii, start < utf8.endIndex else {
            let name = lastComponent(of: normalizedPath(path))
            return Array(name.lowercased().utf8) == wanted || Array(droppingExtension(name).lowercased().utf8) == wanted
        }
        // Lowercasing never turns ASCII into non-ASCII, so an ASCII name can't match otherwise.
        guard wantedIsASCII else { return false }
        let name = utf8[start...]
        func same<C: Collection>(_ bytes: C) -> Bool where C.Element == UInt8 {
            guard bytes.count == wanted.count else { return false }
            var i = 0
            for b in bytes {
                let lower = b >= 65 && b <= 90 ? b + 32 : b
                if lower != wanted[i] { return false }
                i += 1
            }
            return true
        }
        if same(name) { return true }
        // Without its extension: up to the last dot, which must not be the first character.
        guard let dot = name.lastIndex(of: UInt8(ascii: ".")), dot != name.startIndex else { return false }
        return same(name[..<dot])
    }

    /// Whether `path` (or its NFC form) is one of `prefixes` or inside one.
    private static func isUnder(_ prefixes: Set<String>, _ path: String) -> Bool {
        let plain = path.utf8.allSatisfy { $0 < 0x80 && $0 != UInt8(ascii: "\\") }
        var prefix = Substring(plain ? path : normalizedPath(path))
        while !prefix.isEmpty {
            if prefixes.contains(String(prefix)) { return true }
            guard let slash = prefix.lastIndex(of: "/") else { return false }
            prefix = prefix[..<slash]
        }
        return false
    }

    /// A precomputed index over a candidate list, for resolving many links fast.
    ///
    /// The query is normalized first: alias and anchor are dropped (`components(of:)`), `\` is
    /// collapsed to `/`, a leading `./` or `/` and a trailing `/` are stripped, and the result is
    /// put in NFC (candidate paths are normalized the same way). An empty target resolves to `nil`.
    ///
    /// Match tiers, first tier with any match wins:
    /// 1. exact relative path (`decks/q3.pptx`)
    /// 2. relative path without extension (`decks/q3`)
    /// 3. basename (`q3.pptx`)
    /// 4. basename without extension (`q3`)
    /// 5–8. the same four, case-insensitively
    ///
    /// Within the winning tier, ties are broken by: same folder as the `source` file (when given),
    /// then fewest path components, then `localizedStandardCompare` of the relative path. The
    /// result is deterministic regardless of candidate order.
    public final class Resolver: @unchecked Sendable {
        /// One table per tier, in priority order. Tiers 0–3 are keyed by exact normalized
        /// strings, tiers 4–7 by their lowercased forms.
        private let tiers: [[String: [FileRef]]]
        /// Historical spellings use the same tiers, after real paths in each tier. Reusing an
        /// old exact filename always selects the current file instead of redirecting it.
        private let aliasTiers: [[String: [FileRef]]]
        private static let tierCount = 8

        /// Builds the index. Cost is linear in the number of candidates.
        public init(candidates: [FileRef], aliases: [String: String] = [:]) {
            var tables = Array(repeating: [String: [FileRef]](), count: Resolver.tierCount)
            for ref in candidates {
                for (tier, key) in Wikilink.candidateKeys(for: ref.relativePath).enumerated() {
                    tables[tier][key, default: []].append(ref)
                }
            }
            tiers = tables
            aliasTiers = Self.aliasTables(candidates: candidates, aliases: (try? PathAliases.validated(aliases)) ?? [:])
        }

        /// Resolves `target` (bare, or full `[[target#anchor|alias]]` text) to a candidate, or `nil`.
        public func resolve(_ target: String) -> FileRef? {
            resolve(target, source: nil)
        }

        /// Resolves `target`, preferring candidates in the same folder as `source` when several tie.
        public func resolve(_ target: String, from source: FileRef) -> FileRef? {
            resolve(target, source: source)
        }

        private func resolve(_ target: String, source: FileRef?) -> FileRef? {
            guard let query = Wikilink.normalizedQuery(target) else { return nil }
            let folded = query.lowercased()
            for (tier, table) in tiers.enumerated() {
                let key = tier < Resolver.tierCount / 2 ? query : folded
                if let matches = table[key], !matches.isEmpty {
                    return Wikilink.best(of: matches, near: source)
                }
                if let matches = aliasTiers[tier][key], !matches.isEmpty {
                    // On a case-insensitive vault a newly created `old.md` also occupies
                    // the old `OLD.md` name. Its exact path wins over a historical redirect.
                    if let current = tiers[4][folded], !current.isEmpty {
                        return Wikilink.best(of: current, near: source)
                    }
                    return Wikilink.best(of: matches, near: source)
                }
            }
            return nil
        }

        /// Reverse only matching path prefixes, avoiding an aliases × whole-vault scan.
        /// A specific child rename can override an older folder rename. Forward resolution
        /// validates each proposed spelling so that the broader alias cannot steal that link.
        private static func aliasTables(candidates: [FileRef], aliases: [String: String]) -> [[String: [FileRef]]] {
            var tables = Array(repeating: [String: [FileRef]](), count: tierCount)
            guard !aliases.isEmpty else { return tables }
            var reversed: [String: [String]] = [:]
            for (old, new) in aliases { reversed[new, default: []].append(old) }
            for ref in candidates {
                let actual = Wikilink.normalizedPath(ref.relativePath)
                var seen: Set<String> = [actual]
                var queue: [(path: String, used: Set<String>)] = [(actual, [])]
                var cursor = 0
                while cursor < queue.count {
                    let item = queue[cursor]
                    cursor += 1
                    var prefix = item.path
                    while !prefix.isEmpty {
                        for old in reversed[prefix] ?? [] where !item.used.contains(old) {
                            let historical = old + item.path.dropFirst(prefix.count)
                            guard seen.insert(historical).inserted,
                                  PathAliases.resolvedPath(historical, aliases: aliases) == actual else { continue }
                            for (tier, key) in Wikilink.candidateKeys(for: historical).enumerated() {
                                tables[tier][key, default: []].append(ref)
                            }
                            var used = item.used; used.insert(old)
                            queue.append((historical, used))
                        }
                        guard let slash = prefix.lastIndex(of: "/") else { break }
                        prefix = String(prefix[..<slash])
                    }
                }
            }
            return tables
        }
    }

    // MARK: - Scanner helpers

    private typealias Scalars = String.UnicodeScalarView

    /// Measures the run of backticks starting at `start`.
    private static func backtickRun(from start: String.Index, in scalars: Scalars) -> (end: String.Index, length: Int) {
        var j = start
        var n = 0
        while j < scalars.endIndex, scalars[j] == "`" {
            n += 1
            j = scalars.index(after: j)
        }
        return (j, n)
    }

    /// Index just past the next backtick run of exactly `length` scalars, or `nil` if there is
    /// none (the opening run is then literal text).
    private static func closingBacktickRun(length: Int, from start: String.Index, in scalars: Scalars) -> String.Index? {
        var j = start
        while j < scalars.endIndex {
            if scalars[j] == "`" {
                let run = backtickRun(from: j, in: scalars)
                if run.length == length { return run.end }
                j = run.end
            } else {
                j = scalars.index(after: j)
            }
        }
        return nil
    }

    /// Scans inner link text from `start` and returns the range of the closing `]]`, or `nil` if
    /// a `[`, a lone `]`, a newline, or the end of input comes first.
    private static func closingBrackets(from start: String.Index, in scalars: Scalars) -> Range<String.Index>? {
        var k = start
        while k < scalars.endIndex {
            let d = scalars[k]
            if d == "]" {
                let next = scalars.index(after: k)
                if next < scalars.endIndex, scalars[next] == "]" {
                    return k..<scalars.index(after: next)
                }
                return nil
            }
            if d == "[" || CharacterSet.newlines.contains(d) { return nil }
            k = scalars.index(after: k)
        }
        return nil
    }

    // MARK: - Resolution helpers

    /// Collapses `\` to `/` and applies NFC. Used for both candidates and queries.
    static func normalizedPath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").precomposedStringWithCanonicalMapping
    }

    /// The normalized bare target of a link, or `nil` when it is empty.
    static func normalizedQuery(_ target: String) -> String? {
        var t = Substring(normalizedPath(components(of: target).target))
        while true {
            if t.hasPrefix("./") { t = t.dropFirst(2) }
            else if t.hasPrefix("/") { t = t.dropFirst() }
            else { break }
        }
        while t.hasSuffix("/") { t = t.dropLast() }
        return String(t).nonEmpty
    }

    /// The eight lookup keys for a candidate, in tier order: path, path without extension,
    /// basename, basename without extension, then the four lowercased.
    static func candidateKeys(for relativePath: String) -> [String] {
        let path = normalizedPath(relativePath)
        let name = lastComponent(of: path)
        let exact = [path, droppingExtension(path), name, droppingExtension(name)]
        return exact + exact.map { $0.lowercased() }
    }

    /// Text after the last `/`, or the whole string.
    static func lastComponent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// Text before the last `/`, or `""` for a root-level path.
    static func parentDirectory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// Removes the extension from the last path component. A leading dot (`.bashrc`) is not an extension.
    static func droppingExtension(_ path: String) -> String {
        let nameStart = path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex
        guard let dot = path[nameStart...].lastIndex(of: "."), dot > nameStart else { return path }
        return String(path[..<dot])
    }

    /// Deterministic tie-break among candidates of one tier: same folder as `source` first,
    /// then fewest path components, then `localizedStandardCompare` ascending.
    static func best(of matches: [FileRef], near source: FileRef?) -> FileRef? {
        guard matches.count > 1 else { return matches.first }
        let sourceDir = source.map { parentDirectory(of: normalizedPath($0.relativePath)) }
        return matches.min { a, b in
            let pa = normalizedPath(a.relativePath), pb = normalizedPath(b.relativePath)
            if let sourceDir {
                let aNear = parentDirectory(of: pa) == sourceDir
                let bNear = parentDirectory(of: pb) == sourceDir
                if aNear != bNear { return aNear }
            }
            let ca = pa.split(separator: "/").count, cb = pb.split(separator: "/").count
            if ca != cb { return ca < cb }
            return a.relativePath.localizedStandardCompare(b.relativePath) == .orderedAscending
        }
    }
}

// MARK: - Small string helpers

private extension StringProtocol {
    /// Whitespace and newlines removed from both ends.
    func trimmed() -> String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

private extension String {
    /// `self`, or `nil` when empty.
    var nonEmpty: String? { isEmpty ? nil : self }
}
