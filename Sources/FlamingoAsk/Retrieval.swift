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
    /// Every matching section, ranked. All terms first, any term when that finds nothing.
    func searchSections(_ query: String, limit: Int) throws -> [SearchHit]
    /// Matching comments, ranked, same matching rules.
    func searchComments(_ query: String, limit: Int) throws -> [CommentHit]
    func sections(of ref: FileRef) throws -> [SourceSection]
    func text(of ref: FileRef) throws -> String?
    func comments(on ref: FileRef) throws -> [Comment]
    func files() -> [FileRef]
}

struct IndexSource: PassageSource {
    let index: IndexStore
    var vault: Vault { index.vault }
    func searchSections(_ query: String, limit: Int) throws -> [SearchHit] { try index.searchSections(query, limit: limit) }
    func searchComments(_ query: String, limit: Int) throws -> [CommentHit] { try index.searchComments(query, limit: limit) }
    func sections(of ref: FileRef) throws -> [SourceSection] {
        try index.sections(of: ref).map { SourceSection(anchor: $0.anchor, title: $0.title, text: $0.text) }
    }
    func text(of ref: FileRef) throws -> String? { try index.text(of: ref) }
    func comments(on ref: FileRef) throws -> [Comment] { try index.comments(on: ref) }
    func files() -> [FileRef] { (try? index.indexedFiles()) ?? VaultScanner.files(in: index.vault) }
}

/// Turns a question into index queries: its content words, each clause split on "and", and the
/// longest single words stemmed so the index's trailing-prefix match catches "price" from
/// "pricing". The raw question goes in only when it has no content words: the index falls back
/// to matching any term, and "what", "did" and "I" match everything.
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
        let all = terms(question)
        guard !all.isEmpty else {
            add(question, 1)
            return out
        }
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
        "files", "vault", "anything", "something", "thing", "things", "find",
        // Verbs that carry the question, not the topic.
        "go", "goes", "going", "gone", "need", "needs", "needed", "want", "wants", "make", "makes", "made",
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
        var focus: String? = nil
    }

    let source: PassageSource
    var sectionLimit = 20
    var searchLimit = 120
    var maxSectionsPerFile = 3
    var maxSectionChars = 1800
    var maxCommentChars = 1200

    private(set) var nextID: Int
    private var seen = Set<String>()
    /// Section texts already handed out, by `SourcePrior.duplicateKey`.
    private var packedTexts = Set<String>()
    private var sectionCache: [FileRef: [SourceSection]] = [:]
    private var commentCache: [FileRef: [Comment]] = [:]
    private lazy var allFiles: [FileRef] = source.files()

    init(source: PassageSource, firstID: Int = 1) { self.source = source; self.nextID = firstID }

    /// Passages another retriever already gave this question, so they aren't repeated.
    func skip(_ passages: [Passage]) {
        for p in passages {
            if let id = p.commentID { seen.insert("c:\(id.uuidString)") } else { packedTexts.insert(SourcePrior.duplicateKey(p.text)) }
        }
    }

    /// Searches the index for `question`'s reformulations and packs, within `budgetTokens`:
    /// comments that match, then sections by rank (with the files those comments link to), then
    /// comments that sit on the matching places. Throws only if every index query failed.
    func retrieve(_ question: String, budgetTokens: Int = 12_000) throws -> [Passage] {
        let terms = QueryPlan.terms(question)
        let queries = QueryPlan.queries(for: question)

        // Each kind fused across the reformulations by rank, deduped by place or comment id.
        var sectionRank = Fusion<SearchHit>()
        var commentRank = Fusion<CommentHit>()
        var failure: Error?
        var failures = 0
        for q in queries {
            do {
                let found = try source.searchSections(q.text, limit: searchLimit)
                // A thought found by meaning arrives among the sections. It stays a thought: it
                // joins the comment fusion, never the section list.
                sectionRank.add(found.filter { $0.commentID == nil }, weight: q.weight) { Self.key($0.file, $0.anchor) }
                commentRank.add(found.compactMap(thoughtHit), weight: q.weight) { "c:\($0.comment.id.uuidString)" }
                commentRank.add(try source.searchComments(q.text, limit: 50), weight: q.weight) { "c:\($0.comment.id.uuidString)" }
            } catch {
                failure = error
                failures += 1
            }
        }
        if failures == queries.count, let failure { throw failure }

        // Weighted toward the user's own documents and away from duplicates, generated text
        // and any one file taking every slot.
        var perFile: [FileRef: Int] = [:]
        var texts = Set<String>()
        let topHits = Array(sectionRank.ranked
            .map { ($0.item, $0.score * SourcePrior.weight($0.item.file.relativePath) * SourcePrior.quality(Self.plain($0.item.snippet))) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
            .filter { hit in
                guard perFile[hit.file, default: 0] < maxSectionsPerFile,
                      texts.insert(SourcePrior.duplicateKey(Self.plain(hit.snippet))).inserted else { return false }
                perFile[hit.file, default: 0] += 1
                return true
            }
            .prefix(sectionLimit))
        let hitFiles = Set(topHits.map(\.file))
        let hitPlaces = Set(topHits.map { Self.key($0.file, $0.anchor) })

        // Matching comments, weighted by how much of the question they cover (the index falls
        // back to any term), and nudged up when they sit on or link to a matching place. Each
        // nudge is about a quarter of a first-place rank.
        let direct: [CommentHit] = commentRank.ranked.map { hit, score -> (CommentHit, Double) in
            let coverage = terms.isEmpty ? 1 : Double(Self.matchCount(terms, in: hit.comment.text)) / Double(terms.count)
            var s = score * (0.4 + 0.6 * coverage)
            if hitFiles.contains(hit.file) { s += 0.004 }
            if hit.comment.anchor != nil, hitPlaces.contains(Self.key(hit.file, hit.comment.anchor)) { s += 0.004 }
            if hit.comment.links.contains(where: {
                Wikilink.resolve($0, in: source.vault, candidates: Array(hitFiles)) != nil
            }) { s += 0.004 }
            return (hit, s)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
        let directIDs = Set(direct.map(\.comment.id))

        // Comments on the best places that didn't match the words themselves.
        var context: [(file: FileRef, comment: Comment)] = []
        for hit in topHits.prefix(8) {
            for c in cachedComments(on: hit.file) where !directIDs.contains(c.id) && c.anchor == hit.anchor {
                if !context.contains(where: { $0.comment.id == c.id }) { context.append((hit.file, c)) }
            }
        }

        // Sections: direct hits by rank, with the files the top comments link to slotted in after
        // the first few, since those links are how the user connected things.
        var sections: [Candidate] = topHits.compactMap { hit in
            let c = sectionText(for: hit) ?? Candidate(file: hit.file, anchor: hit.anchor, title: nil, text: Self.plain(hit.snippet))
            return Self.hasContent(c) ? c : nil
        }
        let linked = linkedSections(from: direct.prefix(8).map(\.comment), terms: terms,
                                    excluding: Set(sections.map { Self.key($0.file, $0.anchor) }))
        sections.insert(contentsOf: linked, at: min(3, sections.count))

        // Pack.
        var out: [Passage] = []
        var used = 0
        let commentBudget = sections.isEmpty ? budgetTokens : budgetTokens * 45 / 100
        func add(_ p: Passage, key: String, within budget: Int) {
            guard !seen.contains(key) else { return }
            let cost = Self.tokens(p)
            guard used + cost <= budget else { return }
            out.append(Passage(id: nextID, kind: p.kind, file: p.file, anchor: p.anchor, title: p.title,
                               text: p.text, timestamp: p.timestamp, provenance: p.provenance, commentID: p.commentID))
            used += cost; nextID += 1; seen.insert(key)
        }
        func comment(_ file: FileRef, _ c: Comment) -> Passage {
            // A reply says what it answers, so it reads on its own.
            let parent = parentLine(of: c, on: file).map { "re: " + $0 + "\n" } ?? ""
            return Passage(id: 0, kind: .comment, file: file, anchor: c.anchor,
                           text: parent + Self.excerpt(c.text, terms: terms, max: maxCommentChars), timestamp: c.timestamp,
                           provenance: c.provenance, commentID: c.id)
        }
        for hit in direct.prefix(40) {
            add(comment(hit.file, hit.comment), key: "c:\(hit.comment.id.uuidString)", within: commentBudget)
        }
        for s in sections {
            let text = Self.excerpt(s.text, terms: terms, max: maxSectionChars, focus: s.focus)
            guard !text.isEmpty, !packedTexts.contains(SourcePrior.duplicateKey(text)) else { continue }
            let before = out.count
            add(Passage(id: 0, kind: .section, file: s.file, anchor: s.anchor, title: s.title, text: text),
                key: Self.key(s.file, s.anchor) + "|" + text, within: budgetTokens)
            if out.count > before { packedTexts.insert(SourcePrior.duplicateKey(text)) }
        }
        for (file, c) in context.prefix(20) {
            add(comment(file, c), key: "c:\(c.id.uuidString)", within: budgetTokens)
        }
        return out
    }

    // MARK: Ranking

    /// Reciprocal-rank fusion. Rank rather than the index's raw score, so the result doesn't
    /// depend on how bm25 is scaled.
    struct Fusion<Item> {
        private var entries: [String: (item: Item, score: Double, order: Int)] = [:]

        mutating func add(_ items: [Item], weight: Double, key: (Item) -> String) {
            for (rank, item) in items.enumerated() {
                let k = key(item)
                let score = weight / Double(60 + rank + 1)
                if let e = entries[k] { entries[k] = (e.item, e.score + score, e.order) }
                else { entries[k] = (item, score, entries.count) }
            }
        }

        var ranked: [(item: Item, score: Double)] {
            entries.values
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
                .map { ($0.item, $0.score) }
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
                    if taken.insert(Self.key(file, nil)).inserted {
                        out.append(Candidate(file: file, anchor: nil, title: nil, text: text))
                    }
                    continue
                }
                guard let s = pick ?? sections.first(where: { Self.hasContent(Candidate(file: file, anchor: $0.anchor, title: $0.title, text: $0.text)) })
                else { continue }
                if taken.insert(Self.key(file, s.anchor)).inserted {
                    out.append(Candidate(file: file, anchor: s.anchor, title: s.title, text: s.text))
                }
            }
        }
        return out
    }

    // MARK: Thoughts

    /// The thought a section-search hit stands for, when it is one (found by meaning).
    private func thoughtHit(_ hit: SearchHit) -> CommentHit? {
        guard let id = hit.commentID,
              let comment = cachedComments(on: hit.file).first(where: { $0.id == id }) else { return nil }
        return CommentHit(file: hit.file, comment: comment, snippet: Self.plain(hit.snippet), score: hit.score)
    }

    /// The first line of the thought `c` answers, if it is a reply.
    private func parentLine(of c: Comment, on file: FileRef) -> String? {
        guard let parent = c.meta?.parent,
              let root = cachedComments(on: file).first(where: { $0.meta?.uid == parent }) else { return nil }
        let line = root.text.split(separator: "\n", omittingEmptySubsequences: true).first { !$0.hasPrefix(">") } ?? Substring(root.text)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(120))
    }

    // MARK: Text

    private func cachedComments(on file: FileRef) -> [Comment] {
        if let c = commentCache[file] { return c }
        let c = (try? source.comments(on: file)) ?? []
        commentCache[file] = c
        return c
    }

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
                ?? (a.kind == .line ? sections.filter {
                    $0.anchor.kind == .line && (Int($0.anchor.value) ?? Int.max) <= (Int(a.value) ?? 0)
                }.max { (Int($0.anchor.value) ?? 0) < (Int($1.anchor.value) ?? 0) } : nil)
            return s.map { Candidate(file: hit.file, anchor: a, title: $0.title, text: $0.text, focus: Self.plain(hit.snippet)) }
        }
        if let text = try? source.text(of: hit.file), !text.isEmpty {
            return Candidate(file: hit.file, anchor: nil, title: nil, text: text, focus: Self.plain(hit.snippet))
        }
        return nil
    }

    /// More than the file's own name: an image nobody has OCR'd yet matches on its name alone.
    static func hasContent(_ c: Candidate) -> Bool {
        let text = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = (c.file.relativePath as NSString).deletingLastPathComponent
        let stem = (c.file.name as NSString).deletingPathExtension
        // A file known only by name ("name · folder"), or a 3D node that is only its own name.
        if text == c.file.name || text == stem || text == c.file.name + " · " + folder || text == stem + " · " + folder { return false }
        if let title = c.title, text == title { return false }
        return text.count >= 12 || c.anchor == nil
    }

    static func key(_ file: FileRef, _ anchor: FileAnchor?) -> String {
        "s:\(file.relativePath)|\(anchor?.rendered ?? "")"
    }

    static func plain(_ snippet: String) -> String {
        snippet.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "")
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
    static func excerpt(_ text: String, terms: [String], max: Int, focus: String? = nil) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > max else { return t }
        var first: String.Index?
        for term in terms {
            if let r = t.range(of: QueryPlan.stem(term), options: [.caseInsensitive, .diacriticInsensitive]),
               first.map({ r.lowerBound < $0 }) ?? true { first = r.lowerBound }
        }
        if let focus, focus.count > 10, let range = t.range(of: focus) { first = range.lowerBound }
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
