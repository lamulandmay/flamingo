import Foundation
import FlamingoCore

/// PowerPoint: one section per slide in presentation order, anchored `(slide N)` with hidden
/// slides counted so numbers match PowerPoint's. A section's text is the title, then every
/// shape's text in reading order (groups and tables included), then the speaker notes after a
/// blank line. Layouts and masters are never read, so their prompt text never leaks in.
public struct PPTXExtractor: Extractor {
    public static let extensions: Set<String> = ["pptx", "pptm", "potx", "potm", "ppsx", "ppsm"]
    public init() {}

    public func extract(_ url: URL) throws -> Extracted {
        let zip = try ZipArchive(url)
        // One unzip run fetches every part PowerPoint puts in the usual places; parts that the
        // relationships place elsewhere are fetched in a follow-up batch.
        var parts = zip.read(zip.names(where: Self.isUsualPart))
        func load(_ names: [String]) {
            let missing = names.filter { parts[$0] == nil && zip.contains($0) }
            if !missing.isEmpty { parts.merge(zip.read(missing)) { old, _ in old } }
        }

        let package = OOXMLPath.relationships(parts["_rels/.rels"], owner: "")
        func target(_ type: String) -> String? { package.values.first { $0.type == type && !$0.external }?.target }
        guard let main = [target("officeDocument"), "ppt/presentation.xml"].compactMap({ $0 }).first(where: zip.contains)
        else { throw ExtractError.malformed(url.path) }
        let core = target("core-properties") ?? "docProps/core.xml"
        load([main, OOXMLPath.rels(for: main), core])
        guard let presentation = parts[main].flatMap(XML.parse) else { throw ExtractError.malformed(url.path) }

        let rels = OOXMLPath.relationships(parts[OOXMLPath.rels(for: main)], owner: main)
        let slides = (presentation.first("sldIdLst")?.children("sldId") ?? []).compactMap { id -> String? in
            guard let rel = id.prefixedAttr("id").flatMap({ rels[$0] }), !rel.external else { return nil }
            return rel.target
        }
        load(slides + slides.map(OOXMLPath.rels))
        let notes = slides.map { slide in
            OOXMLPath.relationships(parts[OOXMLPath.rels(for: slide)], owner: slide).values
                .first { $0.type == "notesSlide" && !$0.external }?.target
        }
        load(notes.compactMap { $0 })

        let sections = slides.indices.map { i in
            Self.section(number: i + 1, slide: parts[slides[i]], notes: notes[i].flatMap { parts[$0] })
        }
        let docTitle = parts[core].flatMap(XML.parse)?.first("title").map { Self.squeeze($0.text) }
        return Extracted(sections: sections, title: docTitle.flatMap { $0.isEmpty ? nil : $0 } ?? sections.first?.title)
    }

    private static func isUsualPart(_ name: String) -> Bool {
        switch name {
        case "_rels/.rels", "docProps/core.xml", "ppt/presentation.xml", "ppt/_rels/presentation.xml.rels": true
        default: name.hasPrefix("ppt/slides/") || (name.hasPrefix("ppt/notesSlides/") && !name.contains("/_rels/"))
        }
    }

    private static let slideSkips: Set<String> = ["sldNum", "dt", "ftr"]
    private static let notesSkips: Set<String> = ["sldImg", "sldNum", "dt", "ftr", "hdr"]

    private static func section(number: Int, slide: Data?, notes: Data?) -> Section {
        var title: String?
        var body: [String] = []
        if let tree = slide.flatMap(XML.parse)?.path("cSld", "spTree") {
            var titleShape: XElement?
            tree.walk { e in
                if titleShape == nil, e.localName == "sp", let t = placeholderType(e), t == "title" || t == "ctrTitle" { titleShape = e }
                return titleShape == nil
            }
            title = titleShape.map { squeeze(paragraphs($0.first("txBody")).joined(separator: " ")) }.flatMap { $0.isEmpty ? nil : $0 }
            body = shapeTexts(tree, skipping: slideSkips, omitting: titleShape)
        }
        let spoken = notes.flatMap(XML.parse)?.path("cSld", "spTree").map { shapeTexts($0, skipping: notesSkips, omitting: nil) } ?? []
        let text = [(title.map { [$0] } ?? []) + body, spoken]
            .map { $0.joined(separator: "\n") }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return Section(anchor: FileAnchor(kind: .slide, value: String(number)), title: title, text: text)
    }

    /// Text of each shape in `container`, in reading order. A group contributes its own shapes'
    /// text in reading order; placeholders whose type is in `skip`, and `omit`, contribute nothing.
    private static func shapeTexts(_ container: XElement, skipping skip: Set<String>, omitting omit: XElement?) -> [String] {
        var blocks: [(offset: (y: Int, x: Int)?, text: String)] = []
        for shape in members(of: container) where shape !== omit {
            let text: String
            switch shape.localName {
            case "grpSp": text = shapeTexts(shape, skipping: skip, omitting: omit).joined(separator: "\n")
            case "graphicFrame": text = shape.path("graphic", "graphicData", "tbl").map(tableText) ?? ""
            default:
                if let type = placeholderType(shape), skip.contains(type) { continue }
                text = paragraphs(shape.first("txBody")).filter { !isBlank($0) }.joined(separator: "\n")
            }
            if !text.isEmpty { blocks.append((offset(of: shape), text)) }
        }
        // Positioned shapes are sorted top-to-bottom, left-to-right among the slots they occupy;
        // shapes that inherit their position from the layout keep their document order.
        let slots = blocks.indices.filter { blocks[$0].offset != nil }
        let sorted = slots.sorted { a, b in
            let p = blocks[a].offset!, q = blocks[b].offset!
            return (p.y, p.x, a) < (q.y, q.x, b)
        }
        var ordered = blocks.map(\.text)
        for (slot, from) in zip(slots, sorted) { ordered[slot] = blocks[from].text }
        return ordered
    }

    /// A container's children with each `mc:AlternateContent` replaced by its first choice's children.
    private static func members(of container: XElement) -> [XElement] {
        container.children.flatMap { c -> [XElement] in
            guard c.localName == "AlternateContent" else { return [c] }
            return (c.first("Choice") ?? c.first("Fallback")).map(members) ?? []
        }
    }

    /// `p:nvSpPr/p:nvPr/p:ph@type` (or the `nvCxnSpPr`, `nvGraphicFramePr`… equivalent). A
    /// placeholder without a type is a content placeholder and returns "obj".
    private static func placeholderType(_ shape: XElement) -> String? {
        guard let ph = shape.children.first(where: { $0.localName.hasPrefix("nv") })?.path("nvPr", "ph") else { return nil }
        return ph.attr("type") ?? "obj"
    }

    /// Top-left corner in EMUs from the shape's own transform, if it has one.
    private static func offset(of shape: XElement) -> (y: Int, x: Int)? {
        let xfrm = shape.path("spPr", "xfrm") ?? shape.path("grpSpPr", "xfrm") ?? shape.first("xfrm")
        guard let off = xfrm?.first("off"), let x = off.attr("x").flatMap({ Int($0) }),
              let y = off.attr("y").flatMap({ Int($0) }) else { return nil }
        return (y, x)
    }

    /// Each `a:p` of a text body: runs and fields concatenated, `a:br` as a newline.
    private static func paragraphs(_ body: XElement?) -> [String] {
        (body?.children("p") ?? []).map { p in
            p.children.reduce(into: "") { s, c in
                switch c.localName {
                case "r", "fld": s += c.first("t")?.text ?? ""
                case "br": s += "\n"
                default: break
                }
            }
        }
    }

    /// Rows on lines, cells tab-separated, each cell's paragraphs on one line. Empty rows dropped.
    private static func tableText(_ table: XElement) -> String {
        table.children("tr").compactMap { row -> String? in
            let cells = row.children("tc").map { squeeze(paragraphs($0.first("txBody")).joined(separator: " ")) }
            return cells.allSatisfy(\.isEmpty) ? nil : cells.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// Collapses every run of whitespace (line breaks and vertical tabs included) to one space.
    private static func squeeze(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func isBlank(_ s: String) -> Bool { s.allSatisfy(\.isWhitespace) }
}
