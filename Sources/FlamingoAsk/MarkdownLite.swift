import AppKit
import SwiftUI
import FlamingoCore
import FlamingoDesign

extension NSAttributedString.Key {
    /// Passage number of an inline `[n]` citation. Value: `Int`.
    static let flamingoCitation = NSAttributedString.Key("flamingoCitation")
}

/// The subset of markdown an answer uses: paragraphs, bullets, bold, italic, inline code,
/// and `[n]` citations. Rendered for an `NSTextView`.
enum MarkdownLite {
    // Mirror Theme.Font.body (13pt) and Theme.Font.mono (12pt); Theme has no NSFont tokens.
    static let bodySize: CGFloat = 13
    static let codeSize: CGFloat = 12
    static let lineHeight: CGFloat = 17

    static func render(_ markdown: String, sources: [Int: Citation], streaming: Bool) -> NSAttributedString {
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        if streaming { text = trimPartialTail(text) }
        let blocks = parseBlocks(text)
        let out = NSMutableAttributedString()
        for (i, block) in blocks.enumerated() {
            let isLast = i == blocks.count - 1
            let start = out.length
            let style: NSParagraphStyle
            switch block {
            case .paragraph(let s):
                out.append(inline(s, sources: sources, streaming: streaming, bold: false))
                style = paragraphStyle(spacing: isLast ? 0 : Theme.Space.s)
            case .heading(let s):
                out.append(inline(s, sources: sources, streaming: streaming, bold: true))
                style = paragraphStyle(spacing: isLast ? 0 : Theme.Space.s)
            case .item(let marker, let ordered, let level, let s):
                out.append(NSAttributedString(string: marker + "\t", attributes: [
                    .font: NSFont.systemFont(ofSize: bodySize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
                out.append(inline(s, sources: sources, streaming: streaming, bold: false))
                let nextIsItem: Bool
                if !isLast, case .item = blocks[i + 1] { nextIsItem = true } else { nextIsItem = false }
                let lead = CGFloat(level) * Theme.Space.l
                let width = ordered ? Theme.Space.xl : Theme.Space.l
                style = paragraphStyle(spacing: isLast ? 0 : (nextIsItem ? Theme.Space.xs : Theme.Space.s),
                                       firstIndent: lead, indent: lead + width)
            }
            if !isLast {
                out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: bodySize)]))
            }
            out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: out.length - start))
        }
        return out
    }

    // MARK: Blocks

    enum Block: Equatable {
        case paragraph(String)
        case heading(String)
        case item(marker: String, ordered: Bool, level: Int, text: String)
    }

    static func parseBlocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var para: [String] = []
        var lastWasBlank = true
        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\u{2028}"))); para = [] }
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { lastWasBlank = trimmed.isEmpty }
            if trimmed.isEmpty { flush(); continue }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            if let item = listItem(trimmed) {
                flush()
                blocks.append(.item(marker: item.marker, ordered: item.ordered, level: min(indent / 2, 2), text: item.text))
                continue
            }
            if trimmed.hasPrefix("#") {
                let rest = trimmed.drop { $0 == "#" }
                if rest.isEmpty || rest.first == " " {
                    flush()
                    let title = rest.trimmingCharacters(in: .whitespaces)
                    if !title.isEmpty { blocks.append(.heading(title)) }
                    continue
                }
            }
            if para.isEmpty, !lastWasBlank, case .item(let m, let o, let l, let t)? = blocks.last {
                blocks[blocks.count - 1] = .item(marker: m, ordered: o, level: l,
                                                 text: t.isEmpty ? trimmed : t + "\u{2028}" + trimmed)
                continue
            }
            para.append(trimmed)
        }
        flush()
        return blocks
    }

    /// `- x`, `* x`, `+ x`, `• x`, `1. x`, `2) x`. A lone marker is an item still being written.
    static func listItem(_ line: String) -> (marker: String, ordered: Bool, text: String)? {
        let chars = Array(line)
        guard let first = chars.first else { return nil }
        if "-*+•".contains(first) {
            if chars.count == 1 { return ("•", false, "") }
            if chars[1] == " " { return ("•", false, String(chars[2...]).trimmingCharacters(in: .whitespaces)) }
            return nil
        }
        let digits = chars.prefix { $0.isASCII && $0.isNumber }
        guard (1...3).contains(digits.count), digits.count < chars.count else { return nil }
        let delim = chars[digits.count]
        guard delim == "." || delim == ")" else { return nil }
        let marker = String(digits) + String(delim)
        if chars.count == digits.count + 1 { return (marker, true, "") }
        guard chars[digits.count + 1] == " " else { return nil }
        return (marker, true, String(chars[(digits.count + 2)...]).trimmingCharacters(in: .whitespaces))
    }

    /// While streaming, drop what would otherwise flash and then change: a half-written
    /// citation (`[`, `[1`, `[1,`) or a lone `*` that is about to become `**` or an emphasis.
    static func trimPartialTail(_ text: String) -> String {
        var t = text
        if let r = t.range(of: #"\[\[?[\d,\s]*$"#, options: .regularExpression) { t.removeSubrange(r) }
        if t.hasSuffix("*"), !t.hasSuffix("**"), loneStarCount(t) % 2 == 1 { t.removeLast() }
        return t
    }

    private static func loneStarCount(_ s: String) -> Int {
        let c = Array(s)
        var i = 0, count = 0
        while i < c.count {
            if c[i] == "*" {
                if i + 1 < c.count, c[i + 1] == "*" { i += 2; continue }
                count += 1
            }
            i += 1
        }
        return count
    }

    // MARK: Inline

    static func inline(_ s: String, sources: [Int: Citation], streaming: Bool, bold baseBold: Bool) -> NSAttributedString {
        let chars = Array(s)
        let n = chars.count
        let out = NSMutableAttributedString()
        var buf = ""
        var bold = false
        var italic: Character?
        var code = false

        func font() -> NSFont {
            if code { return NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular) }
            var f = NSFont.systemFont(ofSize: bodySize, weight: (bold || baseBold) ? .semibold : .regular)
            if italic != nil { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
            return f
        }
        func attrs() -> [NSAttributedString.Key: Any] {
            [.font: font(), .foregroundColor: code ? NSColor.secondaryLabelColor : NSColor.labelColor]
        }
        func flush() {
            if !buf.isEmpty { out.append(NSAttributedString(string: buf, attributes: attrs())); buf = "" }
        }
        func starts(_ seq: String, at i: Int) -> Bool {
            let q = Array(seq)
            guard i + q.count <= n else { return false }
            return Array(chars[i..<(i + q.count)]) == q
        }
        func find(_ seq: String, from i: Int) -> Int? {
            var k = i
            while k < n { if starts(seq, at: k) { return k }; k += 1 }
            return nil
        }
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        func closesItalic(_ d: Character, at k: Int) -> Bool {
            guard chars[k] == d, k > 0, !chars[k - 1].isWhitespace else { return false }
            if d == "*" { return !(k + 1 < n && chars[k + 1] == "*") && chars[k - 1] != "*" }
            return !(k + 1 < n && isWord(chars[k + 1]))
        }
        func appendCitation(_ nums: [Int]) {
            let f = font()
            let accent = NSColor(Theme.Color.accent)
            func plain(_ t: String, _ color: NSColor) {
                out.append(NSAttributedString(string: t, attributes: [.font: f, .foregroundColor: color]))
            }
            func linked(_ t: String, _ num: Int) {
                var a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: accent, .flamingoCitation: num]
                if let url = URL(string: "flamingo-cite:\(num)") { a[.link] = url }
                out.append(NSAttributedString(string: t, attributes: a))
            }
            if nums.count == 1 {
                if sources[nums[0]] != nil { linked("[\(nums[0])]", nums[0]) } else { plain("[\(nums[0])]", .tertiaryLabelColor) }
                return
            }
            let frame: NSColor = nums.contains { sources[$0] != nil } ? accent : .tertiaryLabelColor
            plain("[", frame)
            for (k, num) in nums.enumerated() {
                if k > 0 { plain(", ", frame) }
                if sources[num] != nil { linked("\(num)", num) } else { plain("\(num)", .tertiaryLabelColor) }
            }
            plain("]", frame)
        }
        /// `[3]`, `[2, 5]`, `[2,5]` not followed by `(` (a markdown link). Returns the numbers and the index past `]`.
        func citationGroup(at i: Int) -> ([Int], Int)? {
            var j = i + 1
            var nums: [Int] = []
            while true {
                while j < n, chars[j] == " " { j += 1 }
                var digits = ""
                while j < n, chars[j].isASCII, chars[j].isNumber, digits.count < 4 { digits.append(chars[j]); j += 1 }
                guard let num = Int(digits) else { return nil }
                nums.append(num)
                while j < n, chars[j] == " " { j += 1 }
                guard j < n else { return nil }
                if chars[j] == "," { j += 1; continue }
                guard chars[j] == "]" else { return nil }
                j += 1
                if j < n, chars[j] == "(" { return nil }
                return (nums, j)
            }
        }

        var i = 0
        while i < n {
            let c = chars[i]
            if code {
                if c == "`" { flush(); code = false } else { buf.append(c) }
                i += 1
                continue
            }
            if c == "`" {
                if streaming || find("`", from: i + 1) != nil { flush(); code = true } else { buf.append(c) }
                i += 1
                continue
            }
            if starts("**", at: i) {
                if bold { flush(); bold = false }
                else if streaming || find("**", from: i + 2) != nil { flush(); bold = true }
                else { buf.append("**") }
                i += 2
                continue
            }
            if c == "*" || c == "_" {
                if let d = italic, closesItalic(d, at: i) {
                    flush(); italic = nil; i += 1; continue
                }
                if italic == nil, i + 1 < n, !chars[i + 1].isWhitespace,
                   c == "*" || i == 0 || !isWord(chars[i - 1]),
                   (i + 1..<n).contains(where: { closesItalic(c, at: $0) }) {
                    flush(); italic = c; i += 1; continue
                }
                buf.append(c); i += 1
                continue
            }
            if c == "[" {
                if starts("[[", at: i) {
                    if let end = find("]]", from: i + 2) {
                        buf.append(contentsOf: chars[i..<(end + 2)]); i = end + 2
                    } else {
                        buf.append("[["); i += 2
                    }
                    continue
                }
                if let (nums, end) = citationGroup(at: i) {
                    flush(); appendCitation(nums); i = end
                    continue
                }
            }
            buf.append(c); i += 1
        }
        flush()
        return out
    }

    // MARK: Paragraphs

    static func paragraphStyle(spacing: CGFloat, firstIndent: CGFloat = 0, indent: CGFloat = 0) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lineHeight
        p.maximumLineHeight = lineHeight
        p.paragraphSpacing = spacing
        p.firstLineHeadIndent = firstIndent
        p.headIndent = indent
        if indent > firstIndent {
            p.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            p.defaultTabInterval = indent
        }
        p.lineBreakMode = .byWordWrapping
        return p
    }
}
