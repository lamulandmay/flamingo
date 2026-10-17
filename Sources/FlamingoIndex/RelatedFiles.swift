import Foundation
import FlamingoCore

/// The evidence for a connection, kept separate from the destination it opens.
public struct RelatedFileReason: Hashable, Sendable {
    public enum Kind: String, Sendable { case documentLink, thoughtLink, manual, documentBacklink, thoughtBacklink }
    public let kind: Kind
    public let connectionLabel: String?

    public var label: String {
        switch kind {
        case .documentLink: return "Linked in this document"
        case .thoughtLink: return "Linked in a thought"
        case .manual: return connectionLabel.map { "Connected · \($0)" } ?? "Manually connected"
        case .documentBacklink: return "Links to this file"
        case .thoughtBacklink: return "Thought links to this file"
        }
    }
}

/// One navigable destination. Different anchors remain distinct; duplicate links to the
/// same destination merge their reasons instead of filling the rail with identical rows.
public struct RelatedFile: Identifiable, Equatable, Sendable {
    public let file: FileRef
    public let anchor: FileAnchor?
    public var reasons: [RelatedFileReason]
    public var excerpt: String
    public var id: String { file.relativePath + "\u{1F}" + (anchor?.rendered ?? "") }
}

public struct RelatedFilesSnapshot: Equatable, Sendable {
    public var related: [RelatedFile] = []
    public var backlinks: [RelatedFile] = []
    public var truncated = false
    public init() {}
}

extension IndexStore {
    /// Evidence already in the index and connection store. No extraction, embedding, or
    /// graph rebuild. Call off the main thread; cancellation is checked between sources.
    public func relatedFiles(to ref: FileRef, connections: [ManualConnection] = [], limit: Int = 100,
                             checkCancellation: () throws -> Void = {}) throws -> RelatedFilesSnapshot {
        let limit = min(500, max(0, limit))
        guard limit > 0 else { return RelatedFilesSnapshot() }
        try requireVault()
        try checkCancellation()
        let aliases = try PathAliases(vault: vault).all()
        // Only basename competitors can change how a link to this file resolves. Include
        // those, every outgoing target, and alias spellings/destinations. This preserves
        // the shared resolver's tie-breaking without building eight dictionary tiers
        // over hundreds of thousands of unrelated home-directory files on every click.
        var candidateNames = Set<String>()
        func includeNames(_ path: String) {
            let normalized = path.replacingOccurrences(of: "\\", with: "/")
            let name = (normalized as NSString).lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
            candidateNames.insert(name)
            candidateNames.insert((name as NSString).deletingPathExtension)
        }
        includeNames(ref.relativePath)
        for (old, new) in aliases { includeNames(old); includeNames(new) }
        try read { db in
            for sql in [
                "SELECT text FROM comments WHERE path = ? AND instr(text, '[[') > 0",
                "SELECT s.text FROM sections s JOIN files f ON f.path = s.path WHERE s.path = ? AND f.ext IN ('md', 'markdown', 'mdown', 'mkd', 'mdx') AND instr(s.text, '[[') > 0"
            ] {
                _ = try db.query(sql, ref.relativePath) { row in
                    try checkCancellation()
                    for link in Wikilink.links(in: row.string(0)) { includeNames(link.target.replacingOccurrences(of: "\\", with: "/")) }
                }
            }
        }
        // A name → paths index built once per path list, so a click costs a few lookups
        // rather than a pass over every file in a home folder.
        try checkCancellation()
        let candidates = NameIndex.shared.paths(named: candidateNames, in: try indexedPaths(), store: self)
        let resolver = LinkResolver(paths: candidates, aliases: aliases)
        var related: [String: RelatedFile] = [:], backlinks: [String: RelatedFile] = [:]
        var truncated = false
        var existing: [String: Bool] = [:]
        var headingAnchors: [String: [String: FileAnchor]] = [:]

        func destinationAnchor(_ link: Wikilink.Link, path: String, db: Database) throws -> FileAnchor? {
            if let anchor = link.fileAnchor { return anchor }
            guard let heading = link.anchor, !heading.hasPrefix("^") else { return nil }
            if headingAnchors[path] == nil {
                var anchors: [String: FileAnchor] = [:]
                _ = try db.query("SELECT title, anchor_kind, anchor_value FROM sections WHERE path = ? AND ord > 0 ORDER BY ord", path) { row in
                    if let title = row.optionalString(0), let anchor = Self.anchor(row, 1), anchors[title.lowercased()] == nil {
                        anchors[title.lowercased()] = anchor
                    }
                }
                headingAnchors[path] = anchors
            }
            return headingAnchors[path]?[heading.lowercased()]
        }

        func exists(_ path: String) -> Bool {
            if let value = existing[path] { return value }
            let value = vault.exists(FileRef(relativePath: path))
            existing[path] = value
            return value
        }
        func append(_ path: String, anchor: FileAnchor?, reason: RelatedFileReason, excerpt: String, backlink: Bool) {
            guard path != ref.relativePath else { return }
            let entry = RelatedFile(file: FileRef(relativePath: path), anchor: anchor, reasons: [reason], excerpt: excerpt)
            var prior = backlink ? backlinks[entry.id] : related[entry.id]
            if prior != nil {
                if !prior!.reasons.contains(reason) { prior!.reasons.append(reason) }
                if prior!.excerpt.isEmpty { prior!.excerpt = excerpt }
                if backlink { backlinks[entry.id] = prior } else { related[entry.id] = prior }
            } else if related.count + backlinks.count < limit {
                // Only stat actual result candidates, never every file in the vault.
                guard exists(path) else { return }
                if backlink { backlinks[entry.id] = entry } else { related[entry.id] = entry }
            } else {
                truncated = true
            }
        }

        for connection in connections {
            try checkCancellation()
            // Stored endpoints are full paths. Never let a missing manual endpoint fall
            // back to another file that merely happens to share its basename.
            let other: String?
            if connection.source == ref.relativePath { other = connection.target }
            else if connection.target == ref.relativePath { other = connection.source }
            else { other = nil }
            guard let other else { continue }
            let label = connection.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            append(other, anchor: nil, reason: RelatedFileReason(kind: .manual, connectionLabel: label?.isEmpty == false ? label : nil),
                   excerpt: "", backlink: false)
        }

        func ingest(path: String, anchor: FileAnchor?, text: String, isThought: Bool, db: Database) throws {
            try checkCancellation()
            var priorIndex = text.startIndex
            var sourceLine = anchor.flatMap { $0.kind == .line ? Int($0.value) : nil } ?? 1
            for link in Wikilink.links(in: text) {
                try checkCancellation()
                sourceLine += text[priorIndex..<link.range.lowerBound].reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
                priorIndex = link.range.lowerBound
                guard let target = resolver.resolve(link.target, from: path) else { continue }
                if path == ref.relativePath {
                    append(target, anchor: try destinationAnchor(link, path: target, db: db),
                           reason: RelatedFileReason(kind: isThought ? .thoughtLink : .documentLink, connectionLabel: nil),
                           excerpt: Self.relatedExcerpt(text, around: link.range), backlink: false)
                } else if target == ref.relativePath {
                    // A backlink opens where the evidence was written, never at the
                    // anchor intended for the currently selected destination file.
                    let sourceAnchor = isThought || (anchor != nil && anchor?.kind != .line)
                        ? anchor : FileAnchor(kind: .line, value: String(sourceLine))
                    append(path, anchor: sourceAnchor,
                           reason: RelatedFileReason(kind: isThought ? .thoughtBacklink : .documentBacklink, connectionLabel: nil),
                           excerpt: Self.relatedExcerpt(text, around: link.range), backlink: true)
                }
            }
        }

        try read(snapshot: true) { db in
            // Deliberate outbound links take priority over backlinks when the bound fills.
            for comparison in ["=", "!="] {
                _ = try db.query("""
                    SELECT path, anchor_kind, anchor_value, text FROM comments
                    WHERE path \(comparison) ? AND instr(text, '[[') > 0 ORDER BY ts DESC, rowid DESC
                    """, ref.relativePath) { row in
                    try ingest(path: row.string(0), anchor: Self.anchor(row, 1), text: row.string(3), isThought: true, db: db)
                }
                // CROSS JOIN fixes the loop order: filter cheap file metadata first,
                // then read text only from Markdown sections. An ordinary JOIN may
                // scan the entire multi-GB sections table before checking extension.
                _ = try db.query("""
                    SELECT s.path, s.anchor_kind, s.anchor_value, s.text FROM files f
                    CROSS JOIN sections s ON s.path = f.path
                    WHERE f.path \(comparison) ? AND f.ext IN ('md', 'markdown', 'mdown', 'mkd', 'mdx') AND instr(s.text, '[[') > 0
                    AND (s.ord > 0 OR NOT EXISTS (SELECT 1 FROM sections other WHERE other.path = s.path AND other.ord > 0))
                    ORDER BY s.path, s.ord
                    """, ref.relativePath) { row in
                    try ingest(path: row.string(0), anchor: Self.anchor(row, 1), text: row.string(3), isThought: false, db: db)
                }
            }
        }
        try checkCancellation()
        func ordered(_ values: Dictionary<String, RelatedFile>.Values) -> [RelatedFile] {
            values.sorted {
                if $0.file != $1.file { return $0.file < $1.file }
                return ($0.anchor?.label ?? "").localizedStandardCompare($1.anchor?.label ?? "") == .orderedAscending
            }
        }
        var result = RelatedFilesSnapshot()
        result.related = ordered(related.values)
        result.backlinks = ordered(backlinks.values)
        result.truncated = truncated
        return result
    }

    /// A short, literal excerpt centered on the link; it cannot accidentally show an
    /// unrelated opening paragraph of a long document as evidence.
    private static func relatedExcerpt(_ text: String, around range: Range<String.Index>) -> String {
        let start = text.index(range.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 120, limitedBy: text.endIndex) ?? text.endIndex
        let body = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let capped = String(body.prefix(260))
        return (start > text.startIndex ? "…" : "") + capped + (end < text.endIndex || body.count > 260 ? "…" : "")
    }
}

/// Lowercased file names and stems → paths, for the current cached path list. Rebuilt when
/// `indexedPaths()` hands back a different array (the index changed).
final class NameIndex: @unchecked Sendable {
    static let shared = NameIndex()
    private let lock = NSLock()
    private var key: (store: ObjectIdentifier, buffer: UnsafeRawPointer?, count: Int)?
    /// Holding the array keeps its storage alive, so a new path list can never reuse the
    /// address and be mistaken for this one.
    private var source: [String] = []
    private var byName: [String: [String]] = [:]

    func paths(named names: Set<String>, in paths: [String], store: IndexStore) -> [String] {
        let buffer = paths.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
        lock.lock(); defer { lock.unlock() }
        if key?.store != ObjectIdentifier(store) || key?.buffer != buffer || key?.count != paths.count {
            var index: [String: [String]] = [:]
            index.reserveCapacity(paths.count)
            for path in paths {
                let normalized = path.replacingOccurrences(of: "\\", with: "/")
                let name = (normalized as NSString).lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
                index[name, default: []].append(path)
                let stem = (name as NSString).deletingPathExtension
                if stem != name { index[stem, default: []].append(path) }
            }
            byName = index
            source = paths
            key = (ObjectIdentifier(store), buffer, paths.count)
        }
        var seen = Set<String>(), out: [String] = []
        for name in names { for path in byName[name] ?? [] where seen.insert(path).inserted { out.append(path) } }
        return out.sorted()
    }
}
