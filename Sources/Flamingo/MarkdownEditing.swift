import Foundation

/// Markdown as the editor sees it, a line at a time: the quote, list and heading prefix, and
/// the inline spans after it. Offsets are UTF-16, as NSTextView's.
enum MarkdownSyntax {
    struct Line: Equatable {
        /// Without its line break.
        var range: NSRange
        /// `> ` prefixes at the start; empty when there are none.
        var quote: NSRange
        /// Spaces and tabs before a list marker or the text.
        var indent: NSRange
        /// `-`, `*`, `+`, `12.` or `12)`.
        var marker: NSRange?
        var number: Int?
        /// `[ ]` or `[x]`.
        var checkbox: NSRange?
        /// `#` to `######`.
        var heading: Int?
        /// Everything after the prefix.
        var content: NSRange

        var isBlank: Bool { content.length == 0 }
    }

    struct Span: Equatable {
        enum Kind { case strong, emphasis, strongEmphasis, underline, strike, code, link, wikilink, url }
        var kind: Kind
        /// With its markers.
        var range: NSRange
        var content: NSRange

        var markers: [NSRange] {
            [NSRange(location: range.location, length: content.location - range.location),
             NSRange(location: NSMaxRange(content), length: NSMaxRange(range) - NSMaxRange(content))]
        }
    }

    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    // Groups: quote, indent, marker, number, checkbox (with its spaces), heading.
    private static let prefix = re(#"((?:[ \t]{0,3}>[ \t]?)*)([ \t]*)(?:([-*+]|(\d{1,9})[.)])[ \t]+(\[[ xX]\](?:[ \t]+|$))?|(#{1,6})(?:[ \t]+|$))?"#)

    static func line(in ns: NSString, at location: Int) -> Line {
        var start = 0, contentsEnd = 0
        ns.getLineStart(&start, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: min(max(location, 0), ns.length), length: 0))
        return parse(ns, NSRange(location: start, length: contentsEnd - start))
    }

    /// Every line the range touches; a range ending at a line's start leaves that line out.
    static func lines(in ns: NSString, _ range: NSRange) -> [Line] {
        var lines: [Line] = [], position = range.location
        while true {
            let line = line(in: ns, at: position)
            lines.append(line)
            let next = NSMaxRange(ns.lineRange(for: NSRange(location: line.range.location, length: 0)))
            guard next > position, next < NSMaxRange(range) else { return lines }
            position = next
        }
    }

    static func parse(_ ns: NSString, _ range: NSRange) -> Line {
        let empty = NSRange(location: range.location, length: 0)
        guard let m = prefix.firstMatch(in: ns as String, options: .anchored, range: range) else {
            return Line(range: range, quote: empty, indent: empty, content: range)
        }
        func group(_ i: Int) -> NSRange? { let r = m.range(at: i); return r.location == NSNotFound ? nil : r }
        let end = NSMaxRange(m.range)
        return Line(range: range, quote: group(1) ?? empty, indent: group(2) ?? empty, marker: group(3),
                    number: group(4).flatMap { Int(ns.substring(with: $0)) },
                    checkbox: group(5).map { NSRange(location: $0.location, length: 3) },
                    heading: group(6)?.length,
                    content: NSRange(location: end, length: NSMaxRange(range) - end))
    }

    private static let codeSpan = re(#"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private static let wikilink = re(#"!?\[\[([^\[\]\n]+)\]\]"#)
    private static let link = re(#"!?\[([^\[\]\n]*)\]\([^()\n]*\)"#)
    private static let url = re(#"\bhttps?://[^\s<>()\[\]]*[^\s<>()\[\].,;:!?'"]"#)
    private static let underline = re(#"<u>(.+?)</u>"#, .caseInsensitive)
    private static let strike = re(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let emphasis: [(NSRegularExpression, Span.Kind, Int)] = [
        (re(#"(?<![*\\])\*\*\*(?![\s*])(.+?)(?<![\s*\\])\*\*\*(?!\*)|(?<![_\w\\])___(?![\s_])(.+?)(?<![\s_\\])___(?![_\w])"#), .strongEmphasis, 3),
        (re(#"(?<![*\\])\*\*(?![\s*])(.+?)(?<![\s\\])\*\*(?!\*)|(?<![_\w\\])__(?![\s_])(.+?)(?<![\s\\])__(?![_\w])"#), .strong, 2),
        (re(#"(?<![*\\])\*(?![\s*])(.+?)(?<![\s*\\])\*(?!\*)|(?<![_\w\\])_(?![\s_])(.+?)(?<![\s_\\])_(?![_\w])"#), .emphasis, 1),
    ]

    /// Inline spans in one line's text. Code, wikilinks and URLs shield what's inside them;
    /// `***` is taken before `**`, and `**` before `*`.
    static func spans(in ns: NSString, _ range: NSRange) -> [Span] {
        let text = ns as String
        var spans: [Span] = [], shielded: [NSRange] = [], taken: [NSRange] = []
        func overlaps(_ r: NSRange, _ zones: [NSRange]) -> Bool { zones.contains { NSIntersectionRange($0, r).length > 0 } }
        // A span may hold a shielded run whole, but not cut into one.
        func clear(_ r: NSRange) -> Bool {
            !shielded.contains { NSIntersectionRange($0, r).length > 0 && !(r.location <= $0.location && NSMaxRange($0) <= NSMaxRange(r)) }
        }
        func matches(_ re: NSRegularExpression) -> [NSTextCheckingResult] { re.matches(in: text, range: range) }
        for m in matches(codeSpan) {
            spans.append(Span(kind: .code, range: m.range, content: m.range(at: 2))); shielded.append(m.range)
        }
        for m in matches(wikilink) where !overlaps(m.range, shielded) {
            spans.append(Span(kind: .wikilink, range: m.range, content: m.range(at: 1))); shielded.append(m.range)
        }
        for m in matches(link) where !overlaps(m.range, shielded) {
            let label = m.range(at: 1)
            spans.append(Span(kind: .link, range: m.range, content: label))
            shielded.append(NSRange(location: NSMaxRange(label), length: NSMaxRange(m.range) - NSMaxRange(label)))
        }
        for m in matches(url) where !overlaps(m.range, shielded) {
            spans.append(Span(kind: .url, range: m.range, content: m.range)); shielded.append(m.range)
        }
        for m in matches(underline) where clear(m.range) { spans.append(Span(kind: .underline, range: m.range, content: m.range(at: 1))) }
        for m in matches(strike) where clear(m.range) { spans.append(Span(kind: .strike, range: m.range, content: m.range(at: 1))) }
        for (re, kind, n) in emphasis {
            for m in matches(re) {
                let content = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
                let markers = [NSRange(location: m.range.location, length: n), NSRange(location: NSMaxRange(m.range) - n, length: n)]
                guard clear(m.range), !markers.contains(where: { overlaps($0, taken) }) else { continue }
                spans.append(Span(kind: kind, range: m.range, content: content))
                taken += markers
            }
        }
        return spans
    }
}

/// One replacement, and where the selection goes after it (nil leaves it).
struct MarkdownEdit: Equatable {
    var range: NSRange
    var replacement: String
    var selection: NSRange?

    var changesText: Bool { range.length > 0 || !replacement.isEmpty }
}

/// What the Markdown editor's keys do to the text: lists that continue themselves, and
/// ⌘B / ⌘I / ⌘U. Pure functions of the text and the selection, so each can be tested.
enum MarkdownEditing {
    typealias Line = MarkdownSyntax.Line
    typealias Span = MarkdownSyntax.Span

    // MARK: Lists

    /// ↩ in a list item or a quote starts the next one, numbered on. In an empty item it steps
    /// out instead: up a level, then out of the list, then out of the quote.
    static func newline(in ns: NSString, selection: NSRange) -> MarkdownEdit? {
        let line = MarkdownSyntax.line(in: ns, at: selection.location)
        guard line.marker != nil || line.quote.length > 0, line.heading == nil,
              selection.location >= line.content.location, NSMaxRange(selection) <= NSMaxRange(line.range) else { return nil }
        if ns.substring(with: line.content).trimmingCharacters(in: .whitespaces).isEmpty {
            if line.marker != nil, line.indent.length > 0 { return outdent(line, in: ns, selection: selection) }
            let start = line.marker != nil ? line.indent.location : line.range.location
            return MarkdownEdit(range: NSRange(location: start, length: NSMaxRange(line.range) - start), replacement: "",
                                selection: NSRange(location: start, length: 0))
        }
        var next = ns.substring(with: line.quote) + ns.substring(with: line.indent)
        var parts: [(NSRange, String)] = []
        if let marker = line.marker {
            let text = ns.substring(with: marker)
            if let n = line.number {
                let delimiter = String(text.suffix(1))
                let siblings = followingSiblings(of: line, in: ns)
                // 1. 1. 1. stays that way; otherwise the items below count on.
                if let first = siblings.first, first.number == n {
                    next += "\(n)" + delimiter
                } else {
                    next += "\(n + 1)" + delimiter
                    for (i, sibling) in siblings.enumerated() where sibling.number != n + 2 + i {
                        let own = ns.substring(with: sibling.marker!).suffix(1)
                        parts.append((sibling.marker!, "\(n + 2 + i)" + own))
                    }
                }
            } else {
                next += text
            }
            let gapEnd = line.checkbox?.location ?? line.content.location
            next += ns.substring(with: NSRange(location: NSMaxRange(marker), length: gapEnd - NSMaxRange(marker)))
            if line.checkbox != nil { next += "[ ] " }
        }
        parts.insert((selection, "\n" + next), at: 0)
        let merged = merge(parts, in: ns)
        return MarkdownEdit(range: merged.range, replacement: merged.text,
                            selection: NSRange(location: selection.location + 1 + (next as NSString).length, length: 0))
    }

    /// ⌫ right after a list marker takes it off: a checkbox first, then the marker (or one
    /// level of indent). Right after `> `, the quote.
    static func deleteBackward(in ns: NSString, selection: NSRange) -> MarkdownEdit? {
        guard selection.length == 0 else { return nil }
        let line = MarkdownSyntax.line(in: ns, at: selection.location)
        guard line.heading == nil, selection.location == line.content.location, selection.location > line.range.location else { return nil }
        let start: Int
        if let box = line.checkbox {
            start = box.location
        } else if let marker = line.marker {
            if line.indent.length > 0 { return outdent(line, in: ns, selection: selection) }
            start = marker.location
        } else if line.quote.length > 0 {
            start = line.range.location
        } else {
            return nil
        }
        return MarkdownEdit(range: NSRange(location: start, length: line.content.location - start), replacement: "",
                            selection: NSRange(location: start, length: 0))
    }

    /// Tab and ⇧Tab on list items: every item the selection touches goes a level in, or out to
    /// its parent's indent. Nil when the selection doesn't start in a list.
    static func indent(in ns: NSString, selection: NSRange, outdent: Bool) -> MarkdownEdit? {
        let lines = MarkdownSyntax.lines(in: ns, selection)
        guard lines.first?.marker != nil else { return nil }
        var parts: [(NSRange, String)] = []
        for line in lines where line.marker != nil {
            if !outdent {
                parts.append((NSRange(location: line.indent.location, length: 0), "\t"))
            } else if line.indent.length > 0 {
                parts.append((line.indent, parentIndent(of: line, in: ns)))
            }
        }
        // ⇧Tab at the top level does nothing, rather than leaving the text view.
        guard !parts.isEmpty else { return MarkdownEdit(range: NSRange(location: selection.location, length: 0), replacement: "", selection: selection) }
        let merged = merge(parts, in: ns)
        let start = map(selection.location, parts), end = map(NSMaxRange(selection), parts)
        return MarkdownEdit(range: merged.range, replacement: merged.text, selection: NSRange(location: start, length: end - start))
    }

    /// A click on a checkbox ticks it, or unticks it.
    static func toggleCheckbox(in ns: NSString, at location: Int) -> MarkdownEdit? {
        guard let box = MarkdownSyntax.line(in: ns, at: location).checkbox else { return nil }
        let mark = NSRange(location: box.location + 1, length: 1)
        return MarkdownEdit(range: mark, replacement: ns.substring(with: mark) == " " ? "x" : " ", selection: nil)
    }

    private static func outdent(_ line: Line, in ns: NSString, selection: NSRange) -> MarkdownEdit {
        let parts = [(line.indent, parentIndent(of: line, in: ns))]
        let start = map(selection.location, parts)
        return MarkdownEdit(range: line.indent, replacement: parts[0].1,
                            selection: NSRange(location: start, length: map(NSMaxRange(selection), parts) - start))
    }

    /// The indent of the nearest item above with less of it, or none.
    private static func parentIndent(of line: Line, in ns: NSString) -> String {
        var position = line.range.location
        while position > 0 {
            let previous = MarkdownSyntax.line(in: ns, at: position - 1)
            position = previous.range.location
            if previous.marker == nil {
                if ns.substring(with: previous.range).trimmingCharacters(in: .whitespaces).isEmpty { continue }
                break
            }
            if previous.indent.length < line.indent.length { return ns.substring(with: previous.indent) }
        }
        return ""
    }

    /// Numbered items below this one at its level, past its children, until the list ends.
    private static func followingSiblings(of line: Line, in ns: NSString) -> [Line] {
        var siblings: [Line] = []
        var position = NSMaxRange(ns.lineRange(for: NSRange(location: line.range.location, length: 0)))
        while position < ns.length {
            let next = MarkdownSyntax.line(in: ns, at: position)
            guard next.marker != nil, next.quote.length == line.quote.length else { break }
            if next.indent.length == line.indent.length {
                guard next.number != nil else { break }
                siblings.append(next)
            } else if next.indent.length < line.indent.length {
                break
            }
            let end = NSMaxRange(ns.lineRange(for: NSRange(location: position, length: 0)))
            guard end > position else { break }
            position = end
        }
        return siblings
    }

    // MARK: Bold, italic, underline

    enum Inline: CaseIterable {
        case bold, italic, underline

        var open: String {
            switch self {
            case .bold: "**"
            case .italic: "*"
            case .underline: "<u>"
            }
        }
        var close: String { self == .underline ? "</u>" : open }

        func styles(_ kind: Span.Kind) -> Bool {
            switch self {
            case .bold: kind == .strong || kind == .strongEmphasis
            case .italic: kind == .emphasis || kind == .strongEmphasis
            case .underline: kind == .underline
            }
        }

        /// A span's markers once this style comes off it: none, or the other half of `***`.
        func remaining(_ span: Span, in ns: NSString) -> String {
            guard span.kind == .strongEmphasis else { return "" }
            let c = ns.substring(with: NSRange(location: span.range.location, length: 1))
            return self == .bold ? c : c + c
        }
    }

    /// ⌘B, ⌘I, ⌘U. A selection is wrapped, or unwrapped when it's already styled; spans it
    /// only partly covers merge into one. With no selection a caret touching a word styles the
    /// word, a caret in or beside a styled run unstyles it, and anywhere else an empty pair
    /// opens that the same key steps out of once it's typed in.
    static func toggle(_ style: Inline, in ns: NSString, selection: NSRange) -> MarkdownEdit {
        let segments = segments(of: selection, in: ns).map { segment in
            (segment, MarkdownSyntax.spans(in: ns, MarkdownSyntax.line(in: ns, at: segment.location).content).filter { style.styles($0.kind) })
        }
        guard !segments.isEmpty else { return toggle(style, in: ns, caret: NSMaxRange(selection)) }
        func covering(_ segment: NSRange, _ spans: [Span]) -> Span? {
            spans.first { $0.range == segment || (segment.location >= $0.content.location && NSMaxRange(segment) <= NSMaxRange($0.content)) }
        }
        let styled = segments.allSatisfy { covering($0.0, $0.1) != nil }
        var pieces: [(range: NSRange, text: String, selected: NSRange)] = []
        for (segment, spans) in segments {
            if styled, let span = covering(segment, spans) {
                let inner = span.range == segment ? span.content : segment
                let open = ns.substring(with: span.markers[0]), close = ns.substring(with: span.markers[1])
                let before = ns.substring(with: NSRange(location: span.content.location, length: inner.location - span.content.location))
                let after = ns.substring(with: NSRange(location: NSMaxRange(inner), length: NSMaxRange(span.content) - NSMaxRange(inner)))
                let rest = style.remaining(span, in: ns)
                var text = before.isEmpty ? "" : open + before + close
                let start = (text + rest).utf16.count
                text += rest + ns.substring(with: inner) + rest
                if !after.isEmpty { text += open + after + close }
                pieces.append((span.range, text, NSRange(location: start, length: inner.length)))
            } else if covering(segment, spans) != nil {
                pieces.append((NSRange(location: segment.location, length: 0), "", NSRange(location: 0, length: segment.length)))
            } else {
                let overlapping = spans.filter { NSIntersectionRange($0.range, segment).length > 0 }
                let union = overlapping.reduce(segment) { NSUnionRange($0, $1.range) }
                var inner = "", position = union.location
                for span in overlapping {
                    let rest = style.remaining(span, in: ns)
                    inner += ns.substring(with: NSRange(location: position, length: span.range.location - position))
                        + rest + ns.substring(with: span.content) + rest
                    position = NSMaxRange(span.range)
                }
                inner += ns.substring(with: NSRange(location: position, length: NSMaxRange(union) - position))
                pieces.append((union, style.open + inner + style.close, NSRange(location: style.open.utf16.count, length: inner.utf16.count)))
            }
        }
        let merged = merge(pieces.map { ($0.range, $0.text) }, in: ns)
        var delta = 0, start = 0, end = 0
        for (i, piece) in pieces.enumerated() {
            let at = piece.range.location + delta
            if i == 0 { start = at + piece.selected.location }
            end = at + NSMaxRange(piece.selected)
            delta += piece.text.utf16.count - piece.range.length
        }
        return MarkdownEdit(range: merged.range, replacement: merged.text, selection: NSRange(location: start, length: end - start))
    }

    private static func toggle(_ style: Inline, in ns: NSString, caret: Int) -> MarkdownEdit {
        let line = MarkdownSyntax.line(in: ns, at: caret)
        let open = style.open.utf16.count, close = style.close.utf16.count
        func text(_ location: Int, _ length: Int) -> String {
            guard location >= line.range.location, location + length <= NSMaxRange(line.range) else { return "" }
            return ns.substring(with: NSRange(location: location, length: length))
        }
        func star(_ location: Int) -> Bool { text(location, 1) == "*" }
        func move(_ location: Int) -> MarkdownEdit { MarkdownEdit(range: NSRange(location: caret, length: 0), replacement: "", selection: NSRange(location: location, length: 0)) }

        // `**|**`, as the key left it: take it back.
        if text(caret - open, open) == style.open, text(caret, close) == style.close,
           style == .underline || (!star(caret - open - 1) && !star(caret + close)) {
            return MarkdownEdit(range: NSRange(location: caret - open, length: open + close), replacement: "",
                                selection: NSRange(location: caret - open, length: 0))
        }
        let spans = MarkdownSyntax.spans(in: ns, line.content).filter { style.styles($0.kind) }
        if let span = spans.first(where: { $0.range.location <= caret && caret <= NSMaxRange($0.range) }) {
            if caret == NSMaxRange(span.content), span.content.length > 0 { return move(NSMaxRange(span.range)) }
            let rest = style.remaining(span, in: ns)
            let offset = min(max(caret, span.content.location), NSMaxRange(span.content)) - span.content.location
            return MarkdownEdit(range: span.range, replacement: rest + ns.substring(with: span.content) + rest,
                                selection: NSRange(location: span.range.location + rest.utf16.count + offset, length: 0))
        }
        // `**bold |**` doesn't parse with that space: step out and take the spaces along.
        if text(caret, close) == style.close, isOpen(style, ns.substring(with: NSRange(location: line.content.location, length: caret - line.content.location))) {
            var start = caret
            while start > line.content.location, text(start - 1, 1) == " " { start -= 1 }
            guard start < caret else { return move(caret + close) }
            let spaces = String(repeating: " ", count: caret - start)
            return MarkdownEdit(range: NSRange(location: start, length: caret - start + close), replacement: style.close + spaces,
                                selection: NSRange(location: caret + close, length: 0))
        }
        // Touching a word: style the word. From its end, typing carries on unstyled after it.
        if (caret > line.content.location && isWord(ns, caret - 1)) || (caret < NSMaxRange(line.content) && isWord(ns, caret)) {
            var start = caret, end = caret
            while start > line.content.location, isWord(ns, start - 1) { start -= 1 }
            while end < NSMaxRange(line.content), isWord(ns, end) { end += 1 }
            let word = NSRange(location: start, length: end - start)
            return MarkdownEdit(range: word, replacement: style.open + ns.substring(with: word) + style.close,
                                selection: NSRange(location: caret == end ? end + open + close : caret + open, length: 0))
        }
        return MarkdownEdit(range: NSRange(location: caret, length: 0), replacement: style.open + style.close,
                            selection: NSRange(location: caret + open, length: 0))
    }

    /// Whether a style opened earlier on the line is still waiting for its close.
    private static func isOpen(_ style: Inline, _ before: String) -> Bool {
        if style == .underline {
            return before.components(separatedBy: "<u>").count > before.components(separatedBy: "</u>").count
        }
        var bold = 0, italic = 0, run = 0
        for c in before + " " {
            if c == "*" { run += 1; continue }
            bold += run / 2; italic += run % 2; run = 0
        }
        return (style == .bold ? bold : italic) % 2 == 1
    }

    private static func isWord(_ ns: NSString, _ i: Int) -> Bool {
        guard i >= 0, i < ns.length, let scalar = UnicodeScalar(ns.character(at: i)) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    /// The selection's text on each line it touches, past list, quote and heading prefixes,
    /// without the spaces at either end.
    private static func segments(of selection: NSRange, in ns: NSString) -> [NSRange] {
        guard selection.length > 0 else { return [] }
        return MarkdownSyntax.lines(in: ns, selection).compactMap { line in
            var start = max(line.content.location, selection.location)
            var end = min(NSMaxRange(line.content), NSMaxRange(selection))
            while start < end, isSpace(ns.character(at: start)) { start += 1 }
            while end > start, isSpace(ns.character(at: end - 1)) { end -= 1 }
            return end > start ? NSRange(location: start, length: end - start) : nil
        }
    }

    private static func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 }

    // MARK: Helpers

    /// Several replacements as one, from the first to the last; ranges must not overlap.
    private static func merge(_ parts: [(NSRange, String)], in ns: NSString) -> (range: NSRange, text: String) {
        let parts = parts.sorted { $0.0.location < $1.0.location }
        let start = parts[0].0.location
        var text = "", position = start
        for (range, replacement) in parts {
            text += ns.substring(with: NSRange(location: position, length: range.location - position)) + replacement
            position = NSMaxRange(range)
        }
        return (NSRange(location: start, length: position - start), text)
    }

    /// Where a position lands after the replacements; one inside a replaced range keeps its
    /// offset, as far as the replacement reaches.
    private static func map(_ position: Int, _ parts: [(NSRange, String)]) -> Int {
        var delta = 0
        for (range, text) in parts.sorted(by: { $0.0.location < $1.0.location }) {
            let length = text.utf16.count
            if position >= NSMaxRange(range) { delta += length - range.length }
            else if position > range.location { return range.location + delta + min(position - range.location, length) }
            else { break }
        }
        return position + delta
    }
}
