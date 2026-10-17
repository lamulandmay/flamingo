import AppKit

/// `MarkdownLite` for other modules: a work memo's body as styled text for an `NSTextView`.
/// No citations (a memo's sources are wikilinks, which the caller turns into links).
public enum MemoMarkdown {
    public static func attributed(_ markdown: String) -> NSAttributedString {
        MarkdownLite.render(markdown, sources: [:], streaming: false)
    }
}
