import Foundation

/// gitignore-style rules read from `<vault>/.flamingoignore`.
///
/// Supported subset (a single file at the vault root, nothing nested):
/// - Blank lines and lines starting with `#` are ignored. Trailing whitespace is trimmed.
///   A leading `\#` or `\!` is a literal `#` / `!`.
/// - `!pattern` negates: a path matching a negated pattern is re-included. Patterns are
///   evaluated in order and the last match wins.
/// - A pattern ending in `/` matches directories only.
/// - A pattern with no `/` (after stripping a trailing one) matches the basename at any
///   depth. A pattern containing a `/` anywhere else is anchored to the vault root; a
///   leading `/` is stripped.
/// - Globs: `*` (any run except `/`), `?` (one character except `/`), `**` (zero or more
///   path components: `**/x`, `x/**`, `a/**/b`), classes `[abc]`, `[a-z]`, `[!a-z]`.
///   Every other character is literal. Matching is case-sensitive.
/// - As in gitignore, once a directory is excluded nothing inside it can be re-included.
public struct IgnoreRules: Sendable, Equatable {
    /// Name of the rules file, looked up directly under the vault root.
    public static let fileName = ".flamingoignore"

    /// Rules that ignore nothing.
    public static let empty = IgnoreRules(text: "")

    /// One parsed, compiled line of the rules file.
    struct Pattern: @unchecked Sendable, Equatable {
        /// The glob after stripping negation and leading/trailing slashes.
        let glob: String
        /// `!pattern` — a match re-includes the path.
        let negated: Bool
        /// Trailing `/` — only directories can match.
        let directoryOnly: Bool
        /// Contains a `/` (other than trailing) — matched against the whole relative
        /// path from the vault root rather than the basename.
        let anchored: Bool
        /// Compiled, fully anchored (`^...$`) translation of `glob`.
        let regex: NSRegularExpression

        static func == (lhs: Pattern, rhs: Pattern) -> Bool {
            lhs.glob == rhs.glob && lhs.negated == rhs.negated
                && lhs.directoryOnly == rhs.directoryOnly && lhs.anchored == rhs.anchored
        }

        func matches(_ subject: String) -> Bool {
            let range = NSRange(subject.startIndex..<subject.endIndex, in: subject)
            return regex.firstMatch(in: subject, options: [], range: range) != nil
        }
    }

    let patterns: [Pattern]

    /// Parses the text of a `.flamingoignore` file. Lines that cannot be compiled are dropped.
    public init(text: String) {
        var out: [Pattern] = []
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            if let pattern = IgnoreRules.pattern(fromLine: String(rawLine)) { out.append(pattern) }
        }
        patterns = out
    }

    /// Reads and parses the file at `url`. A missing or unreadable file is an error;
    /// callers decide whether that means "no rules".
    public init(contentsOf url: URL) throws {
        self.init(text: try String(contentsOf: url, encoding: .utf8))
    }

    /// `true` when there are no patterns at all.
    public var isEmpty: Bool { patterns.isEmpty }

    /// Whether `relativePath` is excluded by these rules.
    ///
    /// `relativePath` uses `/` separators and no leading `/`. Directories are matched with
    /// `isDirectory: true`. A path is ignored when the last matching pattern is positive, or
    /// when any proper ancestor directory is ignored (ancestors cannot be re-included from
    /// inside, as in gitignore).
    public func isIgnored(_ relativePath: String, isDirectory: Bool) -> Bool {
        guard !patterns.isEmpty else { return false }
        let path = IgnoreRules.normalize(relativePath)
        guard !path.isEmpty else { return false }
        if verdict(for: path, isDirectory: isDirectory) { return true }
        // Proper ancestors: "a/b/c.txt" -> "a", "a/b".
        var ancestor = ""
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        for component in components.dropLast() {
            ancestor = ancestor.isEmpty ? String(component) : ancestor + "/" + component
            if verdict(for: ancestor, isDirectory: true) { return true }
        }
        return false
    }

    /// The last-match-wins result for exactly this path, ignoring ancestors. The scanner uses
    /// this directly because it never descends into directories it already skipped.
    func verdict(for path: String, isDirectory: Bool) -> Bool {
        let basename = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
        var ignored = false
        for pattern in patterns {
            if pattern.directoryOnly && !isDirectory { continue }
            let subject = pattern.anchored ? path : basename
            if pattern.matches(subject) { ignored = !pattern.negated }
        }
        return ignored
    }

    // MARK: - Parsing

    /// Strips leading and trailing `/` so callers can be sloppy about separators.
    static func normalize(_ relativePath: String) -> String {
        var s = Substring(relativePath)
        while s.hasPrefix("/") { s = s.dropFirst() }
        while s.hasSuffix("/") { s = s.dropLast() }
        return String(s)
    }

    /// Turns one line of the file into a pattern, or `nil` for blanks, comments, and
    /// lines that reduce to nothing.
    static func pattern(fromLine rawLine: String) -> Pattern? {
        var line = Substring(rawLine)
        while let last = line.last, last == " " || last == "\t" || last == "\r" { line = line.dropLast() }
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }

        var negated = false
        if line.hasPrefix("!") { negated = true; line = line.dropFirst() }
        // "\#" and "\!" stay in the glob; the translator turns "\x" into a literal x.

        var directoryOnly = false
        if line.hasSuffix("/") {
            directoryOnly = true
            while line.hasSuffix("/") { line = line.dropLast() }
        }
        let anchored = line.contains("/")
        while line.hasPrefix("/") { line = line.dropFirst() }
        guard !line.isEmpty else { return nil }

        let glob = String(line)
        guard let regex = try? NSRegularExpression(pattern: regexSource(forGlob: glob)) else { return nil }
        return Pattern(glob: glob, negated: negated, directoryOnly: directoryOnly, anchored: anchored, regex: regex)
    }

    /// Translates a gitignore glob into an anchored ICU regular expression.
    static func regexSource(forGlob glob: String) -> String {
        let chars = Array(glob)
        var out = "^"
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                var j = i
                while j < chars.count, chars[j] == "*" { j += 1 }
                let isDoubleStar = j - i >= 2
                let atComponentStart = i == 0 || chars[i - 1] == "/"
                let atEnd = j == chars.count
                let followedBySlash = j < chars.count && chars[j] == "/"
                if isDoubleStar && atComponentStart && followedBySlash {
                    out += "(?:.*/)?"      // "**/x": x at any depth
                    i = j + 1
                } else if isDoubleStar && atComponentStart && atEnd {
                    out += ".*"            // "x/**": everything inside x
                    i = j
                } else {
                    out += "[^/]*"         // plain "*" (or "**" inside a name)
                    i = j
                }
            case "?":
                out += "[^/]"
                i += 1
            case "[":
                var j = i + 1
                var negate = false
                if j < chars.count, chars[j] == "!" || chars[j] == "^" { negate = true; j += 1 }
                let bodyStart = j
                if j < chars.count, chars[j] == "]" { j += 1 }   // a leading "]" is a literal member
                while j < chars.count, chars[j] != "]" { j += 1 }
                if j < chars.count, j > bodyStart {
                    var body = ""
                    for member in chars[bodyStart..<j] {
                        if member.isLetter || member.isNumber || member == "-" { body.append(member) }
                        else { body += NSRegularExpression.escapedPattern(for: String(member)) }
                    }
                    out += negate ? "[^/" + body + "]" : "[" + body + "]"
                    i = j + 1
                } else {
                    out += "\\["           // unterminated or empty class: literal bracket
                    i += 1
                }
            case "\\":
                if i + 1 < chars.count {
                    out += NSRegularExpression.escapedPattern(for: String(chars[i + 1]))
                    i += 2
                } else {
                    out += "\\\\"
                    i += 1
                }
            default:
                out += NSRegularExpression.escapedPattern(for: String(c))
                i += 1
            }
        }
        out += "$"
        return out
    }
}
