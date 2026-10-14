import Foundation

/// Turns what a person types into a safe FTS5 query.
///
/// `pricing model` → `"pricing" "model"*` (all terms, last one a prefix while typing),
/// `"gross margin" q3` → `"gross margin" "q3"*`. Every term is quoted, so FTS5 syntax
/// characters in the input are just text. A trailing space or closing quote ends the
/// word: no prefix. An unclosed quote is a phrase still being typed.
enum FTSQuery {
    struct Term: Equatable {
        var text: String
        var phrase: Bool
    }

    static func terms(_ input: String) -> [Term] {
        var out: [Term] = []
        var word = ""
        var inQuote = false
        func flush(phrase: Bool) {
            let t = word.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
                out.append(Term(text: t, phrase: phrase))
            }
            word = ""
        }
        for ch in input {
            if ch == "\"" {
                flush(phrase: inQuote)
                inQuote.toggle()
            } else if !inQuote, ch.isWhitespace {
                flush(phrase: false)
            } else {
                word.append(ch)
            }
        }
        flush(phrase: inQuote)
        return out
    }

    /// `nil` when the input has nothing searchable. `any` joins terms with OR instead of AND.
    static func build(_ input: String, any: Bool = false) -> String? {
        let ts = terms(input)
        guard !ts.isEmpty else { return nil }
        let typingLastWord = !(input.last?.isWhitespace ?? true) && input.last != "\""
        let parts = ts.enumerated().map { i, t -> String in
            let quoted = "\"" + t.text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let isLast = i == ts.count - 1
            return quoted + (isLast && typingLastWord ? "*" : "")
        }
        return parts.joined(separator: any ? " OR " : " ")
    }
}
