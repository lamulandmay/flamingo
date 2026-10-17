import Foundation
import FlamingoCore
import FlamingoIndex

// Chat may use a remote provider (Claude) for questions about files. It may not carry a
// thought there. Before anything goes to a provider that is not on this Mac, thoughts are
// removed from what it would read: thought passages, sections that came from a thought hit,
// and turns of the conversation that quote or were drawn from one.

/// A source with every thought taken out. Retrieval over it can only find file text.
struct ThoughtBlindSource: PassageSource {
    let base: PassageSource
    var vault: Vault { base.vault }

    func files() -> [FileRef] { base.files() }
    func sections(of ref: FileRef) throws -> [SourceSection] { try base.sections(of: ref) }
    func text(of ref: FileRef) throws -> String? { try base.text(of: ref) }
    func comments(on ref: FileRef) throws -> [Comment] { [] }
    func searchComments(_ query: String, limit: Int) throws -> [CommentHit] { [] }

    /// A semantic thought hit arrives in the section results with a `commentID`. It is dropped
    /// here, and the list is asked for extra so file sections still fill the limit.
    func searchSections(_ query: String, limit: Int) throws -> [SearchHit] {
        Array(try base.searchSections(query, limit: limit * 2).filter { $0.commentID == nil }.prefix(limit))
    }
}

enum ThoughtPrivacy {
    /// True for a source that is scoped to chosen files, looking through the privacy wrapper.
    static func isScoped(_ source: PassageSource) -> Bool {
        if let blind = source as? ThoughtBlindSource { return isScoped(blind.base) }
        return source is ScopedPassageSource
    }

    /// Passages with every thought removed.
    static func withoutThoughts(_ passages: [Passage]) -> [Passage] {
        passages.filter { $0.kind != .comment && $0.commentID == nil }
    }

    /// The conversation without the turns that carry a thought: those marked as drawn from
    /// thoughts, and those whose question or answer repeats a stretch of a thought `source`
    /// can find for them. A paraphrase of a thought can't be told apart, which is why a turn
    /// that cited a thought should be marked (`ConversationTurn.thoughtDerived`).
    static func scrub(_ history: [ConversationTurn], against source: PassageSource) -> [ConversationTurn] {
        history.filter { turn in
            if turn.thoughtDerived { return false }
            let text = compact(turn.question + " " + turn.answer)
            guard !text.isEmpty else { return true }
            let probe = turn.question + " " + String(turn.answer.prefix(400))
            var candidates: [Comment] = []
            for query in QueryPlan.queries(for: probe).prefix(3) {
                candidates += ((try? source.searchComments(query.text, limit: 25)) ?? []).map(\.comment)
            }
            let plain = turn.question + " " + turn.answer
            return !candidates.contains { quotes($0.text, in: text) || restates($0.text, in: plain) }
        }
    }

    /// Whether `plain` says most of what the thought says in other words: at least four of the
    /// thought's content words (links left out), and seven tenths of them, appear. Errs toward
    /// dropping a turn.
    static func restates(_ thought: String, in plain: String) -> Bool {
        let words = ThoughtRules.prose(of: thought).replacingOccurrences(of: #"!?\[\[[^\]]*\]\]"#, with: " ", options: .regularExpression)
        let terms = QueryPlan.terms(words)
        guard terms.count >= 4 else { return false }
        return Double(Retriever.matchCount(terms, in: plain)) / Double(terms.count) >= 0.7
    }

    /// Letters and digits only, lowercased: survives spacing, case and punctuation changes.
    static func compact(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Whether `haystack` (already compact) repeats a run of the thought's words.
    static func quotes(_ thought: String, in haystack: String) -> Bool {
        let prose = ThoughtRules.prose(of: thought)
        for piece in [prose] + prose.split(whereSeparator: \.isNewline).map(String.init) + sentences(prose) {
            let needle = compact(piece)
            if needle.count >= 12, needle.count <= 24 { if haystack.contains(needle) { return true } }
            else if needle.count > 24 {
                let chars = Array(needle)
                var i = 0
                while i + 24 <= chars.count {
                    if haystack.contains(String(chars[i..<(i + 24)])) { return true }
                    i += 2
                }
            }
        }
        return false
    }

    private static func sentences(_ text: String) -> [String] {
        text.split(whereSeparator: { ".?!。？！\n".contains($0) }).map(String.init)
    }
}
