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
            } else if ch.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) {
                flush(phrase: inQuote)   // NUL and friends would end the string early in SQLite
            } else if !inQuote, ch.isWhitespace {
                flush(phrase: false)
            } else {
                word.append(ch)
            }
        }
        flush(phrase: inQuote)
        return out
    }

    /// True when the input uses a script written without spaces between words (Han, kana,
    /// Thai, Lao, Khmer, Myanmar) or Hangul, where a query word is often part of a longer token.
    static func isUnspaced(_ input: String) -> Bool {
        input.unicodeScalars.contains { s in
            switch s.value {
            case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF, 0x3040...0x30FF, 0x3400...0x4DBF,
                 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return true
            default: return false
            }
        }
    }

    /// `nil` when the input has nothing searchable. `any` joins terms with OR instead of AND.
    static func build(_ input: String, any: Bool = false) -> String? {
        let ts = terms(input)
        guard !ts.isEmpty else { return nil }
        let typingLastWord = !(input.last?.isWhitespace ?? true) && input.last != "\""
        // A one-character prefix (`a*`) matches half the vocabulary and is slow; wait for two.
        let lastToken = ts.last!.text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).last ?? ""
        let prefix = typingLastWord && lastToken.count >= 2
        let parts = ts.enumerated().map { i, t -> String in
            let quoted = "\"" + t.text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            return quoted + (i == ts.count - 1 && prefix ? "*" : "")
        }
        return parts.joined(separator: any ? " OR " : " ")
    }
}
