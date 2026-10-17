import Foundation

/// How much a thought gives its project, read from its words alone so the moment of saving
/// can show it. A spark is a quick dump; a solid thought says something specific or names
/// another file; a woven one links another file and says why. Deterministic and instant;
/// never stored, because the text is the source of truth.
public enum ThoughtStrength: Int, Comparable, CaseIterable, Sendable {
    case spark, solid, woven

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public init(_ comment: Comment) { self.init(text: comment.text) }

    public init(text: String) {
        let links = Set(Wikilink.parse(text).map { Wikilink.components(of: $0).target.lowercased() }).count
        let points = Self.points(text: text, links: links)
        if links > 0, points >= 4 { self = .woven }
        else if points >= 2 { self = .solid }
        else { self = .spark }
    }

    /// A link is worth 2 and a second one 1. Then 1 each for 8 words, 25 words, a reason
    /// (because, but, should, 因为…), a specific (a number, a date, a price) and some structure
    /// (two sentences or two lines). Links count as one word and never as a specific.
    static func points(text: String, links: Int) -> Int {
        let prose = text.replacingOccurrences(of: #"!?\[\[[^\]]*\]\]"#, with: "link", options: .regularExpression)
        var points = 0
        if links > 0 { points += 2 }
        if links > 1 { points += 1 }
        let words = wordCount(prose)
        if words >= 8 { points += 1 }
        if words >= 25 { points += 1 }
        if hasReason(prose) { points += 1 }
        if prose.contains(where: \.isNumber) { points += 1 }
        if sentenceCount(prose) >= 2 { points += 1 }
        return points
    }

    /// Space-separated words, plus one per two CJK characters (those scripts don't space words).
    static func wordCount(_ text: String) -> Int {
        var cjk = 0
        for s in text.unicodeScalars where isCJK(s) { cjk += 1 }
        let spaced = text.split(whereSeparator: \.isWhitespace).filter { token in
            token.unicodeScalars.contains { !isCJK($0) && CharacterSet.alphanumerics.contains($0) }
        }.count
        return spaced + cjk / 2
    }

    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF: true
        default: false
        }
    }

    private static let reasonWords: Set<String> = [
        "because", "since", "so", "therefore", "thus", "hence", "but", "however", "although", "though",
        "instead", "unless", "otherwise", "rather", "if", "why", "contradicts", "contradict", "conflicts",
        "means", "implies", "should", "must", "need", "needs", "vs", "versus",
    ]
    private static let reasonMarks = ["→", "->", "=>", "≠", "因为", "所以", "但是", "可是", "因此", "应该", "需要",
                                      "如果", "而不是", "否则", "为什么"]

    static func hasReason(_ text: String) -> Bool {
        let lower = text.lowercased()
        if reasonMarks.contains(where: { lower.contains($0) }) { return true }
        return lower.split(whereSeparator: { !$0.isLetter }).contains { reasonWords.contains(String($0)) }
    }

    /// Runs of at least three characters between sentence ends or line breaks.
    static func sentenceCount(_ text: String) -> Int {
        text.split(whereSeparator: { ".?!。？！\n".contains($0) })
            .filter { $0.trimmingCharacters(in: .whitespaces).count >= 3 }
            .count
    }
}
