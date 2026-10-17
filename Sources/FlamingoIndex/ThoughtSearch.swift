import Foundation
import FlamingoCore

/// One thought as the index knows it: the thought itself, what is known about it besides its
/// text (kind, state, due date), and its place in a thread.
public struct ThoughtRecord: Sendable, Equatable, Identifiable {
    public var id: String { comment.id.uuidString }
    /// The file, or the note's own ref for a thought in the inbox, on a web page or on a folder.
    public var file: FileRef
    public var comment: Comment
    public var uid: String?
    /// The uid of the thought this one answers.
    public var parent: String?
    /// The person's or a model's decision, else what `ThoughtRules` read from the words.
    public var kind: ThoughtKind
    public var kindBy: ThoughtDecider
    public var state: ThoughtState
    public var due: Date?
    public var snoozeUntil: Date?
    /// `intent.action` when a model understood the thought.
    public var action: String?
    public var origin: CommentProvenance.Origin
    /// When the file was last changed; nil for a thought with no file behind it.
    public var fileModified: Date?
    /// Direct replies in the thread.
    public var replies: Int
    public var lastHumanReplyAt: Date?

    public var hasFile: Bool { fileModified != nil }
}

/// A thought that matched a search, with why and how well.
public struct ThoughtHit: Sendable, Equatable, Identifiable {
    public var id: String { record.id }
    public var record: ThoughtRecord
    /// The matching words (marked «…» when a keyword matched), on one line.
    public var snippet: String
    public var score: Double
    /// How clearly it matches by meaning (0…1 and beyond), nil when only the words matched.
    public var relevance: Double?
    /// The first line of the thought this one answers.
    public var parentLine: String?
}

/// Triage queries: open thoughts, what is due, what is waiting for a reply.
public struct ThoughtQuery: Sendable, Equatable {
    public enum Order: Sendable, Equatable { case newest, oldest, due }
    /// `nil` for any state.
    public var states: Set<ThoughtState>? = [.open]
    /// Also include snoozed thoughts whose snooze ended by this date.
    public var snoozeEndedBy: Date?
    public var kinds: Set<ThoughtKind>?
    public var origin: CommentProvenance.Origin?
    /// Everything inside a folder.
    public var folder: String?
    public var file: FileRef?
    public var uid: String?
    public var parent: String?
    /// `false` for thread roots only, `true` for replies only.
    public var isReply: Bool?
    public var dueBefore: Date?
    public var dueAfter: Date?
    public var requiresDue = false
    public var createdBefore: Date?
    public var createdAfter: Date?
    public var includeVirtual = true
    public var order: Order = .newest
    public var limit = 200

    public init() {}
    public init(states: Set<ThoughtState>? = [.open], kinds: Set<ThoughtKind>? = nil, order: Order = .newest, limit: Int = 200) {
        self.states = states; self.kinds = kinds; self.order = order; self.limit = limit
    }
}

extension IndexStore {
    // MARK: - Triage

    static let thoughtColumns = """
        c.path, c.id, c.ts, c.anchor_kind, c.anchor_value, c.text, c.provenance, c.meta,
        c.uid, c.parent, c.kind, c.kind_by, c.state, c.due, c.snooze_until, c.origin, c.action, f.mtime,
        (SELECT count(*) FROM comments r WHERE c.uid IS NOT NULL AND r.path = c.path AND r.parent = c.uid),
        (SELECT max(r.ts) FROM comments r WHERE c.uid IS NOT NULL AND r.path = c.path AND r.parent = c.uid AND r.origin = 'human')
        """

    static func thoughtRecord(_ r: Row) -> ThoughtRecord {
        func date(_ i: Int32) -> Date? { r.isNull(i) ? nil : Date(timeIntervalSince1970: r.double(i)) }
        return ThoughtRecord(
            file: FileRef(relativePath: r.string(0)), comment: comment(r, 1, provenanceColumn: 6, metaColumn: 7),
            uid: r.optionalString(8), parent: r.optionalString(9),
            kind: r.optionalString(10).flatMap(ThoughtKind.init(rawValue:)) ?? .idea,
            kindBy: r.optionalString(11).flatMap(ThoughtDecider.init(rawValue:)) ?? .rules,
            state: ThoughtState(rawValue: r.string(12)) ?? .open, due: date(13), snoozeUntil: date(14),
            action: r.optionalString(16), origin: CommentProvenance.Origin(rawValue: r.string(15)) ?? .human,
            fileModified: date(17), replies: r.int(18), lastHumanReplyAt: date(19))
    }

    /// Thoughts matching a triage query, from SQL over the `comments_triage` index.
    public func thoughts(_ q: ThoughtQuery) throws -> [ThoughtRecord] {
        guard q.limit > 0 else { return [] }
        var clauses: [String] = [], values: [(any SQLBindable)?] = []
        func add(_ clause: String, _ value: (any SQLBindable)? = nil, bind: Bool = true) {
            clauses.append(clause)
            if bind { values.append(value) }
        }
        if let states = q.states {
            let list = states.map { "'\($0.rawValue)'" }.sorted().joined(separator: ",")
            if let ended = q.snoozeEndedBy {
                add("(c.state IN (\(list)) OR (c.state = 'snoozed' AND c.snooze_until <= ?))", ended.timeIntervalSince1970)
            } else {
                add("c.state IN (\(list))", bind: false)
            }
        }
        if let kinds = q.kinds { add("c.kind IN (\(kinds.map { "'\($0.rawValue)'" }.sorted().joined(separator: ",")))", bind: false) }
        if let origin = q.origin { add("c.origin = ?", origin.rawValue) }
        if let file = q.file { add("c.path = ?", file.relativePath) }
        if let uid = q.uid { add("c.uid = ?", uid) }
        if let parent = q.parent { add("c.parent = ?", parent) }
        if let isReply = q.isReply { add(isReply ? "c.parent IS NOT NULL" : "c.parent IS NULL", bind: false) }
        if let before = q.dueBefore { add("c.due IS NOT NULL AND c.due < ?", before.timeIntervalSince1970) }
        if let after = q.dueAfter { add("c.due IS NOT NULL AND c.due >= ?", after.timeIntervalSince1970) }
        if q.requiresDue { add("c.due IS NOT NULL", bind: false) }
        if let before = q.createdBefore { add("c.ts < ?", before.timeIntervalSince1970) }
        if let after = q.createdAfter { add("c.ts >= ?", after.timeIntervalSince1970) }
        if !q.includeVirtual { add("f.path IS NOT NULL", bind: false) }
        let scope = Self.folderPredicate(q.folder, column: "c.path")
        let order: String
        switch q.order {
        case .newest: order = "c.ts DESC, c.rowid DESC"
        case .oldest: order = "c.ts, c.rowid"
        case .due: order = "c.due IS NULL, c.due, c.ts DESC, c.rowid DESC"
        }
        values.append(q.limit)
        let sql = """
            SELECT \(Self.thoughtColumns) FROM comments c LEFT JOIN files f ON f.path = c.path
            WHERE \((clauses + ["1 = 1"]).joined(separator: " AND ")) \(scope) ORDER BY \(order) LIMIT ?\(values.count)
            """
        return try read { db in try db.prepare(sql).query(values, row: Self.thoughtRecord) }
    }

    /// The thought with uid `rootUID` and every reply under it, oldest first.
    public func thread(rootUID: String, in ref: FileRef) throws -> [ThoughtRecord] {
        let all = try read { db in
            try db.query("SELECT \(Self.thoughtColumns) FROM comments c LEFT JOIN files f ON f.path = c.path WHERE c.path = ? ORDER BY c.ts, c.rowid",
                         ref.relativePath, row: Self.thoughtRecord)
        }
        var family: Set<String> = [rootUID]
        var members: [ThoughtRecord] = []
        var changed = true
        while changed {
            changed = false
            for r in all where !members.contains(where: { $0.id == r.id }) {
                if let uid = r.uid, uid == rootUID || (r.parent.map(family.contains) ?? false) {
                    members.append(r)
                    if family.insert(uid).inserted { changed = true }
                    changed = true
                }
            }
        }
        return all.filter { r in members.contains { $0.id == r.id } }
    }

    // MARK: - Search

    /// Thoughts that match, best first: keyword hits and thoughts nearest by meaning, fused by
    /// reciprocal rank. Finds thoughts with no file behind them (inbox, web pages, folders) like any other.
    public func searchThoughts(_ query: String, inFolder folder: String? = nil, limit: Int = 20, includeSemantic: Bool = true,
                               wait: TimeInterval? = nil, shouldCancel: @Sendable () -> Bool = { false }) throws -> [ThoughtHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, limit > 0 else { return [] }
        let (keywordHits, strength) = try rankedComments(q, inFolder: folder, limit: max(limit * 2, 20))
        let keyword = keywordHits.map { hit in
            (hit: SearchHit(file: hit.file, anchor: hit.comment.anchor, snippet: hit.snippet, score: hit.score, commentID: hit.comment.id), key: hit.comment.id.uuidString)
        }
        var semantic: [(hit: SearchHit, key: String, relevance: Double)] = []
        if includeSemantic, !shouldCancel() {
            semantic = semanticSections(q, limit: 50, folder: folder, commentsOnly: true, wait: wait ?? Self.directEmbedWait, shouldCancel: shouldCancel)
                .compactMap { hit in hit.commentID.map { (semanticHit(hit, query: q), $0.uuidString, hit.relevance) } }
        }
        let fused = semantic.isEmpty
            ? Array(keyword.map(\.hit).prefix(limit))
            : Self.hybrid(keyword: keyword, strength: strength, query: q, semantic: semantic, limit: limit)
        let ids = fused.compactMap(\.commentID)
        let records = Dictionary(try thoughtRecords(ids: ids).map { ($0.comment.id, $0) }, uniquingKeysWith: { a, _ in a })
        let relevance = Dictionary(semantic.map { ($0.key, $0.relevance) }, uniquingKeysWith: max)
        let parents = try parentLines(for: Array(records.values))
        return fused.compactMap { hit in
            guard let id = hit.commentID, let record = records[id] else { return nil }
            return ThoughtHit(record: record, snippet: hit.snippet, score: hit.score, relevance: relevance[id.uuidString],
                              parentLine: record.parent.flatMap { parents[record.file.relativePath + "\u{1}" + $0] })
        }
    }

    /// Earlier thoughts that mean about what `draft` says, for "you thought this before" while
    /// typing. Meaning only (a draft has too few words to match on); nothing below `minRelevance`.
    /// Waits at most `wait` seconds for the draft's embedding, so it never holds up typing.
    public func similarThoughts(to draft: String, excludingUID: String? = nil, limit: Int = 3, minRelevance: Double = 0.45,
                                wait: TimeInterval = 0.3) -> [ThoughtHit] {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, limit > 0 else { return [] }
        let found = semanticSections(q, limit: limit * 4 + 8, commentsOnly: true, wait: wait).filter { $0.relevance >= minRelevance }
        guard !found.isEmpty, let records = try? thoughtRecords(ids: found.compactMap(\.commentID)) else { return [] }
        let byID = Dictionary(records.map { ($0.comment.id, $0) }, uniquingKeysWith: { a, _ in a })
        let parents = (try? parentLines(for: records)) ?? [:]
        var out: [ThoughtHit] = []
        for hit in found {
            guard let id = hit.commentID, let record = byID[id], record.origin == .human,
                  excludingUID == nil || record.uid != excludingUID else { continue }
            out.append(ThoughtHit(record: record, snippet: Self.clean(hit.text), score: hit.relevance, relevance: hit.relevance,
                                  parentLine: record.parent.flatMap { parents[record.file.relativePath + "\u{1}" + $0] }))
            if out.count == limit { break }
        }
        return out
    }

    func thoughtRecords(ids: [UUID]) throws -> [ThoughtRecord] {
        guard !ids.isEmpty else { return [] }
        return try read { db in
            try db.query("""
                SELECT \(Self.thoughtColumns) FROM comments c LEFT JOIN files f ON f.path = c.path
                WHERE c.id IN (SELECT value FROM json_each(?))
                """, Self.json(ids.map(\.uuidString)), row: Self.thoughtRecord)
        }
    }

    /// `path \u{1} uid` → the first line of that thought, for each reply in `records`.
    func parentLines(for records: [ThoughtRecord]) throws -> [String: String] {
        let wanted = Dictionary(grouping: records.compactMap { r in r.parent.map { (r.file.relativePath, $0) } }, by: { $0.0 })
        guard !wanted.isEmpty else { return [:] }
        var out: [String: String] = [:]
        try read { db in
            for (path, pairs) in wanted {
                _ = try db.query("SELECT uid, text FROM comments WHERE path = ?1 AND uid IN (SELECT value FROM json_each(?2))",
                                 path, Self.json(Array(Set(pairs.map(\.1))))) {
                    out[path + "\u{1}" + $0.string(0)] = Self.firstLine($0.string(1))
                }
            }
        }
        return out
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first { !$0.hasPrefix(">") }.map(String.init) ?? text
        return String(line.prefix(120))
    }

    // MARK: - Resurfacing and degree

    /// A thought from a while ago that bears on `files` (the ones open now), or nil when none does.
    /// It is on one of them, links to one, or is on a file close in meaning to one; open thoughts
    /// a person wrote themselves (not replies), not in `seen` (derived ids or uids). The best match wins, the
    /// oldest first among equals, so the same files bring back the same thought.
    public func resurfaceableThought(near files: [FileRef], olderThan age: TimeInterval = 3 * 86_400, now: Date = Date(),
                                     seen: Set<String> = []) throws -> (FileRef, Comment)? {
        let anchors = Array(files.prefix(4))
        guard !anchors.isEmpty else { return nil }
        let cutoff = now.timeIntervalSince1970 - age
        let candidates = try read { db in
            try db.query("""
                SELECT \(Self.thoughtColumns) FROM comments c LEFT JOIN files f ON f.path = c.path
                WHERE c.state = 'open' AND c.origin = 'human' AND c.parent IS NULL AND c.ts < ? ORDER BY c.ts
                """, cutoff, row: Self.thoughtRecord)
        }.filter { r in !seen.contains(r.comment.id.uuidString) && (r.uid.map { !seen.contains($0) } ?? true) }
        guard !candidates.isEmpty else { return nil }

        var closeness: [String: Double] = [:]
        for file in anchors {
            for similar in (try? similarFiles(to: file, limit: 8)) ?? [] { closeness[similar.file.relativePath] = max(closeness[similar.file.relativePath] ?? 0, similar.score) }
        }
        let resolver = LinkResolver(paths: try indexedPaths(), aliases: (try? PathAliases(vault: vault).all()) ?? [:])
        let open = Set(anchors.map(\.relativePath))
        func score(_ r: ThoughtRecord) -> Double {
            var s = 0.0
            if open.contains(r.file.relativePath) { s += 3 }
            if r.comment.text.contains("[["),
               Wikilink.parse(r.comment.text).contains(where: { target in resolver.resolve(target, from: r.file.relativePath).map(open.contains) ?? false }) { s += 2 }
            s += closeness[r.file.relativePath] ?? 0
            return s
        }
        var best: (record: ThoughtRecord, score: Double)?
        for record in candidates {
            let s = score(record)
            guard s >= 1 else { continue }
            if let current = best, s < current.score || (s == current.score && record.comment.timestamp >= current.record.comment.timestamp) { continue }
            best = (record, s)
        }
        return best.map { ($0.record.file, $0.record.comment) }
    }

    /// For each path, how many other files it is joined to by thoughts: files its thoughts link
    /// to and files whose thoughts link to it. A cheap stand-in for centrality, from SQL alone.
    public func thoughtDegree(of paths: [String]) throws -> [String: Int] {
        guard !paths.isEmpty else { return [:] }
        let rows = try read { db in
            try db.query("SELECT path, text FROM comments WHERE instr(text, '[[') > 0") { ($0.string(0), $0.string(1)) }
        }
        let resolver = LinkResolver(paths: try indexedPaths(), aliases: (try? PathAliases(vault: vault).all()) ?? [:])
        var neighbors: [String: Set<String>] = [:]
        for (source, text) in rows {
            for target in Wikilink.parse(text) {
                guard let dest = resolver.resolve(target, from: source), dest != source else { continue }
                neighbors[source, default: []].insert(dest)
                neighbors[dest, default: []].insert(source)
            }
        }
        return Dictionary(paths.map { ($0, neighbors[$0]?.count ?? 0) }, uniquingKeysWith: { a, _ in a })
    }
}
