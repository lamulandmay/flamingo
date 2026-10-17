import Foundation
import FlamingoCore

/// Why two files belong together. One file pair is one connection; each reason is evidence.
///
/// `yours` and `linked` are explicit: a person made them. The rest are suggestions Flamingo
/// noticed, which can be accepted (they become `yours`) or dismissed (hidden everywhere).
public enum ConnectionReason: String, Sendable, CaseIterable, Codable {
    /// Connected by hand in Flamingo.
    case yours
    /// A `[[wikilink]]` in a thought or a note, in either direction.
    case linked
    /// The same document: a byte-identical copy, or a likely earlier or later version.
    case version
    /// One file's text names the other.
    case mentioned
    /// The two files say similar things.
    case similar
    /// Opened in the same working sessions.
    case together

    public var isExplicit: Bool { self == .yours || self == .linked }

    /// Strongest evidence first, for ordering and for the summary of a connection.
    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// One piece of evidence. `source` and `anchor` say where it was written, so it can be opened.
public struct ConnectionEvidence: Hashable, Sendable {
    public var reason: ConnectionReason
    /// The file holding the evidence: the linking or mentioning file. Nil when the evidence
    /// is not written anywhere (a hand-made connection, a shared session, similar content).
    public var source: FileRef?
    /// Where in `source` the evidence is, or where to open the other file.
    public var anchor: FileAnchor?
    public var excerpt: String
    /// The link was written in a thought rather than in the document itself.
    public var inThought: Bool
    /// Mentions counted, sessions shared, or similarity (0–1).
    public var weight: Double
    /// The note on a hand-made connection.
    public var note: String?

    public init(reason: ConnectionReason, source: FileRef? = nil, anchor: FileAnchor? = nil, excerpt: String = "",
                inThought: Bool = false, weight: Double = 1, note: String? = nil) {
        self.reason = reason; self.source = source; self.anchor = anchor; self.excerpt = excerpt
        self.inThought = inThought; self.weight = weight; self.note = note
    }
}

/// The selected file's connection to one other file.
public struct FileConnection: Identifiable, Equatable, Sendable {
    public var file: FileRef
    /// Where to open `file`: the anchor a link points at, or where a backlink was written.
    public var anchor: FileAnchor?
    public var evidence: [ConnectionEvidence]
    /// 0–1. Evidence combines like independent signals: 1 − Π(1 − sᵢ).
    public var strength: Double
    public var id: String { file.relativePath }

    public init(file: FileRef, anchor: FileAnchor?, evidence: [ConnectionEvidence], strength: Double) {
        self.file = file; self.anchor = anchor; self.evidence = evidence; self.strength = strength
    }

    public var isExplicit: Bool { evidence.contains { $0.reason.isExplicit } }
    /// Distinct reasons, strongest first.
    public var reasons: [ConnectionReason] {
        Array(Set(evidence.map(\.reason))).sorted { $0.rank < $1.rank }
    }
    /// The evidence worth showing as the connection's one line: a written excerpt if any.
    public var headline: ConnectionEvidence? {
        evidence.sorted { ($0.reason.rank, $0.excerpt.isEmpty ? 1 : 0) < ($1.reason.rank, $1.excerpt.isEmpty ? 1 : 0) }
            .first { !$0.excerpt.isEmpty || $0.note != nil } ?? evidence.min { $0.reason.rank < $1.reason.rank }
    }
}

public struct FileConnectionsSnapshot: Equatable, Sendable {
    /// Links and hand-made connections.
    public var explicit: [FileConnection] = []
    /// Mentions, similar content and shared sessions nobody has accepted or dismissed yet.
    public var suggested: [FileConnection] = []
    public var truncated = false
    public init() {}
    public var isEmpty: Bool { explicit.isEmpty && suggested.isEmpty }
}

public enum FileConnections {
    /// Suggestions shown per file, strongest first.
    public static let suggestionLimit = 24

    /// One connection per other file, from the evidence the index already has: links and
    /// hand-made connections (`related`, with excerpts), and the discovered graph edges
    /// touching `ref` (mentions, shared sessions, similar content). Pure; no I/O.
    ///
    /// `dismissed` holds `DismissedConnection.key`s: dismissed suggestions are dropped, but a
    /// dismissal never hides a link someone wrote or a connection someone made.
    public static func merge(for ref: FileRef, related: RelatedFilesSnapshot, edges: [Graph.Edge],
                             similar: [(file: FileRef, score: Double, passage: String?)] = [],
                             mentionExcerpts: [String: (anchor: FileAnchor?, text: String)] = [:],
                             dismissed: Set<String> = []) -> FileConnectionsSnapshot {
        let me = ref.relativePath
        var byPath: [String: FileConnection] = [:]

        func add(_ other: String, _ evidence: ConnectionEvidence, anchor: FileAnchor? = nil) {
            guard other != me, !other.hasSuffix("/"), !other.isEmpty else { return }
            var entry = byPath[other] ?? FileConnection(file: FileRef(relativePath: other), anchor: nil, evidence: [], strength: 0)
            // The same link found twice (a note and its thought) is one piece of evidence.
            if !entry.evidence.contains(where: { $0.reason == evidence.reason && $0.source == evidence.source
                && $0.anchor == evidence.anchor && $0.excerpt == evidence.excerpt }) {
                entry.evidence.append(evidence)
            }
            if entry.anchor == nil { entry.anchor = anchor }
            byPath[other] = entry
        }

        for item in related.related {
            for reason in item.reasons {
                switch reason.kind {
                case .manual:
                    add(item.file.relativePath, ConnectionEvidence(reason: .yours, note: reason.connectionLabel))
                case .documentLink, .thoughtLink:
                    add(item.file.relativePath, ConnectionEvidence(reason: .linked, source: ref, anchor: nil, excerpt: item.excerpt,
                                                                   inThought: reason.kind == .thoughtLink), anchor: item.anchor)
                case .documentBacklink, .thoughtBacklink:
                    add(item.file.relativePath, ConnectionEvidence(reason: .linked, source: item.file, anchor: item.anchor, excerpt: item.excerpt,
                                                                   inThought: reason.kind == .thoughtBacklink), anchor: item.anchor)
                }
            }
        }
        for item in related.backlinks {
            for reason in item.reasons {
                let thought = reason.kind == .thoughtBacklink || reason.kind == .thoughtLink
                add(item.file.relativePath, ConnectionEvidence(reason: .linked, source: item.file, anchor: item.anchor,
                                                               excerpt: item.excerpt, inThought: thought), anchor: item.anchor)
            }
        }

        for edge in edges where edge.source == me || edge.target == me {
            let other = edge.source == me ? edge.target : edge.source
            switch edge.kind {
            case .mention:
                // `source` names `target` in its text.
                let excerpt = mentionExcerpts[edge.source + "\u{1F}" + edge.target]
                add(other, ConnectionEvidence(reason: .mentioned, source: FileRef(relativePath: edge.source), anchor: excerpt?.anchor,
                                              excerpt: excerpt?.text ?? "", weight: edge.weight),
                    anchor: edge.source == other ? excerpt?.anchor : nil)
            case .trail:
                add(other, ConnectionEvidence(reason: .together, weight: edge.weight))
            case .related:
                add(other, ConnectionEvidence(reason: .similar, weight: edge.weight))
            case .link where byPath[other]?.evidence.contains(where: { $0.reason == .linked }) != true:
                add(other, ConnectionEvidence(reason: .linked, source: FileRef(relativePath: edge.source)))
            case .manual where byPath[other]?.evidence.contains(where: { $0.reason == .yours }) != true:
                add(other, ConnectionEvidence(reason: .yours))
            default:
                break
            }
        }
        for s in similar {
            let passage = (s.passage ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            // A graph edge may already have said "similar"; the direct lookup brings the passage.
            if let i = byPath[s.file.relativePath]?.evidence.firstIndex(where: { $0.reason == .similar }) {
                if byPath[s.file.relativePath]!.evidence[i].excerpt.isEmpty { byPath[s.file.relativePath]!.evidence[i].excerpt = passage }
                byPath[s.file.relativePath]!.evidence[i].weight = max(byPath[s.file.relativePath]!.evidence[i].weight, s.score)
            } else {
                add(s.file.relativePath, ConnectionEvidence(reason: .similar, excerpt: passage, weight: s.score))
            }
        }

        var snapshot = FileConnectionsSnapshot()
        for var entry in byPath.values {
            entry.strength = strength(of: entry.evidence)
            if entry.isExplicit {
                snapshot.explicit.append(entry)
            } else if !dismissed.contains(DismissedConnection.key(me, entry.file.relativePath)) {
                snapshot.suggested.append(entry)
            }
        }
        func order(_ a: FileConnection, _ b: FileConnection) -> Bool {
            if a.strength != b.strength { return a.strength > b.strength }
            return a.file.name.localizedStandardCompare(b.file.name) == .orderedAscending
        }
        snapshot.explicit.sort(by: order)
        snapshot.suggested.sort(by: order)
        if snapshot.suggested.count > suggestionLimit {
            snapshot.suggested = Array(snapshot.suggested.prefix(suggestionLimit))
            snapshot.truncated = true
        }
        snapshot.truncated = snapshot.truncated || related.truncated
        return snapshot
    }

    /// How strongly one piece of evidence ties two files, 0–1.
    public static func strength(of evidence: ConnectionEvidence) -> Double {
        switch evidence.reason {
        case .yours: return 1
        case .linked: return 0.9
        case .mentioned: return min(0.75, 0.35 + 0.1 * evidence.weight)
        // Weight is similarity above the model's floor, 0…1 (`IndexStore.relatedness`).
        case .similar: return min(0.7, 0.15 + 0.55 * max(0, min(1, evidence.weight)))
        case .together: return min(0.6, 0.18 + 0.1 * evidence.weight)
        case .version: return evidence.weight >= 1 ? 0.95 : 0.6
        }
    }

    /// Adds copies and versions (from the file-family inspection, which runs separately
    /// because it reads files) to a snapshot already on screen. `identical` copies weigh 1.
    public static func adding(versions: [(file: FileRef, identical: Bool, note: String)], to snapshot: FileConnectionsSnapshot,
                              for ref: FileRef, dismissed: Set<String> = []) -> FileConnectionsSnapshot {
        guard !versions.isEmpty else { return snapshot }
        var out = snapshot
        for v in versions where v.file != ref {
            let evidence = ConnectionEvidence(reason: .version, excerpt: v.note, weight: v.identical ? 1 : 0.5, note: v.identical ? "Identical copy" : "Possible version")
            if let i = out.explicit.firstIndex(where: { $0.file == v.file }) {
                guard !out.explicit[i].evidence.contains(where: { $0.reason == .version }) else { continue }
                out.explicit[i].evidence.append(evidence)
                out.explicit[i].strength = strength(of: out.explicit[i].evidence)
            } else if let i = out.suggested.firstIndex(where: { $0.file == v.file }) {
                guard !out.suggested[i].evidence.contains(where: { $0.reason == .version }) else { continue }
                out.suggested[i].evidence.append(evidence)
                out.suggested[i].strength = strength(of: out.suggested[i].evidence)
            } else if !dismissed.contains(DismissedConnection.key(ref.relativePath, v.file.relativePath)) {
                out.suggested.append(FileConnection(file: v.file, anchor: nil, evidence: [evidence], strength: strength(of: [evidence])))
            }
        }
        func order(_ a: FileConnection, _ b: FileConnection) -> Bool {
            if a.strength != b.strength { return a.strength > b.strength }
            return a.file.name.localizedStandardCompare(b.file.name) == .orderedAscending
        }
        out.explicit.sort(by: order)
        out.suggested.sort(by: order)
        return out
    }

    public static func strength(of evidence: [ConnectionEvidence]) -> Double {
        1 - evidence.reduce(1) { $0 * (1 - strength(of: $1)) }
    }
}

extension IndexStore {
    /// Where `source`'s text names `target`: the first section that contains the target's
    /// name, as an anchor and a short excerpt around it. Nil when the name isn't searchable.
    public func mentionExcerpt(in source: FileRef, naming target: FileRef) throws -> (anchor: FileAnchor?, text: String)? {
        guard let phrase = Self.mentionPhrase(for: target.relativePath) else { return nil }
        return try read(snapshot: true) { db in
            try db.query("""
                SELECT s.anchor_kind, s.anchor_value, snippet(sections_fts, 1, '', '', '…', 14), s.ord FROM sections_fts f
                JOIN sections s ON s.rowid = f.rowid WHERE sections_fts MATCH ? AND s.path = ? ORDER BY s.ord DESC LIMIT 1
                """, phrase, source.relativePath) { row in
                (anchor: Self.anchor(row, 0), text: row.string(2).split(whereSeparator: \.isWhitespace).joined(separator: " "))
            }.first
        }
    }

    /// The selected file's connections. `connections`, `dismissed` and `edges` come from
    /// the shell (connection stores and the built graph); everything else is read here.
    /// Call off the main thread.
    public func fileConnections(of ref: FileRef, connections: [ManualConnection], edges: [Graph.Edge],
                                similar: [(file: FileRef, score: Double, passage: String?)] = [],
                                dismissed: Set<String>, checkCancellation: () throws -> Void = {}) throws -> FileConnectionsSnapshot {
        let related = try relatedFiles(to: ref, connections: connections, checkCancellation: checkCancellation)
        var excerpts: [String: (anchor: FileAnchor?, text: String)] = [:]
        let mine = edges.filter { $0.kind == .mention && ($0.source == ref.relativePath || $0.target == ref.relativePath) }
        // Strongest mentions first; past a dozen the rows show without an excerpt.
        for edge in mine.sorted(by: { $0.weight > $1.weight }).prefix(12) {
            try checkCancellation()
            if let found = try mentionExcerpt(in: FileRef(relativePath: edge.source), naming: FileRef(relativePath: edge.target)) {
                excerpts[edge.source + "\u{1F}" + edge.target] = found
            }
        }
        try checkCancellation()
        return FileConnections.merge(for: ref, related: related, edges: edges, similar: similar,
                                     mentionExcerpts: excerpts, dismissed: dismissed)
    }
}

extension IndexStore {
    /// How far a raw cosine sits above the current model's floor of meaningful relatedness,
    /// 0…1. Raw cosines aren't comparable across embedding models; this is.
    public func relatedness(_ cosine: Double) -> Double {
        let floor = similarityFloor()
        return max(0, min(1, (cosine - floor) / max(0.01, 1 - floor)))
    }

    /// Similar-content suggestions for the whole graph, drawn dashed like other suggestions:
    /// each file's `perFile` nearest neighbours clearly above the model's floor. Weight is
    /// `relatedness`, so `FileConnections.strength` ranks them like the inspector does.
    public func similarEdges(perFile: Int = 3) throws -> [Graph.Edge] {
        let floor = similarityFloor()
        // A third of the way from the floor to identical: related, not merely on-topic.
        let minScore = floor + (1 - floor) / 3
        return try similarPairs(minScore: minScore, perFile: perFile).map {
            Graph.Edge(source: $0.a, target: $0.b, kind: .related, weight: relatedness($0.score))
        }
    }
}
