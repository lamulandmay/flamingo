import Foundation

/// What a thought could set in motion. Proposed from the words alone; nothing here runs by
/// itself: `ask` and `work` start a local model when the person says so (or at night),
/// `remind` only sets a due date, `connect` and `open` are offered and wait for a tap.
public enum ThoughtAction: Hashable, Codable, Sendable {
    /// `@ai` or `@flamingo` was written. `scope` is the files the question is about.
    case ask(mention: String, scope: [String])
    case remind(at: Date)
    /// Link two files that the thought relates.
    case connect(String, String)
    case open(String, FileAnchor?)
    /// Run a work recipe (`review-conflict`, `compare-versions`, `summarize`, `answer`, `find-related`)
    /// on these files and anchors, e.g. `finance/q3-model.xlsx` or `decks/q3.pptx#slide 7`.
    case work(recipe: String, objects: [String])

    /// The actions a thought's words suggest. `file` is the file the thought is on, if any.
    public static func proposed(for comment: Comment, rules: ThoughtReading, resolvedLinks: [FileRef], file: FileRef? = nil) -> [ThoughtAction] {
        var out: [ThoughtAction] = []
        var scope: [String] = []
        if let file, !file.isVirtual { scope.append(anchored(file, comment.anchor)) }
        for link in resolvedLinks where !scope.contains(link.relativePath) { scope.append(link.relativePath) }
        scope = Array(scope.prefix(6))
        if let mention = rules.mentions.first { out.append(.ask(mention: mention, scope: scope)) }
        if let due = rules.due { out.append(.remind(at: due.date)) }
        if let recipe = rules.recipe, !scope.isEmpty { out.append(.work(recipe: recipe, objects: scope)) }
        if resolvedLinks.count >= 2 {
            out.append(.connect(resolvedLinks[0].relativePath, resolvedLinks[1].relativePath))
        } else if let file, !file.isVirtual, let link = resolvedLinks.first, link != file, rules.kind != .question {
            out.append(.connect(file.relativePath, link.relativePath))
        }
        let lower = comment.text.lowercased()
        if let link = resolvedLinks.first, lower.range(of: #"^(open|go to|show me|pull up|打开)\b"#, options: .regularExpression) != nil
            || lower.hasPrefix("打开") {
            out.append(.open(link.relativePath, nil))
        }
        return out
    }

    private static func anchored(_ file: FileRef, _ anchor: FileAnchor?) -> String {
        anchor.map { file.relativePath + "#" + $0.label } ?? file.relativePath
    }
}
