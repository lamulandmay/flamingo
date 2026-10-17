import Foundation
import FlamingoCore

/// Where a thought lands when it is not about a vault file: the note's ref, the front matter a
/// new note starts with, and a short name for the target line. The shell uses the same values
/// when it saves a composer's thought for a folder.
public struct ThoughtNote: Equatable, Sendable {
    public var file: FileRef
    /// Keys for a new note (`SidecarStore.append(_:to:frontmatter:)`); empty for an ordinary file.
    public var frontmatter: [String: String]
    /// What the target line names: the folder's name, the page's title or host.
    public var name: String
    public var isFolder: Bool

    public init(file: FileRef, frontmatter: [String: String] = [:], name: String, isFolder: Bool = false) {
        self.file = file; self.frontmatter = frontmatter; self.name = name; self.isFolder = isFolder
    }

    /// A note about a folder: `.flamingo/notes/<folder>.md` with `subject: folder`.
    /// `folder` is relative to the vault root with no trailing slash; nil for the root itself.
    public static func folder(_ folder: FileRef) -> ThoughtNote? {
        var path = folder.relativePath
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty, path != ".", !path.hasPrefix(".flamingo") else { return nil }
        let ref = FileRef(relativePath: path)
        return ThoughtNote(file: ref, frontmatter: ["subject": "folder"], name: ref.name, isFolder: true)
    }

    /// A note about a web page no vault file stands behind. Nil unless `url` is http(s) with a host.
    public static func web(url: String, title: String?) -> ThoughtNote? {
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ref = WebThought.ref(for: url, title: cleanTitle) else { return nil }
        let host = URL(string: url)?.host ?? url
        let name = (cleanTitle?.isEmpty == false ? cleanTitle : nil) ?? host
        return ThoughtNote(file: ref, frontmatter: WebThought.frontmatter(url: url, title: cleanTitle), name: name ?? host)
    }
}

/// Selected text from another app, as it is written into a thought.
public enum ThoughtQuote {
    /// The longest selection that is read.
    public static let limit = 2_000

    /// `> ` lines for `selection`, nil when it is blank. Cut at `limit` characters; line breaks
    /// are kept, runs of blank lines collapse, and each line is trimmed on the right.
    public static func lines(from selection: String?) -> String? {
        guard var text = selection?.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") else { return nil }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.count > limit { text = String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) }
        var out: [String] = []
        var lastBlank = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank, lastBlank { continue }
            lastBlank = blank
            out.append(blank ? ">" : "> " + line)
        }
        return out.joined(separator: "\n")
    }

    /// The saved text: the quote, a blank line, then what the person wrote.
    public static func compose(quote: String?, text: String) -> String {
        guard let quote, !quote.isEmpty else { return text }
        return text.isEmpty ? quote : quote + "\n\n" + text
    }
}
