import Foundation

/// A sidecar note held in memory, exactly as it is on disk.
///
/// `SidecarFormat.render(parseDocument(x)) == x` for any `x` that ends in a newline.
/// Frontmatter lines are kept verbatim (extra keys survive), and body lines that are
/// not comments are kept verbatim as `.raw` items in their original position, so a note
/// hand-edited in Obsidian is never flattened by Flamingo rewriting it.
///
/// Comments inside a document are always *normalized*: timestamps are truncated to the
/// minute the format can express, and ids are derived from content (see `Comment`).
public struct SidecarDocument: Equatable, Sendable {
    /// One line-group of the body.
    public enum Item: Equatable, Sendable {
        /// A comment: `- [yyyy-MM-dd HH:mm] (kind value) text` plus continuation lines.
        case comment(Comment)
        /// A body line Flamingo does not understand, preserved verbatim (without its newline).
        case raw(String)
    }

    /// Lines between the `---` fences, verbatim. `nil` when the file has no frontmatter.
    public var frontmatter: [String]? { didSet { normalize() } }

    /// The body, in order.
    public private(set) var items: [Item]

    /// `"\n"`, or `"\r\n"` for a note whose first line ended in CR. `render` uses it for
    /// every line, so a CRLF note written by another editor stays CRLF after Flamingo
    /// appends to it. Lines are stored without the terminator either way.
    public var lineTerminator: String = "\n"

    public init(frontmatter: [String]? = nil, items: [Item] = []) {
        self.frontmatter = frontmatter
        self.items = items
        normalize()
    }

    /// A fresh document with `target` and `id` frontmatter and the given comments.
    public init(target: FileRef?, id: UUID?, comments: [Comment]) {
        var lines: [String] = []
        if let target { lines.append("target: " + YAMLScalar.quoteIfNeeded(target.relativePath)) }
        if let id { lines.append("id: " + id.uuidString) }
        self.frontmatter = lines
        self.items = comments.map(Item.comment)
        normalize()
    }

    // MARK: Frontmatter

    /// The `target` key: the user file this note is about, relative to the vault.
    public var target: FileRef? {
        get { frontmatterValue(for: "target").map(FileRef.init(relativePath:)) }
        set { setFrontmatterValue(newValue?.relativePath, for: "target") }
    }

    /// The `id` key: the target's `FileIdentity`, used to follow renames.
    public var id: UUID? {
        get { frontmatterValue(for: "id").flatMap(UUID.init(uuidString:)) }
        set { setFrontmatterValue(newValue?.uuidString, for: "id") }
    }

    /// Keys present in the frontmatter, in order.
    public var frontmatterKeys: [String] {
        (frontmatter ?? []).compactMap { YAMLScalar.keyValue(of: $0)?.key }
    }

    /// The value of a frontmatter key (first occurrence), unquoted. `nil` if absent.
    public func frontmatterValue(for key: String) -> String? {
        for line in frontmatter ?? [] {
            if let kv = YAMLScalar.keyValue(of: line), kv.key == key { return kv.value }
        }
        return nil
    }

    /// Sets (or removes, when `value` is nil) a frontmatter key. An existing line keeps its
    /// position; a new `target` goes first, a new `id` right after `target`, anything else last.
    public mutating func setFrontmatterValue(_ value: String?, for key: String) {
        var lines = frontmatter ?? []
        let existing = lines.firstIndex { YAMLScalar.keyValue(of: $0)?.key == key }
        guard let value else {
            if let existing { lines.remove(at: existing) }
            frontmatter = lines.isEmpty && frontmatter == nil ? nil : lines
            return
        }
        let rendered = "\(key): " + YAMLScalar.quoteIfNeeded(value)
        if let existing {
            lines[existing] = rendered
        } else if key == "target" {
            lines.insert(rendered, at: 0)
        } else if key == "id", let t = lines.firstIndex(where: { YAMLScalar.keyValue(of: $0)?.key == "target" }) {
            lines.insert(rendered, at: t + 1)
        } else if key == "id" {
            lines.insert(rendered, at: 0)
        } else {
            lines.append(rendered)
        }
        frontmatter = lines
    }

    // MARK: Comments

    /// The comments, in document order.
    public var comments: [Comment] {
        items.compactMap { if case .comment(let c) = $0 { return c } else { return nil } }
    }

    /// True when the body has nothing at all, comments or raw lines.
    public var isEmpty: Bool { items.isEmpty }

    /// Position of a comment among `comments`, by id.
    public func index(of id: UUID) -> Int? { comments.firstIndex { $0.id == id } }

    /// Adds a comment at the end of the body.
    public mutating func append(_ comment: Comment) {
        items.append(.comment(comment))
        normalize()
    }

    /// Inserts a comment so that it becomes `comments[index]`. `index == comments.count` appends.
    public mutating func insert(_ comment: Comment, at index: Int) throws {
        let positions = commentItemIndices
        guard index >= 0, index <= positions.count else { throw SidecarError.indexOutOfRange(index) }
        let at = index < positions.count ? positions[index] : items.count
        items.insert(.comment(comment), at: at)
        normalize()
    }

    /// Replaces the comment whose id matches `comment.id`. Returns false if there is none.
    @discardableResult
    public mutating func update(_ comment: Comment) -> Bool {
        guard let i = itemIndex(of: comment.id) else { return false }
        items[i] = .comment(comment)
        normalize()
        return true
    }

    /// Removes the comment with `id`, returning it. Continuation lines go with it.
    @discardableResult
    public mutating func remove(id: UUID) -> Comment? {
        guard let i = itemIndex(of: id), case .comment(let c) = items[i] else { return nil }
        items.remove(at: i)
        normalize()
        return c
    }

    // MARK: Thoughts by uid

    /// The `subject` key: `folder` on a note about a folder (`.flamingo/notes/<folder>.md`).
    public var subject: String? { frontmatterValue(for: "subject") }

    /// True for a note about a folder rather than a file.
    public var isFolderNote: Bool { subject == "folder" }

    /// Every uid in the note.
    public var uids: Set<String> { Set(comments.compactMap { $0.meta?.uid }) }

    private func itemIndex(ofUID uid: String) -> Int? {
        items.firstIndex { if case .comment(let c) = $0 { return c.meta?.uid == uid } else { return false } }
    }

    /// The thought with this uid.
    public func comment(uid: String) -> Comment? {
        itemIndex(ofUID: uid).flatMap { if case .comment(let c) = items[$0] { return c } else { return nil } }
    }

    /// Changes the thought with this uid in place, wherever its text or id has moved to since
    /// the caller last read it. Returns the stored thought (normalized), nil if there is none.
    @discardableResult
    public mutating func update(uid: String, _ change: (inout Comment) throws -> Void) rethrows -> Comment? {
        guard let i = itemIndex(ofUID: uid), case .comment(var c) = items[i] else { return nil }
        try change(&c)
        c.meta?.uid = uid
        items[i] = .comment(c)
        normalize()
        if case .comment(let stored) = items[i] { return stored }
        return nil
    }

    /// Gives the thought with this derived id a uid if it has none, and returns it.
    public mutating func ensureUID(forCommentID id: UUID) -> String? {
        guard let i = itemIndex(of: id), case .comment(var c) = items[i] else { return nil }
        if let uid = c.meta?.uid { return uid }
        var uid = ThoughtUID.generate()
        let taken = uids
        while taken.contains(uid) { uid = ThoughtUID.generate() }
        var meta = c.meta ?? ThoughtMeta()
        meta.uid = uid
        c.meta = meta
        if c.provenance == nil { c.provenance = CommentProvenance(origin: .human) }
        items[i] = .comment(c)
        normalize()
        return uid
    }

    /// Adds `reply` as a thread reply: a top-level bullet placed right after the last
    /// descendant of the thought `parent`, carrying `parent` in its metadata. Returns the
    /// stored reply, nil if the parent is not in this note.
    @discardableResult
    public mutating func appendReply(_ reply: Comment, toUID parent: String) -> Comment? {
        guard let pi = itemIndex(ofUID: parent) else { return nil }
        var r = reply
        var meta = r.meta ?? ThoughtMeta()
        meta.parent = parent
        let taken = uids
        if meta.uid == nil || taken.contains(meta.uid!) {
            var uid = ThoughtUID.generate()
            while taken.contains(uid) { uid = ThoughtUID.generate() }
            meta.uid = uid
        }
        r.meta = meta
        if r.provenance == nil { r.provenance = CommentProvenance(origin: .human) }
        var family: Set<String> = [parent]
        var insertAt = pi + 1
        for j in (pi + 1)..<max(pi + 1, items.count) {
            guard case .comment(let c) = items[j], let p = c.meta?.parent, family.contains(p) else { continue }
            if let uid = c.meta?.uid { family.insert(uid) }
            insertAt = j + 1
        }
        items.insert(.comment(r), at: insertAt)
        normalize()
        if case .comment(let stored) = items[insertAt] { return stored }
        return nil
    }

    /// Appends `other`'s items after this document's (used when two notes merge). Comments
    /// identical to one already here are skipped, so merging the same note twice (a crash
    /// between writing the new note and removing the old one) does not duplicate thoughts.
    /// A raw line that would read back as a continuation of the preceding comment gets a
    /// blank line before it.
    public mutating func merge(_ other: SidecarDocument) {
        var keys = Set(comments.map(SidecarDocument.contentKey))
        for item in other.items {
            switch item {
            case .comment(let c):
                let key = SidecarDocument.contentKey(c)
                guard keys.insert(key).inserted else { continue }
                items.append(item)
            case .raw(let line):
                if case .comment = items.last, line.unicodeScalars.starts(with: "  ".unicodeScalars) {
                    items.append(.raw(""))
                }
                items.append(item)
            }
        }
        normalize()
    }

    /// Recomputes comment ids and truncates timestamps to minute precision. Called after
    /// every mutation; call it yourself only if you edit `frontmatter` by other means.
    public mutating func normalize() {
        let t = target?.relativePath ?? ""
        var seen: [String: Int] = [:]
        for i in items.indices {
            guard case .comment(let c) = items[i] else { continue }
            let ts = SidecarFormat.string(fromTimestamp: c.timestamp)
            let date = SidecarFormat.timestamp(from: ts) ?? c.timestamp
            var anchor = c.anchor
            if let a = anchor, a.value.contains(where: \.isNewline) {
                anchor = FileAnchor(kind: a.kind, value: a.value.map { $0.isNewline ? " " : String($0) }.joined())
            }
            let key = ts + "\n" + (anchor?.rendered ?? "") + "\n" + c.text
            let n = seen[key, default: 0]
            seen[key] = n + 1
            let id = SidecarFormat.stableID(target: t, timestamp: ts, anchor: anchor, text: c.text, occurrence: n)
            if id != c.id || date != c.timestamp || anchor != c.anchor {
                items[i] = .comment(Comment(id: id, timestamp: date, anchor: anchor, text: c.text, provenance: c.provenance, meta: c.meta))
            }
        }
    }

    /// Timestamp, anchor and text: what makes two comments "the same thought".
    static func contentKey(_ c: Comment) -> String {
        SidecarFormat.string(fromTimestamp: c.timestamp) + "\n" + (c.anchor?.rendered ?? "") + "\n" + c.text + (SidecarFormat.metadataLines(of: c).joined(separator: "\n"))
    }

    private var commentItemIndices: [Int] {
        items.indices.filter { if case .comment = items[$0] { return true } else { return false } }
    }

    /// Item index of the comment with `id`. Ids of identical comments are numbered by
    /// occurrence, so after one twin is removed the other is renumbered; an id that names a
    /// vanished higher occurrence of a group still resolves to that group (its last member),
    /// which keeps ids held by a UI valid while it deletes duplicates one by one.
    private func itemIndex(of id: UUID) -> Int? {
        if let i = items.firstIndex(where: { if case .comment(let c) = $0 { return c.id == id } else { return false } }) {
            return i
        }
        let t = target?.relativePath ?? ""
        var groups: [String: [Int]] = [:]
        for (i, item) in items.enumerated() {
            if case .comment(let c) = item { groups[SidecarDocument.contentKey(c), default: []].append(i) }
        }
        for indices in groups.values {
            guard let last = indices.last, case .comment(let c) = items[last] else { continue }
            let ts = SidecarFormat.string(fromTimestamp: c.timestamp)
            for n in indices.count..<(indices.count + 64)
            where SidecarFormat.stableID(target: t, timestamp: ts, anchor: c.anchor, text: c.text, occurrence: n) == id {
                return last
            }
        }
        return nil
    }
}

/// The on-disk format. See CONTRACT.md "Sidecar notes".
///
/// ```
/// ---
/// target: decks/q3.pptx
/// id: 6F9619FF-8B86-D011-B42D-00C04FC964FF
/// ---
/// - [2026-10-14 22:05] (slide 7) Pricing contradicts [[q3-model.xlsx]]
/// - [2026-10-14 22:09] Needs a better title
///   Second line of the same comment is indented two spaces.
/// ```
///
/// Parsing rules, chosen so that `render` reproduces the input byte for byte:
/// - A comment starts with `- [` + a `yyyy-MM-dd HH:mm` timestamp + `]`, then either
///   end of line or a single space and the rest of the line.
/// - If the rest begins with `(kind value)` where `kind` is a known `FileAnchor.Kind`
///   (lowercase) and the closing paren is followed by a space or end of line, that is
///   the anchor. The value may contain spaces, `!`, and even `)`. Unknown kinds are
///   left in the text untouched.
/// - Lines starting with two spaces directly after a comment are continuation lines.
/// - Anything else is kept verbatim as a raw line.
/// - Lines are split on LF only (Swift would otherwise treat `\r\n` as one character).
///   A note whose first line ends in CR is a CRLF note: the CRs are stripped on read and
///   put back on write (`SidecarDocument.lineTerminator`). Structure is matched on Unicode
///   scalars, so text that starts with a combining mark still parses.
///
/// Known deviations from byte-exactness: trailing whitespace after the timestamp or anchor
/// on an otherwise empty first line is dropped; a file without a final newline gains one;
/// a timestamp that falls in the local daylight-saving gap is read as the following hour
/// and written back that way.
public enum SidecarFormat {
    public static let timestampFormat = "yyyy-MM-dd HH:mm"

    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }()

    /// `2026-10-14 22:05`, local time.
    public static func string(fromTimestamp date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// Inverse of `string(fromTimestamp:)`. Accepts exactly `yyyy-MM-dd HH:mm` with a real
    /// calendar date; a time inside the local daylight-saving gap resolves to the following hour.
    public static func timestamp(from string: String) -> Date? {
        let s = Array(string.utf8)
        guard s.count == 16, s[4] == UInt8(ascii: "-"), s[7] == UInt8(ascii: "-"), s[10] == UInt8(ascii: " "), s[13] == UInt8(ascii: ":") else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var n = 0
            for i in range {
                guard s[i] >= UInt8(ascii: "0"), s[i] <= UInt8(ascii: "9") else { return nil }
                n = n * 10 + Int(s[i] - UInt8(ascii: "0"))
            }
            return n
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60 else { return nil }
        let comps = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        guard let date = calendar.date(from: comps) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return date
    }

    /// The id every parse assigns to a comment with this content. `occurrence` is 0 for the
    /// first identical comment in a note, 1 for the next, so duplicates stay distinct.
    public static func stableID(target: String?, timestamp: String, anchor: FileAnchor?, text: String, occurrence: Int) -> UUID {
        StableID.uuid(from: "flamingo.comment\n\(target ?? "")\n\(timestamp)\n\(anchor?.rendered ?? "")\n\(occurrence)\n\(text)")
    }

    // MARK: Render

    public static func render(target: FileRef, id: UUID?, comments: [Comment]) -> String {
        render(SidecarDocument(target: target, id: id, comments: comments))
    }

    /// Serializes a document. Every line ends with the document's `lineTerminator`; an
    /// empty document renders as `""`.
    public static func render(_ document: SidecarDocument) -> String {
        let nl = document.lineTerminator
        var out = ""
        if let fm = document.frontmatter {
            out += "---" + nl
            for line in fm { out += line; out += nl }
            out += "---" + nl
        }
        for item in document.items {
            switch item {
            case .raw(let line):
                out += line; out += nl
            case .comment(let c):
                out += render(comment: c, lineTerminator: nl)
            }
        }
        return out
    }

    /// One comment as its sidecar lines, each terminated by `lineTerminator`.
    public static func render(comment c: Comment, lineTerminator nl: String = "\n") -> String {
        var out = "- [" + string(fromTimestamp: c.timestamp) + "]"
        if let a = c.anchor { out += " " + a.rendered }
        let lines = splitLines(c.text)
        if let first = lines.first, !first.isEmpty { out += " " + first }
        out += nl
        for line in lines.dropFirst() { out += "  " + line + nl }
        for metadata in metadataLines(of: c) { out += "  <!-- flamingo: " + metadata + " -->" + nl }
        return out
    }

    /// Keys of `CommentProvenance`; a hidden line carrying any of them is provenance.
    static let provenanceKeys: Set<String> = ["origin", "model", "appBundleID", "appName", "windowTitle", "sourceURL", "reason"]

    /// The text between `<!-- flamingo: ` and ` -->` for each hidden line a comment writes:
    /// first any non-JSON lines it was read with (kept verbatim), then one JSON object that
    /// merges provenance, thought metadata and unknown keys. The object always has `origin`
    /// (human unless the provenance says otherwise), because Flamingo builds before thoughts
    /// v2 decode the line as provenance and only then keep it out of the thought's text.
    static func metadataLines(of c: Comment) -> [String] {
        var lines = c.meta?.unparsed?.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) ?? []
        if let json = metadataJSON(of: c) { lines.append(json) }
        return lines
    }

    /// The JSON object of the hidden line, nil when the comment has neither provenance nor metadata.
    public static func metadataJSON(of c: Comment) -> String? {
        guard c.provenance != nil || c.meta?.hasFields == true else { return nil }
        var object = c.meta?.fields() ?? [:]
        if let provenance = c.provenance, let p = MetaJSON.object(from: provenance) { object.merge(p) { _, new in new } }
        if object["origin"] == nil { object["origin"] = .string(CommentProvenance.Origin.human.rawValue) }
        return MetaJSON.render(object)
    }

    /// Reads one hidden line (the text between the markers) into `comment`. Any such line is
    /// metadata, never thought text: JSON objects are split into provenance, metadata and
    /// unknown keys; anything else is kept verbatim in `meta.unparsed`.
    public static func applyMetadata(_ line: String, to comment: inout Comment) {
        guard var object = MetaJSON.parseObject(line), !object.isEmpty else {
            var meta = comment.meta ?? ThoughtMeta()
            meta.unparsed = meta.unparsed.map { $0 + "\n" + line } ?? line
            comment.meta = meta
            return
        }
        // A second JSON line merges into what the first one said.
        let unparsed = comment.meta?.unparsed
        if comment.provenance != nil || comment.meta?.hasFields == true {
            var earlier = comment.meta?.fields() ?? [:]
            if let p = comment.provenance.flatMap({ MetaJSON.object(from: $0) }) { earlier.merge(p) { _, new in new } }
            object = earlier.merging(object) { _, new in new }
        }
        var provenanceObject: [String: MetaJSON] = [:]
        for key in provenanceKeys { if let v = object.removeValue(forKey: key) { provenanceObject[key] = v } }
        var provenance: CommentProvenance?
        if !provenanceObject.isEmpty {
            var candidate = provenanceObject
            if candidate["origin"] == nil { candidate["origin"] = .string(CommentProvenance.Origin.human.rawValue) }
            if let decoded = MetaJSON.decode(CommentProvenance.self, from: .object(candidate)) { provenance = decoded }
            else { object.merge(provenanceObject) { old, _ in old } }
        }
        var meta = ThoughtMeta(taking: &object)
        meta.unparsed = unparsed
        comment.provenance = provenance
        comment.meta = meta.hasFields || meta.unparsed != nil ? meta : nil
    }

    // MARK: Parse

    public static func parse(_ text: String) -> (target: FileRef?, id: UUID?, comments: [Comment]) {
        let doc = parseDocument(text)
        return (doc.target, doc.id, doc.comments)
    }

    /// Parses a sidecar note, keeping everything (see the type's rules).
    public static func parseDocument(_ text: String) -> SidecarDocument {
        guard !text.isEmpty else { return SidecarDocument() }
        var lines = splitLines(text)
        if lines.last == "" { lines.removeLast() }
        var terminator = "\n"
        if lines.first?.hasSuffix("\r") == true {
            terminator = "\r\n"
            lines = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        }

        var frontmatter: [String]? = nil
        var bodyStart = 0
        if lines.first == "---", let close = lines[1...].firstIndex(of: "---") {
            frontmatter = Array(lines[1..<close])
            bodyStart = close + 1
        }

        var items: [SidecarDocument.Item] = []
        var current: Comment? = nil
        func flush() {
            if let c = current { items.append(.comment(c)); current = nil }
        }
        for line in lines[bodyStart...] {
            if let c = parseCommentStart(line) {
                flush()
                current = c
            } else if var c = current, line.count >= "  <!-- flamingo:  -->".count,
                      line.hasPrefix("  <!-- flamingo: "), line.hasSuffix(" -->") {
                // Any hidden metadata line is metadata, even one this build cannot read.
                applyMetadata(String(line.dropFirst("  <!-- flamingo: ".count).dropLast(" -->".count)), to: &c)
                current = c
            } else if var c = current, line.unicodeScalars.starts(with: "  ".unicodeScalars) {
                c.text += "\n" + string(line.unicodeScalars.dropFirst(2))
                current = c
            } else {
                flush()
                items.append(.raw(line))
            }
        }
        flush()
        var doc = SidecarDocument(frontmatter: frontmatter, items: items)
        doc.lineTerminator = terminator
        return doc
    }

    /// Splits on the LF scalar only. `Character`-based splitting would treat `\r\n` as one
    /// character and never split a CRLF file.
    static func splitLines(_ text: String) -> [String] {
        var out: [String] = []
        let scalars = text.unicodeScalars
        var start = scalars.startIndex
        var i = start
        while i < scalars.endIndex {
            if scalars[i] == "\n" {
                out.append(string(scalars[start..<i]))
                i = scalars.index(after: i)
                start = i
            } else {
                i = scalars.index(after: i)
            }
        }
        out.append(string(scalars[start..<scalars.endIndex]))
        return out
    }

    private static func string(_ slice: Substring.UnicodeScalarView) -> String {
        String(String.UnicodeScalarView(slice))
    }

    /// `- [2026-10-14 22:05] (slide 7) text` → a comment with the first line of its text.
    static func parseCommentStart(_ line: String) -> Comment? {
        let s = line.unicodeScalars
        guard s.starts(with: "- [".unicodeScalars) else { return nil }
        let tsStart = s.index(s.startIndex, offsetBy: 3)
        guard let close = s[tsStart...].firstIndex(of: "]") else { return nil }
        guard let date = timestamp(from: string(s[tsStart..<close])) else { return nil }
        let rest = s[s.index(after: close)...]
        if rest.isEmpty { return Comment(timestamp: date, anchor: nil, text: "") }
        guard rest.first == " " else { return nil }
        let body = rest.dropFirst()
        if let (anchor, text) = parseAnchor(body) {
            return Comment(timestamp: date, anchor: anchor, text: text)
        }
        return Comment(timestamp: date, anchor: nil, text: string(body))
    }

    /// `(kind value) rest` → the anchor and `rest`; nil if `body` does not start with a known anchor.
    static func parseAnchor(_ body: Substring.UnicodeScalarView) -> (FileAnchor, String)? {
        guard body.first == "(" else { return nil }
        let inner = body.dropFirst()
        guard let space = inner.firstIndex(of: " "), space > inner.startIndex,
              let kind = FileAnchor.Kind(rawValue: string(inner[..<space])) else { return nil }
        let valueStart = inner.index(after: space)
        var from = valueStart
        while let close = inner[from...].firstIndex(of: ")") {
            let next = inner.index(after: close)
            let value = string(inner[valueStart..<close])
            if next == inner.endIndex { return (FileAnchor(kind: kind, value: value), "") }
            if inner[next] == " " { return (FileAnchor(kind: kind, value: value), string(inner[inner.index(after: next)...])) }
            from = next
        }
        return nil
    }
}

/// Just enough YAML for one-line scalars in frontmatter.
enum YAMLScalar {
    /// `key: value` → (key, unquoted value). Requires `: ` or `:` at end of line, like YAML.
    static func keyValue(of line: String) -> (key: String, value: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.hasPrefix("#"), !key.contains(where: { $0.isWhitespace }) else { return nil }
        let after = line[line.index(after: colon)...]
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        return (key, unquote(after.trimmingCharacters(in: .whitespaces)))
    }

    static func unquote(_ raw: String) -> String {
        guard raw.count >= 2 else { return raw }
        if raw.hasPrefix("\""), raw.hasSuffix("\"") {
            var out = ""
            var escaped = false
            for ch in raw.dropFirst().dropLast() {
                if escaped {
                    switch ch {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: out.append(ch)
                    }
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else {
                    out.append(ch)
                }
            }
            return out
        }
        if raw.hasPrefix("'"), raw.hasSuffix("'") {
            return raw.dropFirst().dropLast().replacingOccurrences(of: "''", with: "'")
        }
        return raw
    }

    private static let reservedWords: Set<String> = ["true", "false", "yes", "no", "on", "off", "null", "~", "y", "n"]

    /// Wraps in double quotes when a YAML parser would otherwise misread the value.
    static func quoteIfNeeded(_ value: String) -> String {
        var needs = value.isEmpty
        if let f = value.first, "-?:,[]{}#&*!|>'\"%@` ".contains(f) || f.isWhitespace { needs = true }
        if let l = value.last, l.isWhitespace || l == ":" { needs = true }
        if value.contains(": ") || value.contains(" #") || value.contains("\n") || value.contains("\t") { needs = true }
        if reservedWords.contains(value.lowercased()) || Double(value) != nil { needs = true }
        guard needs else { return value }
        var out = "\""
        for ch in value {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out + "\""
    }
}
