import Foundation
import FlamingoCore

/// One numbered piece of retrieved context: a section of a file or one of the user's comments.
/// The model cites it as `[id]`.
public struct Passage: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case comment, section }

    public let id: Int
    public var kind: Kind
    public var file: FileRef
    public var anchor: FileAnchor?
    public var title: String?
    public var text: String
    /// When the comment was written. Sections have none.
    public var timestamp: Date?

    public init(id: Int, kind: Kind, file: FileRef, anchor: FileAnchor? = nil, title: String? = nil,
                text: String, timestamp: Date? = nil) {
        self.id = id; self.kind = kind; self.file = file; self.anchor = anchor
        self.title = title; self.text = text; self.timestamp = timestamp
    }

    /// `[3]`, as the model writes it.
    public var tag: String { "[\(id)]" }
    public var citation: Citation { Citation(file: file, anchor: anchor) }
}

extension Passage {
    /// The XML-ish block the model reads. Attributes are escaped and passage tags inside the
    /// text are broken, so a file can't close its block early; the text is otherwise verbatim.
    var prompt: String {
        var attrs = "id=\"\(id)\" kind=\"\(kind.rawValue)\" file=\"\(Self.attribute(file.relativePath))\""
        if let anchor { attrs += " at=\"\(anchor.kind.rawValue) \(Self.attribute(anchor.value))\"" }
        if let title, !title.isEmpty { attrs += " title=\"\(Self.attribute(title))\"" }
        if let timestamp { attrs += " date=\"\(Self.day.string(from: timestamp))\"" }
        return "<passage \(attrs)>\n\(Self.body(text))\n</passage>"
    }

    static func attribute(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\n", with: " ")
    }

    static func body(_ s: String) -> String {
        s.replacingOccurrences(of: "</passage", with: "</ passage", options: .caseInsensitive)
            .replacingOccurrences(of: "<passage", with: "< passage", options: .caseInsensitive)
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
