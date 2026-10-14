import Foundation
import FlamingoCore
import FlamingoIndex

/// A section of a file as retrieval sees it.
struct SourceSection: Sendable, Equatable {
    var anchor: FileAnchor
    var title: String?
    var text: String
}

/// What retrieval reads from the vault. `IndexStore` in the app, a fake in tests.
protocol PassageSource: Sendable {
    var vault: Vault { get }
    func search(_ query: String, limit: Int) throws -> [SearchHit]
    func sections(of ref: FileRef) throws -> [SourceSection]
    func text(of ref: FileRef) throws -> String?
    func comments() throws -> [FileRef: [Comment]]
    func files() -> [FileRef]
}

struct IndexSource: PassageSource {
    let index: IndexStore
    var vault: Vault { index.vault }
    func search(_ query: String, limit: Int) throws -> [SearchHit] { try index.search(query, limit: limit) }
    func sections(of ref: FileRef) throws -> [SourceSection] {
        try index.sections(of: ref).map { SourceSection(anchor: $0.anchor, title: $0.title, text: $0.text) }
    }
    func text(of ref: FileRef) throws -> String? { try index.text(of: ref) }
    func comments() throws -> [FileRef: [Comment]] { try SidecarStore(vault: index.vault).all() }
    func files() -> [FileRef] { VaultScanner.files(in: index.vault) }
}

/// Turns a question into index queries: the question itself, its content words, each clause
/// split on "and", and the strongest single words stemmed so the index's trailing-prefix match
/// catches "price" from "pricing".
enum QueryPlan {
    struct Query: Equatable {
        var text: String
        var weight: Double
    }

    static func queries(for question: String) -> [Query] {
        var out: [Query] = []
        func add(_ text: String, _ weight: Double) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !out.contains(where: { $0.text.lowercased() == t.lowercased() }) else { return }
            out.append(Query(text: t, weight: weight))
        }
        add(question, 1)
        let all = terms(question)
        add(all.joined(separator: " "), 1)
        let parts = clauses(question)
        if parts.count > 1 {
            for part in parts { add(terms(part).joined(separator: " "), 0.8) }
        }
        if all.count > 1 {
            for term in all.sorted(by: { $0.count > $1.count }).prefix(4) { add(stem(term), 0.5) }
        }
        return out
    }

    /// Lowercased content words in order, without stopwords or duplicates.
    static func terms(_ text: String) -> [String] {
        var seen = Set<String>()
        return words(text).filter { $0.count > 1 && !stopwords.contains($0) && seen.insert($0).inserted }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func clauses(_ question: String) -> [String] {
        question.replacingOccurrences(of: #"\s+(and|&|vs\.?|versus)\s+|[,;]"#, with: "\u{1F}",
                                      options: [.regularExpression, .caseInsensitive])
            .split(separator: "\u{1F}").map(String.init)
            .filter { !terms($0).isEmpty }
    }

    /// A light suffix strip. Never shorter than four characters.
    static func stem(_ word: String) -> String {
        for suffix in ["ations", "ation", "ings", "ing", "ies", "ed", "es", "ly", "s"] where word.hasSuffix(suffix) {
            let base = String(word.dropLast(suffix.count))
            if base.count >= 4 { return base }
        }
        return word
    }

    static let stopwords: Set<String> = [
        "a", "about", "above", "after", "again", "against", "all", "am", "an", "any", "are", "as", "at",
        "be", "because", "been", "before", "being", "below", "between", "both", "but", "by", "can", "could",
        "did", "do", "does", "doing", "done", "down", "during", "each", "else", "ever", "few", "for", "from",
        "further", "get", "got", "had", "has", "have", "having", "he", "her", "here", "hers", "him", "his",
        "how", "i", "if", "in", "into", "is", "it", "its", "itself", "just", "let", "like", "me", "more",
        "most", "much", "my", "myself", "no", "nor", "not", "now", "of", "off", "on", "once", "only", "or",
        "other", "our", "ours", "out", "over", "own", "same", "she", "should", "so", "some", "such", "than",
        "that", "the", "their", "theirs", "them", "then", "there", "these", "they", "this", "those",
        "through", "to", "too", "under", "until", "up", "us", "very", "was", "we", "were", "what", "when",
        "where", "which", "while", "who", "whom", "why", "will", "with", "would", "you", "your", "yours",
        "and", "vs", "versus",
        // Words about the vault rather than in it.
        "say", "said", "says", "think", "thought", "mention", "mentioned", "mentions", "tell", "told",
        "know", "wrote", "write", "written", "comment", "comments", "commented", "note", "notes", "file",
        "files", "vault", "anything", "something", "thing", "things", "where", "find",
    ]
}

/// Retrieval for one question. Keeps what it has already handed out so follow-up searches
/// (the model's `search` tool) return only new passages, numbered after the earlier ones.
final class Retriever {
    /// A section about to become a passage. Anchorless when the hit was the whole file.
    struct Candidate {
        var file: FileRef
        var anchor: FileAnchor?
        var title: String?
        var text: String
    }

    let source: PassageSource
    var sectionLimit = 20
    var maxSectionChars = 1800
    var maxCommentChars = 1200

    private(set) var nextID = 1
    private var seen = Set<String>()
    private var sectionCache: [FileRef: [SourceSection]] = [:]
    private lazy var allComments: [FileRef: [Comment]] = (try? source.comments()) ?? [:]
    private lazy var allFiles: [FileRef] = source.files()

    init(source: PassageSource) { self.source = source }

    /// Searches the index for `question` and its reformulations, then packs comments first and
    /// sections by rank into `budgetTokens`. Throws only if every index query failed.
    func retrieve(_ question: String, budgetTokens: Int = 12_000) throws -> [Passage] {
        let terms = QueryPlan.terms(question)
        let ranked = try fusedHits(for: question)

        // A hit that is really one of the user's comments boosts that comment; the rest are sections.
        var commentBoost: [UUID: Double] = [:]
        var sectionHits: [SearchHit] = []
        for (hit, score) in ranked {
            if let c = Self.comment(matching: hit, in: allComments[hit.file] ?? []) {
                commentBoost[c.id, default: 0] += score * 61   // rank 1 of a weight-1 query ≈ 1
            } else if !seen.contains(Self.key(hit.file, hit.anchor)) {
                sectionHits.append(hit)
            }
        }
        let topHits = Array(sectionHits.prefix(sectionLimit))
        let hitFiles = Set(topHits.map(\.file))
        let hitPlaces = Set(topHits.map { Self.key($0.file, $0.anchor) })

        let comments = rankComments(terms: terms, boost: commentBoost, hitFiles: hitFiles, hitPlaces: hitPlaces)

        // Sections: direct hits by rank, with files the top comments link to slotted in after
        // the first few, since those links are how the user connected things.
        var sections: [Candidate] = topHits.map { hit in
            sectionText(for: hit) ?? Candidate(file: hit.file, anchor: hit.anchor, title: nil, text: Self.plain(hit.snippet))
        }
        let linked = linkedSections(from: comments.prefix(8).map(\.comment), terms: terms,
                                    excluding: Set(sections.map { Self.key($0.file, $0.anchor) }))
        sections.insert(contentsOf: linked, at: min(3, sections.count))

        // Pack.
        var out: [Passage] = []
        var used = 0
        let commentBudget = sections.isEmpty ? budgetTokens : budgetTokens * 45 / 100
        for (file, c, _) in comments.prefix(40) {
            let key = "c:\(c.id.uuidString)"
            guard !seen.contains(key) else { continue }
            let p = Passage(id: nextID, kind: .comment, file: file, anchor: c.anchor,
                            text: Self.excerpt(c.text, terms: terms, max: maxCommentChars), timestamp: c.timestamp)
            let cost = Self.tokens(p)
            guard used + cost <= commentBudget else { continue }
            out.append(p); used += cost; nextID += 1; seen.insert(key)
        }
        for s in sections {
            let key = Self.key(s.file, s.anchor)
            guard !seen.contains(key) else { continue }
            let text = Self.excerpt(s.text, terms: terms, max: maxSectionChars)
            guard !text.isEmpty else { continue }
            let p = Passage(id: nextID, kind: .section, file: s.file, anchor: s.anchor, title: s.title, text: text)
            let cost = Self.tokens(p)
            guard used + cost <= budgetTokens else { continue }
            out.append(p); used += cost; nextID += 1; seen.insert(key)
        }
        return out
    }

    // MARK: Ranking

    /// Reciprocal-rank fusion over every reformulation, deduped by file + anchor. Rank, not the
    /// index's raw score, so the result doesn't depend on how bm25 is signed or scaled.
    private func fusedHits(for question: String) throws -> [(SearchHit, Double)] {
        var fused: [String: (hit: SearchHit, score: Double, order: Int)] = [:]
        var failures: [Error] = []
        let queries = QueryPlan.queries(for: question)
        for q in queries {
            let hits: [SearchHit]
            do { hits = try source.search(q.text, limit: 50) } catch { failures.append(error); continue }
            for (rank, hit) in hits.enumerated() {
                let key = Self.key(hit.file, hit.anchor)
                let score = q.weight / Double(60 + rank + 1)
                if let e = fused[key] { fused[key] = (e.hit, e.score + score, e.order) }
                else { fused[key] = (hit, score, fused.count) }
            }
        }
        if failures.count == queries.count, let first = failures.first { throw first }
        return fused.values
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            .map { ($0.hit, $0.score) }
    }

    private func rankComments(terms: [String], boost: [UUID: Double], hitFiles: Set<FileRef>,
                              hitPlaces: Set<String>) -> [(file: FileRef, comment: Comment, score: Double)] {
        var out: [(file: FileRef, comment: Comment, score: Double)] = []
        for (file, comments) in allComments {
            for c in comments {
                let matched = Self.matchCount(terms, in: c.text)
                let onHit = c.anchor != nil && hitPlaces.contains(Self.key(file, c.anchor))
                let linksToHit = !hitFiles.isEmpty && c.links.contains {
                    Wikilink.resolve($0, in: source.vault, candidates: Array(hitFiles)) != nil
                }
                let direct = matched > 0 || boost[c.id] != nil
                guard direct || onHit || linksToHit else { continue }
                var score = terms.isEmpty ? 0 : Double(matched) / Double(terms.count)
                score += boost[c.id] ?? 0
                if hitFiles.contains(file) { score += 0.5 }
                if onHit { score += 0.3 }
                if linksToHit { score += 0.5 }
                if !direct { score *= 0.5 }
                out.append((file, c, score))
            }
        }
        return out.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.comment.timestamp > $1.comment.timestamp
        }
    }

    /// The best section of each file the comments link to: the `#anchor` if the link names one,
    /// else the section sharing the most words with the question.
    private func linkedSections(from comments: [Comment], terms: [String], excluding: Set<String>) -> [Candidate] {
        var out: [Candidate] = []
        var taken = excluding
        for c in comments {
            for link in Self.links(in: c.text) {
                guard let file = Wikilink.resolve(link.target, in: source.vault, candidates: allFiles) else { continue }
                let sections = cachedSections(of: file)
                var pick: SourceSection?
                if let a = link.anchor { pick = sections.first { $0.anchor == a } }
                if pick == nil {
                    pick = sections
                        .map { ($0, Self.matchCount(terms, in: ($0.title ?? "") + " " + $0.text)) }
                        .filter { $0.1 > 0 }
                        .max { $0.1 < $1.1 }?.0
                }
                if pick == nil, sections.isEmpty, let text = try? source.text(of: file), !text.isEmpty {
                    let key = Self.key(file, nil)
                    if taken.insert(key).inserted { out.append(Candidate(file: file, anchor: nil, title: nil, text: text)) }
                    continue
                }
                guard let s = pick ?? sections.first else { continue }
                if taken.insert(Self.key(file, s.anchor)).inserted {
                    out.append(Candidate(file: file, anchor: s.anchor, title: s.title, text: s.text))
                }
            }
        }
        return out
    }

    // MARK: Text

    private func cachedSections(of file: FileRef) -> [SourceSection] {
        if let s = sectionCache[file] { return s }
        let s = (try? source.sections(of: file)) ?? []
        sectionCache[file] = s
        return s
    }

    /// The full section behind a hit, so the model reads more than the snippet. A cell hit
    /// falls back to its sheet; an anchorless hit to the file's text.
    private func sectionText(for hit: SearchHit) -> Candidate? {
        let sections = cachedSections(of: hit.file)
        if let a = hit.anchor {
            let s = sections.first(where: { $0.anchor == a })
                ?? (a.kind == .cell ? sections.first {
                    $0.anchor.kind == .sheet && a.value.hasPrefix($0.anchor.value + "!")
                } : nil)
            return s.map { Candidate(file: hit.file, anchor: $0.anchor, title: $0.title, text: $0.text) }
        }
        if let text = try? source.text(of: hit.file), !text.isEmpty {
            return Candidate(file: hit.file, anchor: nil, title: nil, text: text)
        }
        return nil
    }

    static func key(_ file: FileRef, _ anchor: FileAnchor?) -> String {
        "s:\(file.relativePath)|\(anchor?.rendered ?? "")"
    }

    static func plain(_ snippet: String) -> String {
        snippet.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "")
    }

    static func normalized(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The comment a search hit came from, if it came from one: same place, and the snippet's
    /// longest fragment appears in the comment's text.
    static func comment(matching hit: SearchHit, in comments: [Comment]) -> Comment? {
        let fragments = plain(hit.snippet)
            .replacingOccurrences(of: "...", with: "…")
            .components(separatedBy: "…")
            .map(normalized)
        guard let longest = fragments.max(by: { $0.count < $1.count }), longest.count >= 6 else { return nil }
        return comments.first { $0.anchor == hit.anchor && normalized($0.text).contains(longest) }
    }

    /// How many of the terms appear in `text`, matching stems against word prefixes.
    static func matchCount(_ terms: [String], in text: String) -> Int {
        guard !terms.isEmpty else { return 0 }
        let words = Set(QueryPlan.words(text))
        return terms.filter { term in
            let stem = QueryPlan.stem(term)
            return words.contains { $0.hasPrefix(stem) }
        }.count
    }

    /// `[[target]]`, `[[target#slide 3]]`, `[[target|alias]]` with the anchor kept.
    static func links(in text: String) -> [(target: String, anchor: FileAnchor?)] {
        guard let re = try? NSRegularExpression(pattern: #"\[\[([^\]|#]+)(?:#([^\]|]+))?(?:\|[^\]]*)?\]\]"#) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let target = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return nil }
            var anchor: FileAnchor?
            if m.range(at: 2).location != NSNotFound {
                let parts = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                    .split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2, let kind = FileAnchor.Kind(rawValue: parts[0].lowercased()) {
                    anchor = FileAnchor(kind: kind, value: parts[1])
                }
            }
            return (target, anchor)
        }
    }

    /// Up to `max` characters, centered a little before the first term so the match has context.
    static func excerpt(_ text: String, terms: [String], max: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > max else { return t }
        var first: String.Index?
        for term in terms {
            if let r = t.range(of: QueryPlan.stem(term), options: [.caseInsensitive, .diacriticInsensitive]),
               first.map({ r.lowerBound < $0 }) ?? true { first = r.lowerBound }
        }
        let center = first.map { t.distance(from: t.startIndex, to: $0) } ?? 0
        let start = Swift.max(0, Swift.min(center - max / 3, t.count - max))
        let lo = t.index(t.startIndex, offsetBy: start)
        let hi = t.index(lo, offsetBy: max)
        var out = Substring(t[lo..<hi])
        if lo > t.startIndex, let space = out.firstIndex(where: \.isWhitespace) {
            out = out[out.index(after: space)...]
        }
        if hi < t.endIndex, let space = out.lastIndex(where: \.isWhitespace) {
            out = out[..<space]
        }
        return (lo > t.startIndex ? "…" : "") + out + (hi < t.endIndex ? "…" : "")
    }

    /// A conservative estimate: UTF-8 bytes over four, plus the tag.
    static func tokens(_ p: Passage) -> Int { (p.prompt.utf8.count + 3) / 4 }
}
