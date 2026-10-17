import AppKit
import Foundation
import FlamingoCore

/// Plain text, Markdown, source code and config, HTML, Jupyter notebooks, RTF and RTFD.
/// `Extract` also hands it extension-less files that sniff as text, so an extension it
/// doesn't know reads as plain text.
public struct TextExtractor: Extractor {
    static let markdown: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx"]
    static let html: Set<String> = ["html", "htm", "xhtml"]
    static let rich: Set<String> = ["rtf", "rtfd"]
    /// Plain text, code, and config: one section holding the whole file.
    static let plain: Set<String> = [
        "txt", "text", "log", "csv", "tsv", "srt", "vtt", "diff", "patch",
        "swift", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx", "json", "jsonc", "yaml", "yml", "toml",
        "xml", "css", "scss", "sass", "less", "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm",
        "java", "kt", "kts", "scala", "go", "rs", "rb", "php", "pl", "pm", "lua", "r", "sql", "sh",
        "bash", "zsh", "fish", "ps1", "bat", "cs", "fs", "vb", "hs", "ml", "ex", "exs", "erl", "clj",
        "cljs", "dart", "vue", "svelte", "groovy", "gradle", "tf", "hcl", "ini", "cfg", "conf", "env",
        "properties", "tex", "bib", "rst", "org", "adoc", "ipynb",
    ]
    public static let extensions: Set<String> = plain.union(markdown).union(html).union(rich)

    /// Bytes read from one file. The index keeps 2 MB of text, so reading more is wasted work.
    static let readLimit = 8 << 20
    /// Notebooks carry base64 plots in their outputs; they get room to stay valid JSON.
    static let notebookReadLimit = 64 << 20
    static let firstLine = FileAnchor(kind: .line, value: "1")

    public init() {}

    public func extract(_ url: URL) throws -> Extracted {
        let ext = url.pathExtension.lowercased()
        if Self.rich.contains(ext) { return try Self.richText(url, type: ext == "rtfd" ? .rtfd : .rtf) }
        let notebook = ext == "ipynb"
        let (data, truncated) = try Self.read(url, limit: notebook ? Self.notebookReadLimit : Self.readLimit)
        if notebook { return try Self.notebook(data, url) }
        let text = try Self.decode(data, url: url, truncated: truncated, html: Self.html.contains(ext))
        var out: Extracted
        if Self.isBlank(text) { out = Extracted(text: "") }
        else if Self.markdown.contains(ext) { out = MarkdownOutline.extract(text) }
        else if Self.html.contains(ext) { out = HTMLText.extract(text) }
        else { out = Extracted(sections: [Section(anchor: Self.firstLine, text: text)]) }
        if truncated { out.coverage = ExtractionCoverage(.partial, reason: "Source text exceeds the byte budget.") }
        return out
    }

    // MARK: - Reading and decoding

    /// Up to `limit` bytes, and whether the file had more.
    static func read(_ url: URL, limit: Int) throws -> (Data, Bool) {
        guard let h = try? FileHandle(forReadingFrom: url) else { throw ExtractError.unreadable(url.path) }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: limit + 1) ?? Data() else { throw ExtractError.unreadable(url.path) }
        return d.count > limit ? (d.prefix(limit), true) : (d, false)
    }

    /// Decodes text: a byte-order mark wins, then UTF-8, then the charset an HTML page declares,
    /// then whatever Foundation detects (the `com.apple.TextEncoding` xattr TextEdit writes),
    /// then Windows-1252, then Mac Roman, which takes any bytes. Newlines come back as "\n".
    /// Throws `malformed` for binary data (NULs without a BOM) so the caller can try Spotlight.
    static func decode(_ data: Data, url: URL, truncated: Bool, html: Bool = false) throws -> String {
        if case let (encoding, mark)? = byteOrderMark(data) {
            let body = data.dropFirst(mark)
            let s: String? = encoding == .utf8
                ? String(decoding: body, as: UTF8.self)
                : String(data: body.prefix(body.count - body.count % mark), encoding: encoding)
            guard let s else { throw ExtractError.malformed(url.path) }
            return unixNewlines(s)
        }
        if data.prefix(4096).contains(0) { throw ExtractError.malformed(url.path) }
        // A truncated read may end inside a multi-byte character.
        for cut in 0...(truncated ? 3 : 0) {
            if let s = String(data: data.dropLast(cut), encoding: .utf8) { return unixNewlines(s) }
        }
        if html, let encoding = declaredCharset(data), let s = String(data: data, encoding: encoding) {
            return unixNewlines(s)
        }
        var used = String.Encoding.utf8
        if !truncated, let s = try? String(contentsOf: url, usedEncoding: &used) { return unixNewlines(s) }
        guard let s = String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .macOSRoman) else {
            throw ExtractError.malformed(url.path)
        }
        return unixNewlines(s)
    }

    /// The encoding a byte-order mark announces, and the mark's length in bytes.
    static func byteOrderMark(_ data: Data) -> (String.Encoding, Int)? {
        let b = [UInt8](data.prefix(4))
        if b.starts(with: [0xEF, 0xBB, 0xBF]) { return (.utf8, 3) }
        if b.starts(with: [0xFF, 0xFE, 0, 0]) { return (.utf32LittleEndian, 4) }
        if b.starts(with: [0, 0, 0xFE, 0xFF]) { return (.utf32BigEndian, 4) }
        if b.starts(with: [0xFF, 0xFE]) { return (.utf16LittleEndian, 2) }
        if b.starts(with: [0xFE, 0xFF]) { return (.utf16BigEndian, 2) }
        return nil
    }

    /// The `charset=` an HTML page declares near its top, for pages that aren't UTF-8.
    static func declaredCharset(_ data: Data) -> String.Encoding? {
        let head = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
        guard let r = head.range(of: "charset=") else { return nil }
        let name = head[r.upperBound...].drop { $0 == "\"" || $0 == "'" }
            .prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        let cf = CFStringConvertIANACharSetNameToEncoding(String(name) as CFString)
        guard !name.isEmpty, cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// "\r\n" and lone "\r" become "\n". Works on bytes: CR and LF never occur inside a
    /// multi-byte UTF-8 sequence.
    static func unixNewlines(_ s: String) -> String {
        var s = s
        let fixed = s.withUTF8 { b -> String? in
            guard var cr = b.index(of: 13, from: 0) else { return nil }
            var out: [UInt8] = []
            out.reserveCapacity(b.count)
            var i = 0
            while true {
                out.append(contentsOf: UnsafeBufferPointer(rebasing: b[i..<cr]))
                out.append(10)
                i = cr + 1 < b.count && b[cr + 1] == 10 ? cr + 2 : cr + 1
                guard let next = b.index(of: 13, from: i) else { break }
                cr = next
            }
            out.append(contentsOf: UnsafeBufferPointer(rebasing: b[i...]))
            return String(decoding: out, as: UTF8.self)
        }
        return fixed ?? s
    }

    static func isBlank(_ s: String) -> Bool {
        s.utf8.allSatisfy { $0 == 32 || $0 == 9 || $0 == 10 || $0 == 13 }
    }

    // MARK: - Notebooks and rich text

    /// A notebook's cell sources in order, Markdown and code alike; outputs are left out.
    /// Reads nbformat 4 (`cells`, `source`) and 3 (`worksheets`, `input`).
    static func notebook(_ data: Data, _ url: URL) throws -> Extracted {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ExtractError.malformed(url.path)
        }
        let cells = root["cells"] as? [[String: Any]]
            ?? (root["worksheets"] as? [[String: Any]])?.flatMap { $0["cells"] as? [[String: Any]] ?? [] }
            ?? []
        var parts: [String] = [], title: String?
        for cell in cells {
            let source = cell["source"] ?? cell["input"]
            var text = unixNewlines((source as? [String])?.joined() ?? source as? String ?? "")
            guard !isBlank(text) else { continue }
            while text.last == "\n" { text.removeLast() }
            if title == nil, cell["cell_type"] as? String == "markdown" { title = MarkdownOutline.extract(text).title }
            parts.append(text)
        }
        guard !parts.isEmpty else { return Extracted(text: "") }
        return Extracted(sections: [Section(anchor: firstLine, text: parts.joined(separator: "\n\n"))], title: title)
    }

    /// RTF and RTFD through the Cocoa text system, whose RTF reader (unlike its HTML importer)
    /// runs on any thread. The title is the document's `\info{\title}`, if any.
    static func richText(_ url: URL, type: NSAttributedString.DocumentType) throws -> Extracted {
        var info: NSDictionary?
        guard let s = try? NSAttributedString(url: url, options: [.documentType: type], documentAttributes: &info) else {
            throw ExtractError.malformed(url.path)
        }
        var scalars = String.UnicodeScalarView()
        for u in unixNewlines(s.string).unicodeScalars {
            switch u {
            case "\u{FFFC}": continue                           // attachment placeholder
            case "\u{2028}", "\u{2029}": scalars.append("\n")   // \line, paragraph separator
            default: scalars.append(u)
            }
        }
        let text = String(scalars)
        let title = ((info as? [NSAttributedString.DocumentAttributeKey: Any])?[.title] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        guard !isBlank(text) else { return Extracted(text: "", title: title) }
        return Extracted(sections: [Section(anchor: firstLine, text: text)], title: title)
    }
}

// MARK: - Markdown

/// Markdown structure from one pass over the UTF-8 bytes: YAML front matter, then ATX and
/// setext headings by CommonMark's rules (minus lists and block quotes as containers),
/// skipping fenced and indented code.
private enum MarkdownOutline {
    struct Heading { var line: Int; var offset: Int; var level: Int; var title: String? }

    static func extract(_ text: String) -> Extracted {
        var text = text
        let (sections, title) = text.withUTF8 { b -> ([Section], String?) in
            let (headings, frontTitle) = outline(b)
            var sections: [Section] = []
            let first = headings.first?.offset ?? b.count
            if !b.isBlank(0..<first) {
                sections.append(Section(anchor: TextExtractor.firstLine, text: b.string(b.trimmingEnd(0..<first))))
            }
            for (k, h) in headings.enumerated() {
                let end = k + 1 < headings.count ? headings[k + 1].offset : b.count
                sections.append(Section(anchor: FileAnchor(kind: .line, value: String(h.line)), title: h.title,
                                        text: b.string(b.trimmingEnd(h.offset..<end))))
            }
            return (sections, frontTitle ?? headings.lazy.compactMap { $0.level == 1 ? $0.title : nil }.first)
        }
        return Extracted(text: text, sections: sections, title: title)
    }

    /// Headings in order, with 1-based line numbers and the byte offset where each starts,
    /// plus the front matter's title.
    static func outline(_ b: UnsafeBufferPointer<UInt8>) -> ([Heading], String?) {
        var headings: [Heading] = []
        let front = frontMatter(b)
        var pos = front?.end ?? 0, line = front?.lines ?? 0
        var fence: (mark: UInt8, count: Int)?
        var para: (line: Int, offset: Int, lines: [Range<Int>])?
        while pos < b.count {
            let start = pos, end = b.index(of: .newline, from: pos) ?? b.count
            pos = end + 1
            line += 1
            var i = start
            while i < end, b[i] == .space { i += 1 }
            let indent = i < end && b[i] == .tab ? 4 : i - start
            let content = b.trimmingEnd(i..<end)
            let c = content.isEmpty ? 0 : b[i], n = b.run(of: c, in: content)

            if let f = fence {
                if indent < 4, c == f.mark, n >= f.count, n == content.count { fence = nil }
                continue
            }
            if content.isEmpty { para = nil; continue }
            if indent >= 4 { para?.lines.append(content); continue }
            if (c == .backtick || c == .tilde) && n >= 3
                && (c == .tilde || !b[content.lowerBound + n ..< content.upperBound].contains(.backtick)) {
                fence = (c, n); para = nil; continue
            }
            if c == .hash && n <= 6 && (n == content.count || b[i + n] == .space || b[i + n] == .tab) {
                headings.append(Heading(line: line, offset: start, level: n, title: atxTitle(b, i + n ..< content.upperBound)))
                para = nil; continue
            }
            if let p = para, c == .equals || c == .dash, n == content.count {
                let title = p.lines.map { b.string(b.trimming($0)) }.joined(separator: " ")
                headings.append(Heading(line: p.line, offset: p.offset, level: c == .equals ? 1 : 2, title: title))
                para = nil; continue
            }
            if c == .gt || isThematicBreak(b, content) || isListItem(b, content) { para = nil; continue }
            if para == nil { para = (line, start, [content]) } else { para?.lines.append(content) }
        }
        return (headings, front?.title)
    }

    /// `---` on the first line through the next `---` or `...` line. Returns the offset just
    /// past it, its last line number, and its `title:` without quotes.
    static func frontMatter(_ b: UnsafeBufferPointer<UInt8>) -> (end: Int, lines: Int, title: String?)? {
        let firstEnd = b.index(of: .newline, from: 0) ?? b.count
        guard b.equals(b.trimmingEnd(0..<firstEnd), "---") else { return nil }
        var pos = firstEnd + 1, line = 1, title: String?
        while pos < b.count {
            let end = b.index(of: .newline, from: pos) ?? b.count
            line += 1
            let r = b.trimmingEnd(pos..<end)
            if b.equals(r, "---") || b.equals(r, "...") { return (end + 1, line, title) }
            if title == nil, b.hasPrefix(r, "title:") {
                var v = b.string(b.trimming(r.lowerBound + 6 ..< r.upperBound))
                if v.count >= 2, let q = v.first, q == "\"" || q == "'", v.last == q { v = String(v.dropFirst().dropLast()) }
                title = v.isEmpty ? nil : v
            }
            pos = end + 1
        }
        return nil
    }

    /// Heading text after the opening `#`s, without the optional closing `#` run.
    static func atxTitle(_ b: UnsafeBufferPointer<UInt8>, _ r: Range<Int>) -> String? {
        var r = b.trimming(r)
        var k = r.upperBound
        while k > r.lowerBound, b[k - 1] == .hash { k -= 1 }
        if k == r.lowerBound { return nil }
        if k < r.upperBound, b[k - 1] == .space || b[k - 1] == .tab { r = b.trimming(r.lowerBound..<k) }
        return b.string(r)
    }

    /// Three or more of the same `-`, `*`, or `_`, optionally spaced.
    static func isThematicBreak(_ b: UnsafeBufferPointer<UInt8>, _ r: Range<Int>) -> Bool {
        let c = b[r.lowerBound]
        guard c == .dash || c == .star || c == .underscore else { return false }
        var count = 0
        for i in r { if b[i] == c { count += 1 } else if b[i] != .space && b[i] != .tab { return false } }
        return count >= 3
    }

    /// `- `, `* `, `+ `, `1. `, or `1) ` at the start of the line.
    static func isListItem(_ b: UnsafeBufferPointer<UInt8>, _ r: Range<Int>) -> Bool {
        var i = r.lowerBound
        if b[i] == .dash || b[i] == .star || b[i] == .plus {
            i += 1
        } else {
            while i < r.upperBound, i - r.lowerBound < 9, (48...57).contains(b[i]) { i += 1 }
            guard i > r.lowerBound, i < r.upperBound, b[i] == .dot || b[i] == .rparen else { return false }
            i += 1
        }
        return i == r.upperBound || b[i] == .space || b[i] == .tab
    }
}

// MARK: - HTML

/// Visible text of an HTML page without a DOM or WebKit: drops scripts, styles, and comments,
/// takes `<title>` (else the first `<h1>`) as the title, turns block elements into line
/// breaks and table cells into tabs, collapses whitespace as a browser would, decodes entities.
private enum HTMLText {
    /// Elements set off by a blank line.
    static let paragraphs: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "dl", "table", "blockquote", "pre", "hr",
        "section", "article", "header", "footer", "nav", "aside", "main", "figure", "form", "fieldset",
        "address", "details", "body",
    ]
    /// Elements that start on a new line.
    static let lines: Set<String> = [
        "div", "li", "tr", "dt", "dd", "caption", "figcaption", "summary", "legend", "option",
        "thead", "tbody", "tfoot", "center",
    ]
    /// Elements whose content is never shown as text.
    static let hidden: Set<String> = ["script", "style"]

    static func extract(_ html: String) -> Extracted {
        var html = html
        let (text, title) = html.withUTF8 { scan($0) }
        guard !text.isEmpty else { return Extracted(text: "", title: title) }
        return Extracted(sections: [Section(anchor: TextExtractor.firstLine, text: text)], title: title)
    }

    static func scan(_ b: UnsafeBufferPointer<UInt8>) -> (String, String?) {
        var out: [UInt8] = []
        out.reserveCapacity(b.count / 2)
        var titleBytes: ArraySlice<UInt8>?, h1: ArraySlice<UInt8>?, h1Start: Int?
        var space = false, pre = 0, i = 0

        func newlines(_ n: Int) {
            space = false
            guard !out.isEmpty else { return }
            var have = 0
            while have < n, have < out.count, out[out.count - 1 - have] == .newline { have += 1 }
            for _ in have..<n { out.append(.newline) }
        }

        while i < b.count {
            let c = b[i]
            if c != .lt {
                if pre == 0 && (c == .space || c == .tab || c == .newline || c == 12 || c == 13) {
                    space = true
                } else {
                    if space, let last = out.last, last != .newline, last != .tab { out.append(.space) }
                    space = false
                    out.append(c)
                }
                i += 1
                continue
            }
            if b.hasPrefix(i..<b.count, "<!--") {
                i = b.find("-->", from: i + 4).map { $0 + 3 } ?? b.count
                continue
            }
            if i + 1 < b.count, b[i + 1] == .bang || b[i + 1] == .question {
                i = (b.index(of: .gt, from: i) ?? b.count) + 1
                continue
            }
            var j = i + 1
            let closing = j < b.count && b[j] == .slash
            if closing { j += 1 }
            let nameStart = j
            while j < b.count, isNameByte(b[j]) { j += 1 }
            guard j > nameStart, isLetter(b[nameStart]) else {
                // A bare "<", as in "a < b".
                if space, let last = out.last, last != .newline, last != .tab { out.append(.space) }
                space = false
                out.append(c)
                i += 1
                continue
            }
            let name = String(decoding: b[nameStart..<j].map { isLetter($0) ? $0 | 0x20 : $0 }, as: UTF8.self)
            i = tagEnd(b, from: j) + 1

            if !closing, hidden.contains(name) || name == "title" {
                let close = closeTag(b, Array(name.utf8), from: i)
                if name == "title", titleBytes == nil { titleBytes = ArraySlice(UnsafeBufferPointer(rebasing: b[min(i, close)..<close])) }
                i = close
                continue
            }
            switch name {
            case "br":
                space = false
                if !out.isEmpty, !(out.count >= 2 && out[out.count - 1] == .newline && out[out.count - 2] == .newline) {
                    out.append(.newline)
                }
            case "td", "th":
                space = false
                if !closing, let last = out.last, last != .newline, last != .tab { out.append(.tab) }
            case "h1":
                if closing, h1 == nil, let s = h1Start, s <= out.count { h1 = out[s...] }
                newlines(2)
                h1Start = closing ? nil : out.count
            case "pre":
                newlines(2)
                pre = closing ? max(0, pre - 1) : pre + 1
            default:
                if paragraphs.contains(name) { newlines(2) } else if lines.contains(name) { newlines(1) }
            }
        }
        while let last = out.last, last == .newline || last == .space || last == .tab { out.removeLast() }
        let title = (titleBytes ?? h1).flatMap(inline)
        return (decodeEntities(out[...]), title)
    }

    /// One line of display text: entities decoded, whitespace collapsed, nil if empty.
    static func inline(_ bytes: ArraySlice<UInt8>) -> String? {
        let s = decodeEntities(bytes).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return s.isEmpty ? nil : s
    }

    /// Named entities from `entities`; everything else (`&amp;`, `&#8217;`) through `XML.unescape`.
    static func decodeEntities(_ b: ArraySlice<UInt8>) -> String {
        guard var amp = b.firstIndex(of: .amp) else { return String(decoding: b, as: UTF8.self) }
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = b.startIndex
        while true {
            out.append(contentsOf: b[i..<amp])
            i = amp + 1
            if let semi = b[i..<min(i + 11, b.endIndex)].firstIndex(of: .semicolon), semi > i {
                let token = String(decoding: b[amp...semi], as: UTF8.self)
                let decoded = entities[String(decoding: b[i..<semi], as: UTF8.self)] ?? XML.unescape(token)
                if decoded != token { out.append(contentsOf: decoded.utf8); i = semi + 1 } else { out.append(.amp) }
            } else {
                out.append(.amp)
            }
            guard let next = b[i...].firstIndex(of: .amp) else { break }
            amp = next
        }
        out.append(contentsOf: b[i...])
        return String(decoding: out, as: UTF8.self)
    }

    /// HTML 4's named entities beyond XML's five: Latin-1 (U+00A0 through U+00FF, in order)
    /// and the common typographic ones.
    static let entities: [String: String] = {
        let latin1 = """
            nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr deg plusmn \
            sup2 sup3 acute micro para middot cedil sup1 ordm raquo frac14 frac12 frac34 iquest Agrave \
            Aacute Acirc Atilde Auml Aring AElig Ccedil Egrave Eacute Ecirc Euml Igrave Iacute Icirc Iuml \
            ETH Ntilde Ograve Oacute Ocirc Otilde Ouml times Oslash Ugrave Uacute Ucirc Uuml Yacute THORN \
            szlig agrave aacute acirc atilde auml aring aelig ccedil egrave eacute ecirc euml igrave iacute \
            icirc iuml eth ntilde ograve oacute ocirc otilde ouml divide oslash ugrave uacute ucirc uuml \
            yacute thorn yuml
            """.split(separator: " ")
        var map: [String: String] = [:]
        for (k, name) in latin1.enumerated() { map[String(name)] = String(Character(Unicode.Scalar(UInt8(160 + k)))) }
        let more: [String: UInt32] = [
            "OElig": 0x152, "oelig": 0x153, "Scaron": 0x160, "scaron": 0x161, "Yuml": 0x178, "fnof": 0x192,
            "circ": 0x2C6, "tilde": 0x2DC, "ensp": 0x2002, "emsp": 0x2003, "thinsp": 0x2009, "zwnj": 0x200C,
            "zwj": 0x200D, "lrm": 0x200E, "rlm": 0x200F, "ndash": 0x2013, "mdash": 0x2014, "lsquo": 0x2018,
            "rsquo": 0x2019, "sbquo": 0x201A, "ldquo": 0x201C, "rdquo": 0x201D, "bdquo": 0x201E,
            "dagger": 0x2020, "Dagger": 0x2021, "bull": 0x2022, "hellip": 0x2026, "permil": 0x2030,
            "prime": 0x2032, "Prime": 0x2033, "lsaquo": 0x2039, "rsaquo": 0x203A, "euro": 0x20AC,
            "trade": 0x2122, "larr": 0x2190, "uarr": 0x2191, "rarr": 0x2192, "darr": 0x2193, "harr": 0x2194,
            "minus": 0x2212, "le": 0x2264, "ge": 0x2265, "ne": 0x2260, "infin": 0x221E, "asymp": 0x2248,
        ]
        for (name, code) in more { map[name] = Unicode.Scalar(code).map { String(Character($0)) } }
        return map
    }()

    /// Index of the `>` closing a tag whose name ends before `from`. Quotes count only after
    /// `=`, so a stray apostrophe can't swallow the page.
    static func tagEnd(_ b: UnsafeBufferPointer<UInt8>, from: Int) -> Int {
        var quote: UInt8 = 0, prev: UInt8 = 0
        for k in from..<b.count {
            let c = b[k]
            if quote != 0 { if c == quote { quote = 0 }; continue }
            if c == .gt { return k }
            if (c == .quote || c == .apostrophe) && prev == .equals { quote = c }
            if c != .space && c != .tab && c != .newline { prev = c }
        }
        return b.count
    }

    /// Offset of the first `</name` at or after `from`, ignoring case, else the end.
    static func closeTag(_ b: UnsafeBufferPointer<UInt8>, _ name: [UInt8], from: Int) -> Int {
        var i = from
        while let lt = b.index(of: .lt, from: i) {
            let after = lt + 2 + name.count
            if after <= b.count, b[lt + 1] == .slash,
               name.indices.allSatisfy({ b[lt + 2 + $0] | 0x20 == name[$0] }),
               after == b.count || !isNameByte(b[after]) {
                return lt
            }
            i = lt + 1
        }
        return b.count
    }

    static func isLetter(_ c: UInt8) -> Bool { (65...90).contains(c) || (97...122).contains(c) }
    static func isNameByte(_ c: UInt8) -> Bool { isLetter(c) || (48...57).contains(c) || c == .dash || c == 58 || c == .underscore }
}

// MARK: - Byte helpers

private extension UInt8 {
    static let tab: UInt8 = 9, newline: UInt8 = 10, space: UInt8 = 32, bang: UInt8 = 33, quote: UInt8 = 34
    static let hash: UInt8 = 35, amp: UInt8 = 38, apostrophe: UInt8 = 39, rparen: UInt8 = 41, star: UInt8 = 42
    static let plus: UInt8 = 43, dash: UInt8 = 45, dot: UInt8 = 46, slash: UInt8 = 47, semicolon: UInt8 = 59
    static let lt: UInt8 = 60, equals: UInt8 = 61, gt: UInt8 = 62, question: UInt8 = 63
    static let underscore: UInt8 = 95, backtick: UInt8 = 96, tilde: UInt8 = 126
}

private extension UnsafeBufferPointer<UInt8> {
    /// Offset of the next `byte` at or after `from`, via `memchr`.
    func index(of byte: UInt8, from: Int) -> Int? {
        guard let base = baseAddress, from < count, let p = memchr(base + from, Int32(byte), count - from) else { return nil }
        return UnsafeRawPointer(base).distance(to: p)
    }

    /// Offset of the next occurrence of an ASCII literal at or after `from`.
    func find(_ literal: String, from: Int) -> Int? {
        let lit = Array(literal.utf8)
        var i = from
        while let k = index(of: lit[0], from: i) {
            if hasPrefix(k..<count, literal) { return k }
            i = k + 1
        }
        return nil
    }

    func string(_ r: Range<Int>) -> String { String(decoding: UnsafeBufferPointer(rebasing: self[r]), as: UTF8.self) }
    func equals(_ r: Range<Int>, _ literal: String) -> Bool { self[r].elementsEqual(literal.utf8) }
    func hasPrefix(_ r: Range<Int>, _ literal: String) -> Bool { self[r].starts(with: literal.utf8) }
    func isBlank(_ r: Range<Int>) -> Bool { trimmingEnd(r).isEmpty }

    /// How many times `byte` repeats from the start of `r`.
    func run(of byte: UInt8, in r: Range<Int>) -> Int {
        var i = r.lowerBound
        while i < r.upperBound, self[i] == byte { i += 1 }
        return i - r.lowerBound
    }

    func trimmingEnd(_ r: Range<Int>) -> Range<Int> {
        var hi = r.upperBound
        while hi > r.lowerBound, self[hi - 1] == .space || self[hi - 1] == .tab || self[hi - 1] == .newline { hi -= 1 }
        return r.lowerBound..<hi
    }

    func trimming(_ r: Range<Int>) -> Range<Int> {
        let r = trimmingEnd(r)
        var lo = r.lowerBound
        while lo < r.upperBound, self[lo] == .space || self[lo] == .tab { lo += 1 }
        return lo..<r.upperBound
    }
}
