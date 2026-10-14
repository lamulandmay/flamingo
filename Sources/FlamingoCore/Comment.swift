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
}

/// One thought left on a file.
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
}
