import Foundation

/// A memo the night shift (or "Work on this now") wrote about a thought, as an Obsidian
/// Markdown note under `.flamingo/work/<yyyy-MM-dd>/<slug>.md`. Rendering and parsing are
/// pure; nothing here reads or writes a user's file.
///
/// ```
/// ---
/// flamingo: memo
/// thought: t8m2k4q9xa
/// on: "decks/q3-board-review.pptx#slide 7"
/// recipe: review-conflict
/// verdict: conflict
/// sources:
///   - "decks/q3-board-review.pptx#slide 7 · 2026-10-13 14:02"
/// model: qwen3.8-27b
/// provider: llama
/// tokens: 7412
/// created: 2026-10-17 02:14
/// ---
/// # Arc price: deck $249, model $229
///
/// body…
/// ```
public struct WorkMemo: Hashable, Sendable {
    public var thought: String
    public var on: String
    public var recipe: String
    public var verdict: String?
    /// `path#anchor · yyyy-MM-dd HH:mm` (the source's modification time when it was read).
    public var sources: [String]
    public var model: String
    public var provider: String?
    public var tokens: Int?
    /// `yyyy-MM-dd HH:mm`, local.
    public var created: String
    public var title: String
    /// Markdown after the title.
    public var body: String
    /// Front matter keys this build does not know, in order.
    var otherFrontmatter: [String] = []

    public init(thought: String, on: String, recipe: String, verdict: String? = nil, sources: [String] = [],
                model: String, provider: String? = nil, tokens: Int? = nil, created: String, title: String, body: String) {
        self.thought = thought; self.on = on; self.recipe = recipe; self.verdict = verdict; self.sources = sources
        self.model = model; self.provider = provider; self.tokens = tokens; self.created = created; self.title = title; self.body = body
    }

    // MARK: Paths

    /// Path relative to `.flamingo`: `work/2026-10-17/arc-price-q3-board-review.md`.
    public func relativePath(slug: String? = nil) -> String {
        let day = String(created.prefix(10))
        return "work/\(day)/\(slug ?? WorkMemo.slug(for: title.isEmpty ? recipe : title)).md"
    }

    public func url(in vault: Vault, slug: String? = nil) -> URL {
        vault.stateDir.appendingPathComponent(relativePath(slug: slug))
    }

    public static func slug(for text: String) -> String {
        let slug = WebThought.slug(text)
        return slug.isEmpty ? "memo" : slug
    }

    // MARK: Render and parse

    private static func quoted(_ value: String) -> String {
        var out = "\""
        for ch in value {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            default: out.append(ch)
            }
        }
        return out + "\""
    }

    public func render() -> String {
        var lines = ["---", "flamingo: memo", "thought: " + YAMLScalar.quoteIfNeeded(thought), "on: " + WorkMemo.quoted(on),
                     "recipe: " + YAMLScalar.quoteIfNeeded(recipe)]
        if let verdict { lines.append("verdict: " + YAMLScalar.quoteIfNeeded(verdict)) }
        if !sources.isEmpty {
            lines.append("sources:")
            for s in sources { lines.append("  - " + WorkMemo.quoted(s)) }
        }
        lines.append("model: " + YAMLScalar.quoteIfNeeded(model))
        if let provider { lines.append("provider: " + YAMLScalar.quoteIfNeeded(provider)) }
        if let tokens { lines.append("tokens: \(tokens)") }
        lines.append("created: " + YAMLScalar.quoteIfNeeded(created))
        lines += otherFrontmatter
        lines.append("---")
        lines.append("# " + title)
        if !body.isEmpty { lines.append(""); lines.append(body) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Nil unless the text starts with `---` front matter that says `flamingo: memo`.
    public static func parse(_ text: String) -> WorkMemo? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        guard lines.first == "---", let close = lines[1...].firstIndex(of: "---") else { return nil }
        let front = Array(lines[1..<close])
        var scalars: [String: String] = [:]
        var sources: [String] = []
        var other: [String] = []
        var inSources = false
        for line in front {
            if inSources, line.hasPrefix("  - ") {
                sources.append(YAMLScalar.unquote(String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            inSources = false
            guard let kv = YAMLScalar.keyValue(of: line) else { other.append(line); continue }
            if kv.key == "sources" { inSources = true; continue }
            if ["flamingo", "thought", "on", "recipe", "verdict", "model", "provider", "tokens", "created"].contains(kv.key) { scalars[kv.key] = kv.value }
            else { other.append(line) }
        }
        guard scalars["flamingo"] == "memo", let thought = scalars["thought"], let recipe = scalars["recipe"] else { return nil }
        var rest = Array(lines[(close + 1)...])
        while rest.first == "" { rest.removeFirst() }
        var title = ""
        if let first = rest.first, first.hasPrefix("# ") { title = String(first.dropFirst(2)); rest.removeFirst() }
        while rest.first == "" { rest.removeFirst() }
        var memo = WorkMemo(thought: thought, on: scalars["on"] ?? "", recipe: recipe, verdict: scalars["verdict"], sources: sources,
                            model: scalars["model"] ?? "", provider: scalars["provider"], tokens: scalars["tokens"].flatMap(Int.init),
                            created: scalars["created"] ?? "", title: title, body: rest.joined(separator: "\n"))
        memo.otherFrontmatter = other
        return memo
    }

    // MARK: Disk

    /// Writes the memo atomically under `.flamingo/work`. Returns its path relative to `.flamingo`
    /// (what goes in a reply's `work` key). Never touches a user file.
    @discardableResult
    public func write(in vault: Vault, slug: String? = nil) throws -> String {
        let relative = relativePath(slug: slug)
        try AtomicFile.write(Data(render().utf8), to: vault.stateDir.appendingPathComponent(relative))
        return relative
    }

    public static func read(at url: URL) -> WorkMemo? {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap(parse)
    }
}

/// The append-only `.flamingo/work/ledger.jsonl`, one JSON object per line. The events and the
/// planner that reads them are in FlamingoThoughts; this is the file format's plumbing.
public enum WorkLedgerFile {
    /// Appends one line (no newline in `json`). A `flock` keeps two processes' lines whole.
    public static func append(_ json: String, in vault: Vault) throws {
        let url = vault.workLedgerURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw SidecarError.writeFailed(path: url.path, errno: errno) }
        defer { close(fd) }
        flock(fd, LOCK_EX); defer { flock(fd, LOCK_UN) }
        let bytes = Array((json.replacingOccurrences(of: "\n", with: " ") + "\n").utf8)
        guard write(fd, bytes, bytes.count) == bytes.count else { throw SidecarError.writeFailed(path: url.path, errno: errno) }
    }

    /// Every complete line. A torn last line (a crash mid-append) has no newline and is dropped.
    public static func lines(in vault: Vault) -> [String] {
        guard let data = try? Data(contentsOf: vault.workLedgerURL), let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if !text.hasSuffix("\n"), !lines.isEmpty { lines.removeLast() }
        return lines
    }
}
