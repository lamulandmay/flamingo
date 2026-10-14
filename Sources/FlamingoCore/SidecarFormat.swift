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

    /// Appends every item of `other` after this document's items (used when two notes merge).
    public mutating func merge(_ other: SidecarDocument) {
        items.append(contentsOf: other.items)
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
            let key = ts + "\n" + (c.anchor?.rendered ?? "") + "\n" + c.text
            let n = seen[key, default: 0]
            seen[key] = n + 1
            let id = SidecarFormat.stableID(target: t, timestamp: ts, anchor: c.anchor, text: c.text, occurrence: n)
            if id != c.id || date != c.timestamp {
                items[i] = .comment(Comment(id: id, timestamp: date, anchor: c.anchor, text: c.text))
            }
        }
    }

    private var commentItemIndices: [Int] {
        items.indices.filter { if case .comment = items[$0] { return true } else { return false } }
    }

    private func itemIndex(of id: UUID) -> Int? {
        items.firstIndex { if case .comment(let c) = $0 { return c.id == id } else { return false } }
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
/// - Only trailing whitespace after the timestamp or anchor on an otherwise empty
///   first line is not preserved; and a file without a final newline gains one.
public enum SidecarFormat {
    public static let timestampFormat = "yyyy-MM-dd HH:mm"

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.isLenient = false
        f.dateFormat = timestampFormat
        return f
    }()

    /// `2026-10-14 22:05`, local time.
    public static func string(fromTimestamp date: Date) -> String { formatter.string(from: date) }

    /// Strict inverse of `string(fromTimestamp:)`: only accepts strings it would itself produce.
    public static func timestamp(from string: String) -> Date? {
        guard string.count == timestampFormat.count, let d = formatter.date(from: string),
              formatter.string(from: d) == string else { return nil }
        return d
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

    /// Serializes a document. Every line ends with `\n`; an empty document renders as `""`.
    public static func render(_ document: SidecarDocument) -> String {
        var out = ""
        if let fm = document.frontmatter {
            out += "---\n"
            for line in fm { out += line; out += "\n" }
            out += "---\n"
        }
        for item in document.items {
            switch item {
            case .raw(let line):
                out += line; out += "\n"
            case .comment(let c):
                out += render(comment: c)
            }
        }
        return out
    }

    /// One comment as its sidecar lines (each terminated by `\n`).
    public static func render(comment c: Comment) -> String {
        var out = "- [" + string(fromTimestamp: c.timestamp) + "]"
        if let a = c.anchor { out += " " + a.rendered }
        let lines = c.text.split(separator: "\n", omittingEmptySubsequences: false)
        if let first = lines.first, !first.isEmpty { out += " " + first }
        out += "\n"
        for line in lines.dropFirst() { out += "  " + line + "\n" }
        return out
    }

    // MARK: Parse

    public static func parse(_ text: String) -> (target: FileRef?, id: UUID?, comments: [Comment]) {
        let doc = parseDocument(text)
        return (doc.target, doc.id, doc.comments)
    }

    /// Parses a sidecar note, keeping everything (see the type's rules).
    public static func parseDocument(_ text: String) -> SidecarDocument {
        guard !text.isEmpty else { return SidecarDocument() }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }

        var frontmatter: [String]? = nil
        var bodyStart = lines.startIndex
        if lines.first == "---", let close = lines[(lines.startIndex + 1)...].firstIndex(of: "---") {
            frontmatter = lines[(lines.startIndex + 1)..<close].map(String.init)
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
            } else if var c = current, line.hasPrefix("  ") {
                c.text += "\n" + line.dropFirst(2)
                current = c
            } else {
                flush()
                items.append(.raw(String(line)))
            }
        }
        flush()
        return SidecarDocument(frontmatter: frontmatter, items: items)
    }

    /// `- [2026-10-14 22:05] (slide 7) text` → a comment with the first line of its text.
    static func parseCommentStart(_ line: Substring) -> Comment? {
        guard line.hasPrefix("- [") else { return nil }
        let tsStart = line.index(line.startIndex, offsetBy: 3)
        guard let close = line[tsStart...].firstIndex(of: "]") else { return nil }
        let ts = String(line[tsStart..<close])
        guard let date = timestamp(from: ts) else { return nil }
        let rest = line[line.index(after: close)...]
        if rest.isEmpty { return Comment(timestamp: date, anchor: nil, text: "") }
        guard rest.first == " " else { return nil }
        let body = rest.dropFirst()
        if let (anchor, text) = parseAnchor(body) {
            return Comment(timestamp: date, anchor: anchor, text: text)
        }
        return Comment(timestamp: date, anchor: nil, text: String(body))
    }

    /// `(kind value) rest` → the anchor and `rest`; nil if `body` does not start with a known anchor.
    static func parseAnchor(_ body: Substring) -> (FileAnchor, String)? {
        guard body.first == "(" else { return nil }
        let inner = body.dropFirst()
        guard let space = inner.firstIndex(of: " "), space > inner.startIndex,
              let kind = FileAnchor.Kind(rawValue: String(inner[..<space])) else { return nil }
        let valueStart = inner.index(after: space)
        var from = valueStart
        while let close = inner[from...].firstIndex(of: ")") {
            let next = inner.index(after: close)
            let value = String(inner[valueStart..<close])
            if next == inner.endIndex { return (FileAnchor(kind: kind, value: value), "") }
            if inner[next] == " " { return (FileAnchor(kind: kind, value: value), String(inner[inner.index(after: next)...])) }
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
