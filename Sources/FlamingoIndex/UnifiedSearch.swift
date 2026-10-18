import Foundation
import Darwin
import FlamingoCore

/// The deliberately small, visible query language shared by quick open and vault search.
/// Dates use the current calendar/time zone; `after` includes that day, `before` excludes it.
public struct UnifiedSearchQuery: Sendable, Equatable {
    public let raw: String
    public private(set) var text: String
    public private(set) var folder: String?
    public private(set) var extensions: Set<String> = []
    public private(set) var after: Date?
    public private(set) var before: Date?
    public private(set) var directoriesOnly = false
    public private(set) var summary: [String] = []
    public private(set) var issues: [String] = []
    public let now: Date

    /// `key:value` and `key:"quoted value"` filters, compiled once.
    private static let filterPattern = try! NSRegularExpression(pattern: #"(?i)(?<!\S)(path|type|ext|after|before):(?:"([^"]*)"|(\S*))"#)

    public init(raw: String, now: Date = Date()) {
        self.raw = raw
        self.text = raw
        self.now = now
        let regex = Self.filterPattern
        let source = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: source.length)).filter {
            source.substring(to: $0.range.location).filter { $0 == "\"" }.count.isMultiple(of: 2)
        }
        for match in matches {
            let key = source.substring(with: match.range(at: 1)).lowercased()
            let range = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
            let value = source.substring(with: range)
            switch key {
            case "path":
                let normalized = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if value.hasPrefix("/") || normalized.split(separator: "/").contains("..") || normalized == ".flamingo" || normalized.hasPrefix(".flamingo/") {
                    issues.append("Path must be a folder inside this workspace")
                } else {
                    folder = normalized.isEmpty ? nil : normalized
                    if !normalized.isEmpty { summary.append("Folder: \(normalized)") }
                }
            case "type", "ext":
                let names = value.lowercased().split(separator: ",").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
                if names.isEmpty { issues.append("Missing \(key) filter") }
                for name in names {
                    if key == "type", ["folder", "folders", "directory", "directories"].contains(name) { directoriesOnly = true; continue }
                    if key == "type", let mapped = Self.types[name] { extensions.formUnion(mapped) }
                    else if !name.isEmpty, name.count <= 20, name.allSatisfy({ $0.isLetter || $0.isNumber }) { extensions.insert(name) }
                    else { issues.append("Invalid \(key): \(name)") }
                }
            default:
                guard let date = Self.date(value) else { issues.append("Invalid \(key) date: \(value). Use YYYY-MM-DD"); continue }
                if key == "after" { after = date } else { before = date }
            }
        }
        for match in matches.reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            text.replaceSubrange(range, with: " ")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        parseNaturalDates()
        // Only a leading, standalone kind is interpreted. The remainder stays ordinary text.
        if let first = text.split(whereSeparator: \.isWhitespace).first {
            let name = first.lowercased()
            if let mapped = Self.types[name], extensions.isEmpty {
                extensions = mapped
                text = String(text.dropFirst(first.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if ["folders", "directories"].contains(name) {
                directoriesOnly = true
                text = String(text.dropFirst(first.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if directoriesOnly { summary.append("Folders") }
        if !extensions.isEmpty { summary.append("Type: " + extensions.sorted().joined(separator: ", ")) }
        if let after { summary.append("Modified on or after " + Self.dateLabel(after)) }
        if let before { summary.append("Modified before " + Self.dateLabel(before)) }
        if let after, let before, after >= before { issues.append("After date must precede before date") }
        if directoriesOnly, !extensions.isEmpty { issues.append("Folder and file-type filters cannot be combined") }
    }

    private static let types: [String: Set<String>] = [
        "pdf": ["pdf"], "pdfs": ["pdf"],
        "presentation": ["ppt", "pptx", "key"], "presentations": ["ppt", "pptx", "key"], "decks": ["ppt", "pptx", "key"],
        "spreadsheet": ["xls", "xlsx", "xlsm", "csv", "tsv", "numbers"], "spreadsheets": ["xls", "xlsx", "xlsm", "csv", "tsv", "numbers"],
        "document": ["doc", "docx", "odt", "rtf", "rtfd", "pages"], "documents": ["doc", "docx", "odt", "rtf", "rtfd", "pages"],
        "image": ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "webp", "svg"], "images": ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "webp", "svg"],
        "video": ["mov", "mp4", "m4v", "mkv", "avi"], "videos": ["mov", "mp4", "m4v", "mkv", "avi"],
        "audio": ["mp3", "wav", "aif", "aiff", "m4a", "flac"], "notes": ["md", "txt", "markdown"]
    ]

    private mutating func parseNaturalDates() {
        guard after == nil, before == nil else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let phrases = ["last 7 days", "last week", "this week", "last month", "this month", "yesterday", "today"]
        for phrase in phrases {
            let pattern = #"(?i)(?<!\w)(?:(?:from|modified|in|during)\s+)?"# + phrase + #"(?!\w)"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range, in: text),
                  text[..<range.lowerBound].filter({ $0 == "\"" }).count.isMultiple(of: 2) else { continue }
            switch phrase {
            case "last 7 days": after = calendar.date(byAdding: .day, value: -7, to: now)
            case "today": after = today; before = calendar.date(byAdding: .day, value: 1, to: today)
            case "yesterday": after = calendar.date(byAdding: .day, value: -1, to: today); before = today
            case "last week", "this week":
                if let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start {
                    after = phrase == "last week" ? calendar.date(byAdding: .day, value: -7, to: start) : start
                    before = phrase == "last week" ? start : calendar.date(byAdding: .day, value: 7, to: start)
                }
            default:
                if let start = calendar.dateInterval(of: .month, for: now)?.start {
                    after = phrase == "last month" ? calendar.date(byAdding: .month, value: -1, to: start) : start
                    before = phrase == "last month" ? start : calendar.date(byAdding: .month, value: 1, to: start)
                }
            }
            text.removeSubrange(range)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
    }

    private static func date(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let result = formatter.date(from: value), formatter.string(from: result) == value else { return nil }
        return result
    }

    private static func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

public struct UnifiedSearchResult: Identifiable, Sendable, Equatable {
    public var id: String { (isDirectory ? "folder:" : "file:") + file.relativePath }
    public var file: FileRef
    public var isDirectory: Bool
    /// Exact source locations and comment identities; name-only results have no hits.
    public var hits: [SearchHit]
    public var score: Double
    public var modified: Date?
    /// Nil for full extraction; otherwise a short, factual coverage explanation.
    public var coverage: String?

    public init(file: FileRef, isDirectory: Bool = false, hits: [SearchHit] = [], score: Double = 0, modified: Date? = nil, coverage: String? = nil) {
        self.file = file; self.isDirectory = isDirectory; self.hits = hits; self.score = score; self.modified = modified; self.coverage = coverage
    }
}

public struct UnifiedSearchResponse: Sendable, Equatable {
    public var results: [UnifiedSearchResult]
    public var isTruncated: Bool
    public var notice: String?
    /// Thoughts that match, as rows of their own: those on a file (also reachable through `results`)
    /// and those with no file behind them (inbox, web pages, folders), which `results` never lists.
    /// Empty when the query filters by type, date or folders only.
    public var thoughts: [ThoughtHit] = []
    public init(results: [UnifiedSearchResult], isTruncated: Bool = false, notice: String? = nil) {
        self.results = results; self.isTruncated = isTruncated; self.notice = notice
    }
    public init(results: [UnifiedSearchResult], isTruncated: Bool = false, notice: String? = nil, thoughts: [ThoughtHit]) {
        self.results = results; self.isTruncated = isTruncated; self.notice = notice; self.thoughts = thoughts
    }
}

extension IndexStore {
    /// Searches existing names, content, thoughts and folders without moving or tagging files.
    /// The default path never waits on an embedding. Call again with `includeSemantic`
    /// from a separate background task to enrich already-visible lexical results: files found
    /// by meaning join them, each with the passage that matched. With `prefetchSemantic` (on
    /// in the app) the lexical call starts loading vectors and the query's embedding in the
    /// background, so the semantic call that follows is fast.
    public func unifiedSearch(_ query: UnifiedSearchQuery, recentPaths: [String] = [], preferredFolder: String? = nil,
                              limit: Int = 100, includeSemantic: Bool = false, directoryPaths: [String] = [], catalogFiles: [FileRef] = [],
                              shouldCancel: @Sendable () -> Bool = { false }) throws -> UnifiedSearchResponse {
        if shouldCancel() { throw CancellationError() }
        // Background embedding leaves the model free while someone is typing.
        SemanticRuntime.shared.noteInteractive()
        try refreshReadOnlyCaches()
        guard query.issues.isEmpty else { return UnifiedSearchResponse(results: [], notice: query.issues.joined(separator: "; ")) }
        guard limit > 0 else { return UnifiedSearchResponse(results: []) }
        let limit = min(limit, 1_000)
        let candidateLimit = max(200, min(2_000, limit * 4))
        let predicate = Self.unifiedPredicate(query)
        let recent = Array(recentPaths.prefix(200))
        var candidates: [String: UnifiedSearchResult] = [:]
        var truncated = false
        let tokens = FTSQuery.terms(query.text).map(\.text)
        let fuzzy = Array(Self.unifiedFold(tokens.joined()).filter { !$0.isWhitespace })
        if !includeSemantic, Self.prefetchSemantic, !query.text.isEmpty, !query.directoriesOnly { warmSemanticSearch(query: query.text) }

        if !query.directoriesOnly {
            let rows: [UnifiedSearchResult]
            if fuzzy.isEmpty {
                rows = try read { db in
                    let newest = try db.query("SELECT f.path, f.mtime, f.extraction_state, f.extraction_reason FROM files f WHERE \(predicate) ORDER BY f.mtime DESC, f.path LIMIT ?", candidateLimit + 1) { Self.unifiedMetadata($0) }
                    let used: [UnifiedSearchResult]
                    if recent.isEmpty { used = [] }
                    else { used = try db.query("SELECT f.path, f.mtime, f.extraction_state, f.extraction_reason FROM files f WHERE \(predicate) AND f.path IN (SELECT value FROM json_each(?))", Self.json(recent)) { Self.unifiedMetadata($0) } }
                    var seen = Set<String>()
                    return (used + newest).filter { seen.insert($0.file.relativePath).inserted }
                }
            } else {
                rows = try read { db in
                    // LIKE is only the cheap candidate sieve; FuzzyMatch does final ranking.
                    // Filters are in this query, before either the candidate or result cap.
                    let pattern = fuzzy.isEmpty ? "%" : "%" + fuzzy.map { Self.unifiedLike(String($0)) }.joined(separator: "%") + "%"
                    let literal = "%" + Self.unifiedLike(query.text.lowercased()) + "%"
                    return try db.query("""
                        SELECT f.path, f.mtime, f.extraction_state, f.extraction_reason FROM files f
                        WHERE \(predicate) AND lower(f.path) LIKE ?1 ESCAPE '\\'
                        ORDER BY CASE WHEN f.path IN (SELECT value FROM json_each(?2)) THEN 0 ELSE 1 END,
                            CASE WHEN lower(f.path) LIKE ?3 ESCAPE '\\' THEN 0 ELSE 1 END, f.mtime DESC, f.path LIMIT ?4
                        """, pattern, Self.json(recent), literal, candidateLimit + 1) { Self.unifiedMetadata($0) }
                }
            }
            truncated = rows.count > candidateLimit
            for var result in rows.prefix(fuzzy.isEmpty ? rows.count : candidateLimit) {
                if fuzzy.isEmpty { result.score = 10 }
                else if let value = FuzzyMatch.score(fuzzy, path: Self.unifiedFold(result.file.relativePath)) {
                    result.score = Self.unifiedNameScore(result.file.name, tokens: tokens, fuzzy: value)
                } else { continue }
                candidates[result.file.relativePath] = result
            }

            var seen = Set<String>()
            var hasFTS = false
            var lexical = Set<String>(), partialOnly = Set<String>()
            for (index, strategy) in Self.plan(query.text).enumerated() {
                if shouldCancel() { throw CancellationError() }
                if case .fts = strategy, hasFTS { continue }
                let batch = try unifiedHits(strategy, predicate: predicate, limit: candidateLimit + 1)
                let hits = batch.hits
                truncated = truncated || batch.truncated
                if case .fts = strategy, !hits.isEmpty { hasFTS = true }
                // When not every word matched, a hit is weaker evidence than a meaning match.
                var partial = false
                if case .fts = strategy, index > 0 { partial = true }
                for (rank, hit) in hits.enumerated() where seen.insert(hit.id).inserted {
                    if candidates[hit.file.relativePath] == nil { candidates[hit.file.relativePath] = UnifiedSearchResult(file: hit.file) }
                    candidates[hit.file.relativePath]?.hits.append(hit)
                    lexical.insert(hit.file.relativePath)
                    if partial { partialOnly.insert(hit.file.relativePath) } else { partialOnly.remove(hit.file.relativePath) }
                    let score = (hit.commentID == nil ? 70.0 : 74.0) - (partial ? Self.partialMatchPenalty : 0) + 8 / (1 + Double(rank))
                    let previousScore = candidates[hit.file.relativePath]?.score ?? 0
                    candidates[hit.file.relativePath]?.score = max(previousScore, score)
                }
            }
            if includeSemantic, !query.text.isEmpty {
                // A thought with no file (inbox, web page, folder) is no file result; it comes back in `thoughts`.
                let found = semanticSections(query.text, limit: candidateLimit + 1, folder: query.folder, filePredicate: predicate,
                                             wait: Self.interactiveEmbedWait, shouldCancel: shouldCancel).filter { !$0.isGhost }
                // Each file's best hit first (scored), then its other passages (shown).
                let best = Self.bestPerFile(found)
                let scored = Set(best.map(\.section))
                let hits = best + found.filter { !scored.contains($0.section) && !$0.isCard }
                var boosted = Set<String>()
                for (rank, hit) in hits.enumerated() {
                    if rank >= candidateLimit { truncated = true; continue }
                    let source = semanticHit(hit, query: query.text)
                    let path = hit.path
                    if candidates[path] == nil { candidates[path] = UnifiedSearchResult(file: source.file) }
                    // The passage explains the match; skip it when keyword search already
                    // returned that exact location.
                    if seen.insert(source.id).inserted { candidates[path]?.hits.append(source) }
                    // Hits are best first: only a file's best passage scores.
                    guard boosted.insert(path).inserted else { continue }
                    let r = min(1, max(0, hit.relevance))
                    let previousScore = candidates[path]?.score ?? 0
                    let meaning = Self.semanticBase + Self.semanticRange * r
                    if lexical.contains(path), !partialOnly.contains(path) {
                        // Every word matched: meaning reorders keyword hits, never replaces them.
                        candidates[path]?.score = previousScore + Self.semanticAgreementBoost * r
                    } else if lexical.contains(path) {
                        // Only some words matched: the stronger of the two, plus a little for agreeing.
                        candidates[path]?.score = max(previousScore, meaning) + Self.partialAgreementBoost * r
                    } else {
                        candidates[path]?.score = max(previousScore, meaning)
                    }
                }
            }
            // The scanner's catalog is available before extraction. Keep these files
            // searchable immediately, without loading bytes, indexing or organizing them.
            if !catalogFiles.isEmpty {
                let asciiQuery = Array(String(fuzzy).utf8)
                let isASCII = asciiQuery.allSatisfy { $0 < 128 }
                let literal = tokens.joined(separator: " ").lowercased()
                var buckets = [[FileRef](), [FileRef](), [FileRef]()]
                var dates: [String: Date] = [:]
                var dateInspections = 0
                let recentSet = Set(recent)
                for (offset, file) in catalogFiles.enumerated() {
                    if offset.isMultiple(of: 512), shouldCancel() { throw CancellationError() }
                    if fuzzy.isEmpty, query.folder == nil, query.extensions.isEmpty, query.after == nil, query.before == nil, offset >= candidateLimit * 5 {
                        truncated = true; break
                    }
                    let path = file.relativePath
                    if let scope = query.folder, !path.hasPrefix(scope + "/") { continue }
                    if !query.extensions.isEmpty {
                        guard let dot = path.lastIndex(of: "."), query.extensions.contains(String(path[path.index(after: dot)...]).lowercased()) else { continue }
                    }
                    if !fuzzy.isEmpty {
                        if isASCII { guard Self.unifiedSubsequence(asciiQuery, in: path) else { continue } }
                        else { guard path.localizedCaseInsensitiveContains(tokens.first ?? query.text) else { continue } }
                    }
                    if candidates[path] != nil { continue }
                    guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.hasPrefix(".flamingo/") else { continue }
                    var modified: Date?
                    if query.after != nil || query.before != nil {
                        // Date-filtered fallback inspects metadata only, with an explicit
                        // scan budget; accepted candidates are filtered before any result cap.
                        if dateInspections >= candidateLimit * 10 { truncated = true; break }
                        dateInspections += 1
                        modified = (try? vault.url(for: file).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                        guard let modified, query.after.map({ modified >= $0 }) ?? true, query.before.map({ modified < $0 }) ?? true else { continue }
                    }
                    let name = path.lastIndex(of: "/").map { String(path[path.index(after: $0)...]) } ?? path
                    let priority = recentSet.contains(path) || (!literal.isEmpty && name.lowercased().contains(literal)) ? 0 : (fuzzy.isEmpty || path.lowercased().contains(literal) ? 1 : 2)
                    if buckets[priority].count < candidateLimit { buckets[priority].append(file); dates[path] = modified }
                    else { truncated = true }
                    if fuzzy.isEmpty, query.after == nil, query.before == nil, buckets[1].count >= candidateLimit, recentSet.isEmpty { break }
                }
                for file in buckets.flatMap({ $0 }) {
                    let score: Double
                    if fuzzy.isEmpty { score = 10 }
                    else if let value = FuzzyMatch.score(fuzzy, path: Self.unifiedFold(file.relativePath)) {
                        score = Self.unifiedNameScore(file.name, tokens: tokens, fuzzy: value)
                    } else { continue }
                    candidates[file.relativePath] = UnifiedSearchResult(file: file, score: score, modified: dates[file.relativePath], coverage: "Content not indexed yet")
                }
            }
            // Read metadata only for surviving candidates; content can find files with no
            // filename overlap. This never reads source bytes or downloads cloud placeholders.
            if !candidates.isEmpty {
                let metadata = try read { db in
                    try db.query("SELECT path, mtime, extraction_state, extraction_reason FROM files WHERE path IN (SELECT value FROM json_each(?))", Self.json(Array(candidates.keys))) { Self.unifiedMetadata($0) }
                }
                for value in metadata {
                    candidates[value.file.relativePath]?.modified = value.modified
                    candidates[value.file.relativePath]?.coverage = value.coverage
                }
            }
        }

        if query.extensions.isEmpty, !fuzzy.isEmpty || query.directoriesOnly {
            // The home vault can contain hundreds of thousands of folders. The cheap
            // byte sieve visits that cached catalog; only bounded candidates pay for
            // Unicode folding and full fuzzy alignment. Blank search favors recent files.
            let directories = try indexedDirectories(shouldCancel: shouldCancel) + directoryPaths
            let asciiQuery = Array(String(fuzzy).utf8)
            let isASCII = asciiQuery.allSatisfy { $0 < 128 }
            let literal = query.text.lowercased()
            var buckets = [[String](), [String](), [String]()]
            var directoryDates: [String: Date] = [:]
            for (offset, path) in directories.enumerated() {
                if offset.isMultiple(of: 512), shouldCancel() { throw CancellationError() }
                if fuzzy.isEmpty, buckets[0].count >= candidateLimit { truncated = true; break }
                if let scope = query.folder, path != scope, !path.hasPrefix(scope + "/") { continue }
                if !fuzzy.isEmpty {
                    if isASCII { guard Self.unifiedSubsequence(asciiQuery, in: path) else { continue } }
                    else { guard path.localizedCaseInsensitiveContains(tokens.first ?? query.text) else { continue } }
                }
                guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), path != ".flamingo", !path.hasPrefix(".flamingo/") else { continue }
                var modified: Date?
                if query.after != nil || query.before != nil {
                    modified = (try? vault.url(for: FileRef(relativePath: path)).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    guard let modified, query.after.map({ modified >= $0 }) ?? true, query.before.map({ modified < $0 }) ?? true else { continue }
                }
                let name = path.lastIndex(of: "/").map { String(path[path.index(after: $0)...]) } ?? path
                let priority = fuzzy.isEmpty || name.lowercased().contains(literal) ? 0 : (path.lowercased().contains(literal) ? 1 : 2)
                if buckets[priority].count < candidateLimit { buckets[priority].append(path); directoryDates[path] = modified }
                else { truncated = true }
            }
            for path in buckets.flatMap({ $0 }) {
                let score: Double
                if fuzzy.isEmpty { score = 5 }
                else if let value = FuzzyMatch.score(fuzzy, path: Self.unifiedFold(path)) { score = 45 + min(35, Double(value) / 10) }
                else { continue }
                candidates["folder:" + path] = UnifiedSearchResult(file: FileRef(relativePath: path), isDirectory: true, score: score, modified: directoryDates[path])
            }
        }
        if shouldCancel() { throw CancellationError() }
        let recentRanks = Dictionary(recent.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        var results = candidates.values.map { value -> UnifiedSearchResult in
            var value = value
            if let rank = recentRanks[value.file.relativePath] { value.score += 12 / (1 + Double(rank) / 4) }
            if let folder = preferredFolder, !folder.isEmpty, value.file.relativePath.hasPrefix(folder + "/") { value.score += 3 }
            if let modified = value.modified { value.score += 2 / (1 + max(0, query.now.timeIntervalSince(modified)) / 604_800) }
            // An anchored match is always more useful than a title-only hit for opening.
            value.hits.sort {
                if ($0.anchor != nil) != ($1.anchor != nil) { return $0.anchor != nil }
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.id < $1.id
            }
            value.hits = Array(value.hits.prefix(6))
            return value
        }
        results.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.modified != $1.modified { return ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            return $0.file.relativePath < $1.file.relativePath
        }
        truncated = truncated || results.count > limit
        var thoughts: [ThoughtHit] = []
        if !query.text.isEmpty, !query.directoriesOnly, query.extensions.isEmpty, query.after == nil, query.before == nil {
            thoughts = (try? searchThoughts(query.text, inFolder: query.folder, limit: 6, includeSemantic: includeSemantic,
                                            wait: Self.interactiveEmbedWait, shouldCancel: shouldCancel)) ?? []
        }
        return UnifiedSearchResponse(results: Array(results.prefix(limit)), isTruncated: truncated,
                                     notice: truncated ? "More matches available; narrow the query or add a filter" : nil, thoughts: thoughts)
    }

    /// Scores (see `unifiedSearch`): content hits matching every word 70–78, thoughts 74–82,
    /// exact names 110, names containing the query 85, other fuzzy names 38–68. A file found
    /// only by meaning scores 48–72 by how clearly its best passage answers the query, so a
    /// clear answer can pass weaker keyword hits but never an exact name or a top keyword
    /// match. Meaning that agrees with a full keyword hit adds up to 8.
    static let semanticBase = 48.0
    static let semanticRange = 24.0
    static let semanticAgreementBoost = 8.0
    static let partialAgreementBoost = 3.0
    /// Content hits from the any-term fallback (not every word matched): 52–60, thoughts
    /// 56–64. For a question like "what did Maya say about flicker" these are mostly noise.
    static let partialMatchPenalty = 18.0

    /// A single validated predicate is reused by every retrieval source before ranking.
    private static func unifiedPredicate(_ query: UnifiedSearchQuery) -> String {
        var predicate = "1 = 1" + folderPredicate(query.folder, column: "f.path")
        if !query.extensions.isEmpty { predicate += " AND f.ext IN (" + query.extensions.sorted().map(unifiedLiteral).joined(separator: ",") + ")" }
        if let after = query.after { predicate += " AND f.mtime >= \(after.timeIntervalSince1970)" }
        if let before = query.before { predicate += " AND f.mtime < \(before.timeIntervalSince1970)" }
        return predicate
    }

    private static func unifiedMetadata(_ row: Row) -> UnifiedSearchResult {
        let state = row.string(2), reason = row.optionalString(3)
        let coverage: String?
        switch state {
        case "complete": coverage = nil
        case "partial": coverage = "Partial content" + (reason.map { ": " + $0 } ?? "")
        default: coverage = "Filename only" + (reason.map { ": " + $0 } ?? "")
        }
        return UnifiedSearchResult(file: FileRef(relativePath: row.string(0)), modified: Date(timeIntervalSince1970: row.double(1)), coverage: coverage)
    }

    private static func unifiedSubsequence(_ query: [UInt8], in path: String) -> Bool {
        guard !query.isEmpty else { return true }
        // C's byte search avoids a Swift iterator call per byte on a home-size catalog,
        // including in development builds. Final ranking still uses Unicode-aware text.
        return path.withCString { start in
            var cursor = start
            for byte in query {
                let lower = strchr(cursor, Int32(byte))
                let upper = byte >= 97 && byte <= 122 ? strchr(cursor, Int32(byte - 32)) : nil
                let match: UnsafeMutablePointer<CChar>?
                if let lower, let upper { match = UInt(bitPattern: lower) < UInt(bitPattern: upper) ? lower : upper }
                else { match = lower ?? upper }
                guard let match else { return false }
                cursor = UnsafePointer(match.advanced(by: 1))
            }
            return true
        }
    }

    private static func unifiedLiteral(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
    /// Exact names 110, names containing the query 85, other fuzzy names 38–68. Separators
    /// don't count: "q3 board review" is the exact name of `q3-board-review.pptx`, and the
    /// name without its extension is as exact as the whole name.
    static func unifiedNameScore(_ fileName: String, tokens: [String], fuzzy value: Int) -> Double {
        func words(_ s: String) -> String { unifiedFold(s).split { !$0.isLetter && !$0.isNumber }.joined(separator: " ") }
        let needle = words(tokens.joined(separator: " "))
        guard !needle.isEmpty else { return 38 + min(30, Double(value) / 10) }
        let name = words(fileName), stem = words((fileName as NSString).deletingPathExtension)
        if name == needle || stem == needle { return 110 }
        if name.contains(needle) { return 85 }
        return 38 + min(30, Double(value) / 10)
    }

    private static func unifiedFold(_ value: String) -> String { value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    private static func unifiedLike(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") }

    private func unifiedHits(_ match: Match, predicate: String, limit: Int) throws -> (hits: [SearchHit], truncated: Bool) {
        switch match {
        case .fts(let q):
            return try read(snapshot: true) { db in
                // Group before LIMIT so a long document cannot crowd out other files.
                let best = try db.query("""
                    SELECT s.path, min(sections_fts.rank), sections_fts.rowid, s.ord
                    FROM sections_fts JOIN sections s ON s.rowid = sections_fts.rowid JOIN files f ON f.path = s.path
                    WHERE sections_fts MATCH ?1 AND \(predicate) GROUP BY s.path ORDER BY 2, s.path LIMIT ?2
                    """, q, limit) { (path: $0.string(0), score: -$0.double(1), rowid: $0.int(2), ord: $0.int(3)) }
                var picked = Dictionary(best.map { ($0.path, $0.rowid) }, uniquingKeysWith: { a, _ in a })
                let titleOnly = best.filter { $0.ord == 0 }.map(\.path)
                if !titleOnly.isEmpty {
                    let anchored = try db.query("""
                        SELECT s.path, min(sections_fts.rank), sections_fts.rowid
                        FROM sections_fts JOIN sections s ON s.rowid = sections_fts.rowid
                        WHERE sections_fts MATCH ?1 AND s.ord > 0 AND s.path IN (SELECT value FROM json_each(?2)) GROUP BY s.path
                        """, q, Self.json(titleOnly)) { ($0.string(0), $0.int(2)) }
                    for (path, rowid) in anchored { picked[path] = rowid }
                }
                let scores = Dictionary(best.map { ($0.path, $0.score) }, uniquingKeysWith: max)
                let content = try db.query("""
                    WITH m AS MATERIALIZED (
                        SELECT rowid, snippet(sections_fts, 0, '«', '»', '…', 10) AS st,
                            snippet(sections_fts, 1, '«', '»', '…', 20) AS sx
                        FROM sections_fts WHERE sections_fts MATCH ?1 AND +rowid IN (SELECT value FROM json_each(?2))
                    )
                    SELECT s.path, s.anchor_kind, s.anchor_value, m.st, m.sx, s.text FROM m JOIN sections s ON s.rowid = m.rowid
                    """, q, Self.json(Array(picked.values))) { row in
                    SearchHit(file: FileRef(relativePath: row.string(0)), anchor: Self.matchAnchor(Self.anchor(row, 1), text: row.string(5), snippet: row.string(4), path: row.string(0)),
                              snippet: Self.snippet(title: row.string(3), text: row.string(4)), score: scores[row.string(0)] ?? 0)
                }
                let commentRows = try db.query("""
                    SELECT c.path, min(comments_fts.rank), comments_fts.rowid
                    FROM comments_fts JOIN comments c ON c.rowid = comments_fts.rowid JOIN files f ON f.path = c.path
                    WHERE comments_fts MATCH ?1 AND \(predicate) GROUP BY c.path ORDER BY 2, c.path LIMIT ?2
                    """, q, limit) { $0.int(2) }
                let comments = try db.query("""
                    SELECT c.path, c.anchor_kind, c.anchor_value, c.id, m.snip, m.rank FROM (
                        SELECT rowid, snippet(comments_fts, 0, '«', '»', '…', 20) AS snip, rank
                        FROM comments_fts WHERE comments_fts MATCH ?1 AND +rowid IN (SELECT value FROM json_each(?2))
                    ) m JOIN comments c ON c.rowid = m.rowid
                    """, q, Self.json(commentRows)) {
                    SearchHit(file: FileRef(relativePath: $0.string(0)), anchor: Self.anchor($0, 1), snippet: Self.clean($0.string(4)), score: -$0.double(5) * Self.commentBoost, commentID: UUID(uuidString: $0.string(3)))
                }
                return ((content + comments).sorted { $0.score > $1.score }, content.count >= limit || comments.count >= limit)
            }
        case .substring(let terms):
            guard !terms.isEmpty else { return ([], false) }
            return try read { db in
                let sectionTest = terms.map { "(instr(lower(s.text), lower(\(Self.unifiedLiteral($0)))) > 0 OR instr(lower(coalesce(s.title, '')), lower(\(Self.unifiedLiteral($0)))) > 0)" }.joined(separator: " AND ")
                let content = try db.query("""
                    SELECT path, anchor_kind, anchor_value, title, text FROM (
                        SELECT s.*, row_number() OVER (PARTITION BY s.path ORDER BY CASE WHEN s.ord = 0 THEN 1 ELSE 0 END, s.ord) AS picked
                        FROM sections s JOIN files f ON f.path = s.path WHERE \(predicate) AND \(sectionTest)
                    ) WHERE picked = 1 ORDER BY path LIMIT ?
                    """, limit) { row -> SearchHit in
                    let body = terms.contains(where: { row.string(4).range(of: $0, options: .caseInsensitive) != nil }) ? row.string(4) : row.string(3)
                    let snippet = Self.substringSnippet(body, terms)
                    return SearchHit(file: FileRef(relativePath: row.string(0)), anchor: Self.matchAnchor(Self.anchor(row, 1), text: row.string(4), snippet: snippet, path: row.string(0)), snippet: snippet, score: 1)
                }
                let commentTest = terms.map { "instr(lower(c.text), lower(\(Self.unifiedLiteral($0)))) > 0" }.joined(separator: " AND ")
                let comments = try db.query("""
                    SELECT path, anchor_kind, anchor_value, id, text FROM (
                        SELECT c.*, row_number() OVER (PARTITION BY c.path ORDER BY c.ts DESC, c.rowid) AS picked
                        FROM comments c JOIN files f ON f.path = c.path WHERE \(predicate) AND \(commentTest)
                    ) WHERE picked = 1 ORDER BY ts DESC LIMIT ?
                    """, limit) {
                    SearchHit(file: FileRef(relativePath: $0.string(0)), anchor: Self.anchor($0, 1), snippet: Self.substringSnippet($0.string(4), terms), score: Self.commentBoost, commentID: UUID(uuidString: $0.string(3)))
                }
                return (content + comments, content.count >= limit || comments.count >= limit)
            }
        }
    }
}
