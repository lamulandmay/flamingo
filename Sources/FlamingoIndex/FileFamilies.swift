import Foundation
import CryptoKit
import Darwin
import FlamingoCore

/// A relationship inferred from observable files, never a statement about authorship,
/// approval, submission, or which version is authoritative.
public struct ArtifactFamilyMember: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case identicalCopy, possibleVersion, relatedContent
        public var label: String {
            switch self {
            case .identicalCopy: return "Identical copy"
            case .possibleVersion: return "Possible version"
            case .relatedContent: return "Related content"
            }
        }
    }
    public let file: FileRef
    public let kind: Kind
    public let reason: String
    public let comparison: ArtifactFamilyComparison?
    public let anchor: FileAnchor?
    public var id: String { file.relativePath }
}

public struct ArtifactFamilySectionEvidence: Equatable, Sendable, Identifiable {
    public let file: FileRef
    public let anchor: FileAnchor?
    public let title: String?
    public let excerpt: String
    public var id: String { file.relativePath + "#" + (anchor?.rendered ?? "") + excerpt }
}

/// `selectedOnly` and `candidateOnly` mean text not found in the compared extraction,
/// not proof that a slide/page is absent from the source. Pagination can differ.
/// Each side contains at most three representative unmatched excerpts.
public struct ArtifactFamilyComparison: Equatable, Sendable {
    public let sharedSections: Int
    public let selectedOnly: [ArtifactFamilySectionEvidence]
    public let candidateOnly: [ArtifactFamilySectionEvidence]
    public let scope: String
    public let partial: Bool
}

public struct ArtifactFamilySnapshot: Equatable, Sendable {
    public let selected: FileRef
    public var members: [ArtifactFamilyMember] = []
    public var truncated = false
    public var notes: [String] = []
    public init(selected: FileRef) { self.selected = selected }
}

extension IndexStore {
    /// Call off the main thread. This is an on-demand, bounded inspection of indexed
    /// candidates, not a vault-wide duplicate scan. Source files are never changed.
    /// Fingerprints are streamed and cached by filesystem identity + size + nanosecond
    /// modification/change times. No source is read merely because a search key changed.
    public func fileFamily(for ref: FileRef, limit: Int = 12,
                           checkCancellation: () throws -> Void = {}) throws -> ArtifactFamilySnapshot {
        var result = ArtifactFamilySnapshot(selected: ref)
        let limit = min(40, max(0, limit))
        try checkCancellation()
        try refreshReadOnlyCaches()
        guard limit > 0 else { return result }
        try requireVault()
        guard let selected = try familyMetadata(ref), let selectedStamp = FamilyStamp.safe(vault.url(for: ref), vault: vault) else {
            result.notes = ["Family inspection is unavailable until this local file is indexed and readable."]
            return result
        }
        let selectedText = try familyText(selected, stamp: selectedStamp, checkCancellation: checkCancellation)
        let name = FamilyName(ref.stem)
        var candidatePaths = Set<String>(), candidates: [FamilyMetadata] = []
        func add(_ rows: [FamilyMetadata], bound: Int) {
            if rows.count > bound { result.truncated = true }
            for row in rows.prefix(bound) where row.file != ref && candidatePaths.insert(row.file.relativePath).inserted {
                candidates.append(row)
            }
        }
        // Equal length is necessary for byte duplicates, irrespective of name or format.
        add(try read { db in
            try db.query("SELECT \(FamilyMetadata.columns) FROM files WHERE size = ? AND path != ? ORDER BY path LIMIT ?",
                         selectedStamp.size, ref.relativePath, Self.familyCandidateLimit + 1, row: FamilyMetadata.init)
        }, bound: Self.familyCandidateLimit)
        try checkCancellation()
        if let token = name.distinctiveTokens.first {
            let escaped = token.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            add(try read { db in
                try db.query("SELECT \(FamilyMetadata.columns) FROM files WHERE path LIKE ? ESCAPE '\\' AND path != ? ORDER BY path LIMIT ?",
                             "%" + escaped + "%", ref.relativePath, Self.familyCandidateLimit + 1, row: FamilyMetadata.init)
            }, bound: Self.familyCandidateLimit)
        }
        // FTS supplies a short list across folders and names; similarity is checked from
        // extracted text below. A shared word or title alone never establishes a family.
        let contentTerms = selectedText.words.filter { $0.count >= 6 && !FamilyName.generic.contains($0) }
        let terms = Array((name.distinctiveTokens + contentTerms).uniqued().prefix(10))
        if !terms.isEmpty {
            let match = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " OR ")
            let paths = try read { db in
                try db.query("""
                    SELECT s.path, min(sections_fts.rank) FROM sections_fts JOIN sections s ON s.rowid = sections_fts.rowid
                    WHERE sections_fts MATCH ? AND s.path != ? GROUP BY s.path ORDER BY 2, s.path LIMIT ?
                    """, match, ref.relativePath, Self.familyCandidateLimit + 1) { row in
                    try checkCancellation(); return row.string(0)
                }
            }
            if paths.count > Self.familyCandidateLimit { result.truncated = true }
            for path in Array(paths.prefix(Self.familyCandidateLimit)).uniqued() where !candidatePaths.contains(path) {
                try checkCancellation()
                if let row = try familyMetadata(FileRef(relativePath: path)) { add([row], bound: 1) }
            }
        }
        // Inspect likely name variants first so a folder full of tiny unrelated files
        // cannot consume the byte budget before a useful comparison is considered.
        candidates.sort {
            let a = name.matches(FamilyName($0.file.stem)), b = name.matches(FamilyName($1.file.stem))
            return a == b ? $0.file < $1.file : a
        }
        if candidates.count > Self.familyInspectionLimit { result.truncated = true }
        var bytesRemaining = Self.familyByteBudget
        var skippedBytes = false, skippedSources = false
        var selectedDigest: String?
        var attemptedSelectedDigest = false
        for candidate in candidates.prefix(Self.familyInspectionLimit) {
            try checkCancellation()
            let url = vault.url(for: candidate.file)
            guard let stamp = FamilyStamp.safe(url, vault: vault) else { skippedSources = true; continue }
            var identical = false
            if stamp.size == selectedStamp.size {
                if !attemptedSelectedDigest {
                    selectedDigest = try FamilyFingerprints.shared.digest(vault.url(for: ref), expected: selectedStamp,
                                                                         bytesRemaining: &bytesRemaining, checkCancellation: checkCancellation)
                    attemptedSelectedDigest = true
                }
                if let selectedDigest {
                    let digest = try FamilyFingerprints.shared.digest(url, expected: stamp,
                                                                    bytesRemaining: &bytesRemaining, checkCancellation: checkCancellation)
                    identical = digest == selectedDigest
                    if digest == nil { skippedBytes = true }
                } else { skippedBytes = true }
            }
            let sameName = name.matches(FamilyName(candidate.file.stem))
            let candidateText = try familyText(candidate, stamp: stamp, checkCancellation: checkCancellation)
            let similar = selectedText.stronglyResembles(candidateText)
            guard identical || sameName || similar else { continue }
            // Recheck both sources after hashing/comparison, before making any assertion.
            guard FamilyStamp.safe(url, vault: vault) == stamp,
                  FamilyStamp.safe(vault.url(for: ref), vault: vault) == selectedStamp else {
                skippedSources = true; continue
            }
            let kind: ArtifactFamilyMember.Kind = identical ? .identicalCopy : sameName ? .possibleVersion : .relatedContent
            let reason = identical ? "SHA-256 matches every byte of the selected file."
                : sameName ? "Names match after removing version or copy suffixes; origin is unverified."
                : "Substantial indexed text overlaps; origin and version order are unverified."
            let comparison = selectedText.compare(candidateText)
            result.members.append(ArtifactFamilyMember(file: candidate.file, kind: kind, reason: reason,
                                                       comparison: comparison, anchor: comparison?.candidateOnly.first?.anchor ?? candidateText.parts.first?.anchor))
        }
        result.members.sort {
            let rank: [ArtifactFamilyMember.Kind: Int] = [.identicalCopy: 0, .possibleVersion: 1, .relatedContent: 2]
            return rank[$0.kind] == rank[$1.kind] ? $0.file < $1.file : rank[$0.kind]! < rank[$1.kind]!
        }
        if result.members.count > limit { result.truncated = true; result.members = Array(result.members.prefix(limit)) }
        if result.truncated { result.notes.append("More candidates may exist; this inspection is bounded.") }
        if skippedBytes { result.notes.append("Some byte comparisons were skipped because the file or read budget was too large, or the source became unreadable.") }
        if skippedSources { result.notes.append("Unavailable, cloud-only, symbolic-link, or changing sources were skipped.") }
        if selectedText.stale { result.notes.append("The selected file changed since indexing; text comparison will resume after the index catches up.") }
        return result
    }

    static let familyCandidateLimit = 96
    static let familyInspectionLimit = 128
    static let familyByteBudget = 128 * 1024 * 1024
    static let familyTextLimit = 80_000
    static let familySectionLimit = 120

    private func familyMetadata(_ ref: FileRef) throws -> FamilyMetadata? {
        try read { db in
            try db.query("SELECT \(FamilyMetadata.columns) FROM files WHERE path = ?", ref.relativePath, row: FamilyMetadata.init).first
        }
    }

    private func familyText(_ metadata: FamilyMetadata, stamp: FamilyStamp,
                            checkCancellation: () throws -> Void) throws -> FamilyText {
        var text = FamilyText(file: metadata.file, partial: metadata.state != "complete")
        guard metadata.size == stamp.size, abs(metadata.mtime - stamp.mtime) < 0.000_001 else { text.stale = true; return text }
        let rows = try read { db in
            try db.query("""
                SELECT anchor_kind, anchor_value, title, substr(text, 1, 6001), length(text) FROM sections
                WHERE path = ? AND (ord > 0 OR NOT EXISTS (SELECT 1 FROM sections other WHERE other.path = ? AND other.ord > 0))
                ORDER BY ord LIMIT ?
                """, metadata.file.relativePath, metadata.file.relativePath, Self.familySectionLimit + 1) { row in
                try checkCancellation()
                return (Self.anchor(row, 0), row.optionalString(2), row.string(3), row.int(4))
            }
        }
        if rows.count > Self.familySectionLimit { text.partial = true }
        var remaining = Self.familyTextLimit
        for (anchor, title, body, originalLength) in rows.prefix(Self.familySectionLimit) {
            try checkCancellation()
            let included = String(body.prefix(min(6000, remaining)))
            if included.count < originalLength { text.partial = true }
            remaining -= included.count
            if !included.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text.parts.append(ArtifactFamilySectionEvidence(file: metadata.file, anchor: anchor, title: title, excerpt: included))
            }
            if remaining <= 0 { text.partial = true; break }
        }
        return text
    }
}

private struct FamilyMetadata {
    static let columns = "path, mtime, size, extraction_state"
    let file: FileRef
    let mtime: Double
    let size: Int
    let state: String
    init(_ row: Row) { file = FileRef(relativePath: row.string(0)); mtime = row.double(1); size = row.int(2); state = row.string(3) }
}

/// Strip suffixes only, never meaningful numbers within the work's name.
struct FamilyName {
    let normalized: String
    let distinctiveTokens: [String]
    static let generic: Set<String> = ["document", "presentation", "report", "untitled", "notes", "note", "draft", "final", "copy", "version", "revised", "updated", "export", "file", "test", "image", "photo", "scan", "data", "sheet", "spreadsheet", "book", "budget", "summary", "results", "introduction", "conclusion", "the", "and", "with", "from", "this", "that"]
    init(_ stem: String) {
        var value = stem.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let suffix = #"(?:[\s_\-]+(?:v(?:ersion)?\s*\d+(?:\.\d+)*|rev(?:ision)?\s*\d+|copy(?:\s*\d+)?|final(?:\s*\d+)?|revised|updated|draft)|\s*\(\d+\))$"#
        while let range = value.range(of: suffix, options: .regularExpression) { value.removeSubrange(range) }
        normalized = Self.words(value).joined(separator: " ")
        distinctiveTokens = Self.words(value).filter {
            !Self.generic.contains($0) && ($0.count >= 3 || ($0.count >= 2 && $0.contains(where: \.isNumber)))
        }
    }
    func matches(_ other: FamilyName) -> Bool {
        guard normalized == other.normalized, !distinctiveTokens.isEmpty else { return false }
        return distinctiveTokens.contains { $0.count >= 6 }
            || (normalized.count >= 6 && (distinctiveTokens.count >= 2
                || (Self.words(normalized).count >= 2 && distinctiveTokens.contains { $0.contains(where: \.isNumber) })))
    }
    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}

private struct FamilyText {
    let file: FileRef
    var partial: Bool
    var stale = false
    var parts: [ArtifactFamilySectionEvidence] = []
    var words: [String] { parts.flatMap { FamilyName.words($0.excerpt) } }
    var normalized: String { words.joined(separator: " ") }
    func stronglyResembles(_ other: FamilyText) -> Bool {
        let a = words, b = other.words
        guard !stale, !other.stale, min(a.count, b.count) >= 24 else { return false }
        func shingles(_ words: [String]) -> Set<String> {
            Set((0..<(words.count - 4)).map { words[$0..<($0 + 5)].joined(separator: " ") })
        }
        let left = shingles(a), right = shingles(b), shared = left.intersection(right).count
        // Exact repeated boilerplate alone is insufficient; require considerable overlap
        // in both documents, even when names and formats differ.
        return shared >= 18 && Double(shared) / Double(min(left.count, right.count)) >= 0.86
            && Double(shared) / Double(max(left.count, right.count)) >= 0.60
    }
    func compare(_ other: FamilyText) -> ArtifactFamilyComparison? {
        guard !parts.isEmpty, !other.parts.isEmpty, !stale, !other.stale else { return nil }
        let left = normalized, right = other.normalized
        func found(_ part: ArtifactFamilySectionEvidence, in text: String) -> Bool {
            let phrase = FamilyName.words(part.excerpt).joined(separator: " ")
            return !phrase.isEmpty && text.contains(phrase)
        }
        func excerpt(_ part: ArtifactFamilySectionEvidence) -> ArtifactFamilySectionEvidence {
            let body = part.excerpt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return ArtifactFamilySectionEvidence(file: part.file, anchor: part.anchor, title: part.title,
                                                  excerpt: String(body.prefix(240)) + (body.count > 240 ? "…" : ""))
        }
        let incomplete = partial || other.partial
        return ArtifactFamilyComparison(sharedSections: parts.filter { found($0, in: right) }.count,
                                        selectedOnly: parts.filter { !found($0, in: right) }.prefix(3).map(excerpt),
                                        candidateOnly: other.parts.filter { !found($0, in: left) }.prefix(3).map(excerpt),
                                        scope: (incomplete ? "Compared a partial extraction. " : "Compared indexed text. ") + "Formatting, images, charts and document structure are not compared. Showing up to three unmatched excerpts per file; text not found here may still be present in the source.",
                                        partial: incomplete)
    }
}

/// Includes ctime and inode so replacing a file or preserving its mtime cannot reuse a
/// stale digest. A source is checked again through its open descriptor after reading.
struct FamilyStamp: Equatable {
    let size: Int
    let modified: Int64
    let modifiedNanos: Int64
    let changed: Int64
    let changedNanos: Int64
    let inode: UInt64
    let device: Int32
    var mtime: Double { Double(modified) + Double(modifiedNanos) / 1e9 }
    init?(_ st: stat) {
        guard (st.st_mode & S_IFMT) == S_IFREG, st.st_flags & UInt32(SF_DATALESS) == 0,
              st.st_mode & 0o444 != 0, st.st_size >= 0 else { return nil }
        size = Int(st.st_size); modified = Int64(st.st_mtimespec.tv_sec); modifiedNanos = Int64(st.st_mtimespec.tv_nsec)
        changed = Int64(st.st_ctimespec.tv_sec); changedNanos = Int64(st.st_ctimespec.tv_nsec)
        inode = UInt64(st.st_ino); device = st.st_dev
    }
    static func safe(_ url: URL, vault: Vault) -> FamilyStamp? {
        let clean = url.standardizedFileURL
        guard let relative = vault.relativePath(of: clean), !relative.isEmpty, !vault.isState(clean),
              !relative.split(separator: "/").contains("..") else { return nil }
        // Reject linked ancestors too; the final-component O_NOFOLLOW alone cannot.
        var cursor = vault.root
        for component in relative.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            var state = stat()
            guard lstat(cursor.path, &state) == 0, (state.st_mode & S_IFMT) != S_IFLNK else { return nil }
        }
        var state = stat()
        guard lstat(clean.path, &state) == 0 else { return nil }
        return FamilyStamp(state)
    }
}

private final class FamilyFingerprints: @unchecked Sendable {
    static let shared = FamilyFingerprints()
    private let lock = NSLock()
    private var cache: [String: (FamilyStamp, String)] = [:]
    func digest(_ url: URL, expected: FamilyStamp, bytesRemaining: inout Int,
                checkCancellation: () throws -> Void) throws -> String? {
        try checkCancellation()
        lock.lock(); let cached = cache[url.path]; lock.unlock()
        if cached?.0 == expected { return cached?.1 }
        guard expected.size <= Int(VaultScanner.limits.maxExtractableBytes), expected.size <= bytesRemaining else { return nil }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, FamilyStamp(before) == expected else { return nil }
        var hasher = SHA256(), total = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; return nil }
            if count == 0 { break }
            total += count; bytesRemaining -= count
            guard total <= expected.size, bytesRemaining >= 0 else { return nil }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        var after = stat()
        guard total == expected.size, fstat(fd, &after) == 0, FamilyStamp(after) == expected else { return nil }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        lock.lock()
        if cache.count >= 2048 { cache.removeAll(keepingCapacity: true) }
        cache[url.path] = (expected, digest)
        lock.unlock()
        return digest
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}
