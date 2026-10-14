import Foundation

/// Where inside a file a comment points. Rendered as `(kind value)` in sidecars,
/// e.g. `(slide 7)`, `(page 12)`, `(cell Q3!B12)`, `(time 1:23)`, `(line 40)`.
public struct FileAnchor: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case page, slide, sheet, cell, time, line, node, region
    }
    public let kind: Kind
    public let value: String
    public init(kind: Kind, value: String) { self.kind = kind; self.value = value }
    public var rendered: String { "(\(kind.rawValue) \(value))" }

    /// The human form without parentheses, `slide 7`, for chips and labels.
    public var label: String { "\(kind.rawValue) \(value)" }

    /// Parses `"slide 7"`, `"Cell Q3!B12"`, `"time 1:23"`. Kind is case-insensitive;
    /// the value is the rest of the string, trimmed, must be non-empty and on one line.
    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = trimmed.firstIndex(where: { $0.isWhitespace }) else { return nil }
        guard let kind = Kind(rawValue: String(trimmed[..<space]).lowercased()) else { return nil }
        let value = trimmed[space...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isNewline) else { return nil }
        self.init(kind: kind, value: value)
    }

    /// Parses the exact sidecar form `"(slide 7)"`. The whole string must be the anchor;
    /// the value is taken verbatim (not trimmed) so `rendered` reproduces the input.
    public init?(rendered text: String) {
        guard text.hasPrefix("("), text.hasSuffix(")"), text.count >= 3 else { return nil }
        let inner = text.dropFirst().dropLast()
        guard let space = inner.firstIndex(of: " ") else { return nil }
        guard let kind = Kind(rawValue: String(inner[..<space])) else { return nil }
        self.init(kind: kind, value: String(inner[inner.index(after: space)...]))
    }
}

/// One thought left on a file.
///
/// Ids are not written to disk (sidecars are plain Markdown). `SidecarStore` and
/// `SidecarFormat.parse` derive each comment's id deterministically from its target,
/// timestamp, anchor, and text, so the same line always yields the same id across
/// reads and processes. Consequently the id of a `Comment` you pass to `append` is not
/// the id you will read back; use `comments(for:)` after writing. Editing a comment
/// (`update`) changes its id.
public struct Comment: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var timestamp: Date
    public var anchor: FileAnchor?
    public var text: String
    /// Basenames or relative paths referenced by `[[...]]` in `text`. Derived; kept for convenience.
    public var links: [String] { Wikilink.parse(text) }

    public init(id: UUID = UUID(), timestamp: Date = Date(), anchor: FileAnchor? = nil, text: String) {
        self.id = id; self.timestamp = timestamp; self.anchor = anchor; self.text = text
    }

    /// The first line of `text`, for list rows.
    public var firstLine: String {
        if let nl = text.firstIndex(of: "\n") { return String(text[..<nl]) }
        return text
    }

    /// Whether `text` spans more than one line.
    public var isMultiline: Bool { text.contains("\n") }
}
