import Foundation
import FlamingoCore

/// Word: one section per Heading 1–3 chunk, tables included.
///
/// A heading is a body paragraph whose style is `heading 1`–`heading 3` (by name or outline level,
/// through `basedOn`) or whose own outline level is 0–2. Each section is anchored `.node` at its
/// heading text; text before the first heading is anchored at the document title, else its first
/// words. Tracked changes read as accepted. Footnotes and endnotes follow the sections in `text`
/// but belong to none.
public struct DOCXExtractor: Extractor {
    public static let extensions: Set<String> = ["docx", "docm", "dotx", "dotm"]
    public init() {}

    public func extract(_ url: URL) throws -> Extracted {
        let zip = try ZipArchive(url)
        // Word's usual part names are fetched with the package rels, so the common case is one read.
        let guess = Layout(main: "word/document.xml", core: "docProps/core.xml")
        var parts = zip.read(["_rels/.rels"] + guess.all)
        let rels = OOXMLPath.relationships(parts["_rels/.rels"], owner: "").values
        let layout = Layout(
            main: rels.first { $0.type == "officeDocument" && !$0.external && zip.contains($0.target) }?.target ?? guess.main,
            core: rels.first { $0.type == "core-properties" && !$0.external }?.target ?? guess.core)
        let missing = layout.all.filter { parts[$0] == nil && zip.contains($0) }
        if !missing.isEmpty { parts.merge(zip.read(missing)) { old, _ in old } }

        let styles = Styles(parts[layout.styles])
        let body = WordParser(styles: styles)
        guard let document = parts[layout.main], body.parse(document) else { throw ExtractError.malformed(url.path) }
        let notes = [layout.footnotes, layout.endnotes].compactMap { parts[$0] }.flatMap { data -> [String] in
            let p = WordParser(styles: styles)
            _ = p.parse(data)
            return p.notes
        }

        let coreTitle = parts[layout.core].flatMap(XML.parse)?.first("title")
            .map { Self.oneLine($0.allText) }.flatMap { $0.isEmpty ? nil : $0 }
        let sections = Self.sections(body.blocks, intro: coreTitle)
        let title = coreTitle ?? body.blocks.first(where: \.isTitle).map { Self.oneLine($0.text) }
            ?? sections.first { $0.title != nil }?.title
        var out = Extracted(sections: sections, title: title)
        if !notes.isEmpty { out.text += (out.text.isEmpty ? "" : "\n\n") + notes.joined(separator: "\n") }
        return out
    }

    /// Splits body blocks at level 1–3 headings. The part before the first heading is anchored at
    /// `intro`, else at its first paragraph's first 60 characters, and has no title.
    private static func sections(_ blocks: [Block], intro: String?) -> [Section] {
        var out: [Section] = []
        var heading: String?
        var lines: [String] = []
        func flush() {
            guard let first = lines.first else { return }
            let value = heading ?? intro ?? String(oneLine(first).prefix(60)).trimmingCharacters(in: .whitespaces)
            out.append(Section(anchor: FileAnchor(kind: .node, value: value), title: heading,
                               text: lines.joined(separator: "\n")))
        }
        for block in blocks {
            if let level = block.level, (1...3).contains(level) {
                flush()
                heading = oneLine(block.text)
                lines = []
            }
            lines.append(block.text)
        }
        flush()
        return out
    }

    /// Whitespace runs (tabs, breaks, no-break spaces) folded to single spaces, ends trimmed.
    private static func oneLine(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}

/// The parts read from a package, placed relative to its main document part.
private struct Layout {
    let main, core, styles, footnotes, endnotes: String
    var all: [String] { [main, core, styles, footnotes, endnotes] }

    init(main: String, core: String) {
        let dir = (main as NSString).deletingLastPathComponent
        func sibling(_ name: String) -> String { dir.isEmpty ? name : "\(dir)/\(name)" }
        self.main = main
        self.core = core
        styles = sibling("styles.xml")
        footnotes = sibling("footnotes.xml")
        endnotes = sibling("endnotes.xml")
    }
}

/// Paragraph styles from `styles.xml`: outline level (1-based) and whether a style is Title.
/// Without a styles part, or for ids it doesn't define, Word's built-in ids (`Heading1`, `Title`) decide.
private struct Styles {
    private var levels: [String: Int] = [:]
    private var titles: Set<String> = []
    private var defined: Set<String> = []

    init(_ data: Data?) {
        guard let data, let root = XML.parse(data) else { return }
        struct Style { var name: String; var basedOn: String?; var outline: Int? }
        var styles: [String: Style] = [:]
        for s in root.children("style") where s.attr("type") == "paragraph" {
            guard let id = s.attr("styleId") else { continue }
            styles[id] = Style(name: (s.first("name")?.attr("val") ?? "").lowercased(),
                               basedOn: s.first("basedOn")?.attr("val"),
                               outline: s.path("pPr", "outlineLvl")?.attr("val").flatMap { Int($0) })
        }
        // A style's own name or outline level wins over what it inherits; the depth cap stops cycles.
        func level(_ id: String, depth: Int) -> Int? {
            guard depth < 16, let s = styles[id] else { return nil }
            if s.name.hasPrefix("heading "), let n = Int(s.name.dropFirst(8)) { return n }
            if let o = s.outline { return o + 1 }
            return s.basedOn.flatMap { level($0, depth: depth + 1) }
        }
        for id in styles.keys { levels[id] = level(id, depth: 0) }
        titles = Set(styles.filter { $0.value.name == "title" }.keys)
        defined = Set(styles.keys)
    }

    func level(_ id: String) -> Int? {
        if defined.contains(id) { return levels[id] }
        let lower = id.lowercased()
        return lower.hasPrefix("heading") ? Int(lower.dropFirst(7)) : nil
    }

    func isTitle(_ id: String) -> Bool { defined.contains(id) ? titles.contains(id) : id == "Title" }
}

/// A paragraph or flattened table. Level and Title flag are set only for paragraphs directly in the body.
private struct Block {
    var text: String
    var level: Int?
    var isTitle = false
}

/// Streams a WordprocessingML part (document, footnotes, or endnotes) into blocks.
///
/// Text reads like Word's accepted view: deletions, moved-from runs, field instructions, and the
/// `mc:Fallback` copy of each drawing are skipped. Table cells join their paragraphs with spaces,
/// cells with tabs, rows with newlines. A text box's paragraphs follow the paragraph anchoring it.
private final class WordParser: NSObject, XMLParserDelegate {
    private(set) var blocks: [Block] = []
    /// Footnote and endnote texts in order, separators left out.
    private(set) var notes: [String] = []

    private struct Paragraph { var text = ""; var style: String?; var outline: Int?; var floating: [Block] = [] }
    private struct Table {
        var rows: [[String]] = []
        mutating func add(cell: String) { if rows.isEmpty { rows.append([]) }; rows[rows.count - 1].append(cell) }
        var text: String { rows.filter { $0.contains { !$0.isEmpty } }.map { $0.joined(separator: "\t") }.joined(separator: "\n") }
    }

    private static let skipped: Set<String> = ["del", "delText", "moveFrom", "instrText", "delInstrText", "Fallback"]
    private static let separators: Set<String> = ["separator", "continuationSeparator", "continuationNotice"]
    /// Run content that stands for a character.
    private static let marks = ["tab": "\t", "br": "\n", "cr": "\n", "noBreakHyphen": "-"]

    private let styles: Styles
    private var path: [String] = []
    private var skipDepth = 0
    private var inText = false
    private var paragraphs: [Paragraph] = []
    /// The body, then each open table cell, text box, or note.
    private var containers: [[Block]] = [[]]
    private var tables: [Table] = []

    init(styles: Styles) { self.styles = styles }

    /// False if the part isn't well-formed and nothing was recovered before the error.
    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        let ok = parser.parse()
        blocks = containers[0]
        return ok || !blocks.isEmpty
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        let local = name.firstIndex(of: ":").map { String(name[name.index(after: $0)...]) } ?? name
        if skipDepth > 0 || Self.skipped.contains(local)
            || ((local == "footnote" || local == "endnote") && Self.separators.contains(Self.value(attributes, "type") ?? "")) {
            skipDepth += 1
            return
        }
        let parent = path.last
        path.append(local)
        switch local {
        case "p": paragraphs.append(Paragraph())
        case "t": inText = true
        case "pStyle", "outlineLvl":
            // Only the paragraph's own properties; `w:pPrChange` holds the pre-revision ones.
            guard parent == "pPr", path.count >= 3, path[path.count - 3] == "p", !paragraphs.isEmpty else { break }
            let v = Self.value(attributes, "val")
            if local == "pStyle" { paragraphs[paragraphs.count - 1].style = v }
            else { paragraphs[paragraphs.count - 1].outline = v.flatMap { Int($0) } }
        case "tbl": tables.append(Table())
        case "tr": if !tables.isEmpty { tables[tables.count - 1].rows.append([]) }
        case "tc", "txbxContent", "footnote", "endnote": containers.append([])
        default: if parent == "r", let mark = Self.marks[local] { append(mark) }
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if skipDepth > 0 { skipDepth -= 1; return }
        guard let local = path.popLast() else { return }
        switch local {
        case "t": inText = false
        case "p": endParagraph()
        case "tc":
            let cell = containers.removeLast().map(\.text).joined(separator: " ")
            if !tables.isEmpty { tables[tables.count - 1].add(cell: cell) }
        case "tbl": if let t = tables.popLast() { add(Block(text: t.text)) }
        case "txbxContent":
            let inner = containers.removeLast()
            if paragraphs.isEmpty { containers[containers.count - 1] += inner }
            else { paragraphs[paragraphs.count - 1].floating += inner }
        case "footnote", "endnote":
            let note = containers.removeLast().map(\.text).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty { notes.append(note) }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { append(string) }
    }

    private func append(_ s: String) {
        if !paragraphs.isEmpty { paragraphs[paragraphs.count - 1].text += s }
    }

    private func endParagraph() {
        guard let p = paragraphs.popLast() else { return }
        var block = Block(text: p.text)
        if containers.count == 1 {
            block.level = p.outline.map { $0 + 1 } ?? p.style.flatMap(styles.level)
            block.isTitle = p.style.map(styles.isTitle) ?? false
        }
        add(block)
        containers[containers.count - 1] += p.floating
    }

    /// Appends to the innermost container unless the block has no visible text.
    private func add(_ block: Block) {
        guard block.text.contains(where: { !$0.isWhitespace }) else { return }
        containers[containers.count - 1].append(block)
    }

    /// `w:val`-style attribute by local name, whatever the prefix.
    private static func value(_ attributes: [String: String], _ local: String) -> String? {
        attributes["w:" + local] ?? attributes.first { $0.key.hasSuffix(":" + local) }?.value
    }
}
