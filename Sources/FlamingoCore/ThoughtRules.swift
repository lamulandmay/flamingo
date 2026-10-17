import Foundation

/// What the rules make of a thought's words: instant, deterministic, no model, and
/// recomputed from the text whenever it is needed (never stored), so improving the rules
/// improves every thought without rewriting a note.
public struct ThoughtReading: Hashable, Sendable {
    public var kind: ThoughtKind
    /// A date the words name, for a question, to do or intent (or any thought that says "due").
    public var due: ParsedDue?
    /// `ai` and `flamingo` for each `@ai` / `@flamingo` in the text, in order, without repeats.
    public var mentions: [String]
    /// The work recipe the words ask for (`review-conflict`, `compare-versions`, `summarize`,
    /// `find-related`, `answer`), when they ask for one.
    public var recipe: String?
    /// Whether the text names a file or an anchor (`[[...]]`, `slide 7`, `report.pdf`).
    public var refersToFiles: Bool

    public var mentionsAssistant: Bool { !mentions.isEmpty }
}

public enum ThoughtRules {
    /// The thought's own words: quote lines (selected text from another app) are not what
    /// the person said, so they are left out, as are `@ai` / `@flamingo` mentions.
    public static func prose(of text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix(">") }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: #"(?<![\w@])@(?:ai|flamingo)\b"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func read(_ text: String, at timestamp: Date, calendar: Calendar = .current) -> ThoughtReading {
        let words = prose(of: text)
        let lower = words.lowercased()
        let kind = self.kind(of: words, lower: lower)
        let refers = refersToFiles(lower)
        var mentions: [String] = []
        for m in DueParser.matches(#"(?<![\w@])@(ai|flamingo)\b"#, in: text.lowercased()) {
            let name = (text.lowercased() as NSString).substring(with: m.result.range(at: 1))
            if !mentions.contains(name) { mentions.append(name) }
        }
        var due = DueParser.parse(words, relativeTo: timestamp, calendar: calendar)
        if kind == .idea, !hasDeadlineCue(lower) { due = nil }
        return ThoughtReading(kind: kind, due: due, mentions: mentions, recipe: recipe(lower, kind: kind, refers: refers), refersToFiles: refers)
    }

    // MARK: Kind

    /// `[[q3-board-review.pptx#slide 7]]` is a reference, not words: "review" inside a file name is no verb.
    static func bare(_ lower: String) -> String {
        lower.replacingOccurrences(of: #"!?\[\[[^\]]*\]\]"#, with: " ◻ ", options: .regularExpression)
    }

    static func kind(of words: String, lower: String) -> ThoughtKind {
        guard !lower.isEmpty else { return .idea }
        let text = bare(lower)
        if isStrongQuestion(text) { return .question }
        if isIntent(text, refers: refersToFiles(lower)) { return .intent }
        if isWeakQuestion(text) { return .question }
        if isTodo(text) { return .todo }
        return .idea
    }

    private static func trimmedEnd(_ lower: String) -> String {
        var s = Substring(lower)
        while let last = s.last, last.isWhitespace || "\"')]}”’*_`".contains(last) { s = s.dropLast() }
        return String(s)
    }

    static func isStrongQuestion(_ lower: String) -> Bool {
        let end = trimmedEnd(lower)
        if end.hasSuffix("?") || end.hasSuffix("？") { return true }
        return lower.contains("吗") || lower.contains("为什么") || lower.contains("為什麼")
    }

    private static let interrogatives: Set<String> = ["what", "why", "how", "when", "where", "who", "whom", "whose", "which", "whether"]
    private static let auxiliaries: Set<String> = ["is", "are", "was", "were", "should", "could", "can", "would", "will", "does", "did", "shall", "isn't", "aren't", "doesn't"]

    static func isWeakQuestion(_ lower: String) -> Bool {
        for marker in ["怎么办", "怎么样", "怎么", "如何", "是否", "为何", "什么时候", "哪个", "哪些"] where lower.contains(marker) { return true }
        let first = clauses(lower).first.flatMap(firstWord) ?? ""
        if interrogatives.contains(first) { return true }
        if auxiliaries.contains(first) {
            // "Should we ...", "Can you ..." read as questions; a long run-on is more likely a statement.
            return lower.split(whereSeparator: \.isWhitespace).count <= 20
        }
        return false
    }

    private static let intentVerbs = #"\b(review|compare|reconcile|summari[sz]e|check|cross-check|double-check|verify|find|research|draft|audit|validate|investigate|analy[sz]e|diff)\b|审查|审阅|核对|核实|检查|比较|对比|总结|整理|调研|调查|确认一下|查一下|看一下"#
    private static let conflictWording = #"conflict|contradict|inconsisten|mismatch|disagree|discrepan|out of sync|versions?\b|矛盾|冲突|不一致|差异|版本"#

    static func isIntent(_ lower: String, refers: Bool) -> Bool {
        guard !DueParser.matches(intentVerbs, in: lower).isEmpty else { return false }
        return refers || lower.range(of: conflictWording, options: .regularExpression) != nil
    }

    static func refersToFiles(_ lower: String) -> Bool {
        lower.contains("[[") || lower.range(of: #"\b(slide|page|sheet|cell|line|node)s? [\w!$:]+|\b[\w-]+\.(xlsx|xls|pptx|ppt|docx|doc|pdf|key|numbers|pages|csv|md|txt|png|jpe?g|mp4|m4a|usdz|py|swift)\b"#, options: .regularExpression) != nil
    }

    private static let imperatives: Set<String> = [
        "say", "name", "cut", "put", "send", "fix", "update", "add", "remove", "call", "email", "link", "follow", "move", "read",
        "keep", "pull", "change", "make", "ask", "tell", "write", "set", "rename", "delete", "drop", "finish", "ship", "buy", "book",
        "schedule", "order", "pay", "reply", "respond", "share", "upload", "download", "close", "merge", "split", "create", "build",
        "test", "run", "install", "clean", "prepare", "plan", "confirm", "decide", "pick", "choose", "get", "take", "bring", "give",
        "show", "print", "sign", "submit", "file", "cancel", "notify", "remind", "review", "compare", "check", "verify", "find",
        "research", "draft", "summarize", "summarise", "reconcile", "cite", "include", "mention", "list", "use", "try", "start",
        "stop", "go", "attach", "approve", "escalate", "ping", "text", "message", "double-check", "cross-check", "revisit", "figure",
    ]

    static func isTodo(_ lower: String) -> Bool {
        let cues = #"\b(need to|needs to|have to|has to|had to|must|remember to|don'?t forget|do not forget|todo|to-do|gotta|got to|make sure|should (?:say|cite|include|mention|list|add|use|link|move|read|show|name|go through)|ought to)\b|记得|别忘|不要忘|需要|必须|提醒我|待办|要记得"#
        if lower.range(of: cues, options: .regularExpression) != nil { return true }
        for clause in clauses(lower) {
            guard let first = firstWord(clause) else { continue }
            if imperatives.contains(first) { return true }
            // Chinese verbs open a clause without a space after them.
            for verb in ["联系", "修改", "更新", "添加", "删除", "发送", "回复", "完成", "提交", "预订", "购买", "安排", "改成", "改为"] where clause.hasPrefix(verb) { return true }
        }
        return false
    }

    private static let fillers: Set<String> = ["please", "pls", "also", "and", "then", "ok", "okay", "so", "just", "maybe", "to", "now", "first", "next", "later", "todo:", "-"]

    /// Pieces of a thought that each start a new instruction: split at sentence ends,
    /// commas, semicolons, colons, line breaks, and " and " / " then ".
    static func clauses(_ lower: String) -> [String] {
        let separators = CharacterSet(charactersIn: ".!?;:,\n。！？；：，")
        var out: [String] = []
        for piece in lower.components(separatedBy: separators) {
            for part in piece.replacingOccurrences(of: " and ", with: "\u{1}").replacingOccurrences(of: " then ", with: "\u{1}").components(separatedBy: "\u{1}") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { out.append(trimmed) }
            }
        }
        return out
    }

    /// The first word that is not a filler ("please", "also", "and"…), with edge punctuation removed.
    static func firstWord(_ clause: String) -> String? {
        for token in clause.split(whereSeparator: \.isWhitespace) {
            let word = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'([{*_`•-–—#"))
            if word.isEmpty || fillers.contains(word) { continue }
            return word
        }
        return nil
    }

    // MARK: Due and recipe

    static func hasDeadlineCue(_ lower: String) -> Bool {
        lower.range(of: #"\b(due|deadline|remind|reminder)\b|截止|提醒"#, options: .regularExpression) != nil
    }

    static func recipe(_ original: String, kind: ThoughtKind, refers: Bool) -> String? {
        let lower = bare(original)
        let has = { (pattern: String) in lower.range(of: pattern, options: .regularExpression) != nil }
        if kind == .intent || has(intentVerbs) {
            if has(#"conflict|contradict|inconsisten|mismatch|disagree|discrepan|out of sync|矛盾|冲突|不一致|差异"#) { return "review-conflict" }
            if has(#"\bcompare\b|\bdiff\b|versions?\b|对比|比较|版本"#) { return "compare-versions" }
            if has(#"summari[sz]e|tl;?dr|总结|整理"#) { return "summarize" }
            if has(#"\b(find|research|related)\b|调研|调查"#) { return "find-related" }
            if has(#"\b(review|reconcile|check|verify|audit|validate|cross-check|double-check)\b|审查|审阅|核对|核实|检查|确认一下"#) { return refers ? "review-conflict" : nil }
        }
        if kind == .question, refers { return "answer" }
        return nil
    }
}
