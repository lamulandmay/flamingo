import Foundation
import FlamingoCore

/// Excel: one section per sheet in workbook order, anchored by sheet name. A sheet's text is its
/// cell values row by row, tab-separated, with shared strings resolved and date-formatted numbers
/// shown as ISO dates. Worksheets and shared strings stream through `XMLParser`.
public struct XLSXExtractor: Extractor {
    public static let extensions: Set<String> = ["xlsx", "xlsm", "xltx", "xltm"]
    /// A sheet stops after this many non-empty cells.
    static let maxCellsPerSheet = 50_000
    /// A run of empty columns wider than this collapses to a single tab.
    static let maxPaddedGap = 32
    /// Sheets larger than this, uncompressed, are read only this far; the cell cap comes long before.
    static let maxSheetBytes = 32 << 20

    public init() {}

    public func extract(_ url: URL) throws -> Extracted { try read(url, selectedCell: nil) }

    /// Reads an exact spreadsheet coordinate without inferring it from flattened rows.
    /// Accepts `Sheet name!B12` and Excel's quoted `'Sheet name'!B12` spelling.
    public func cell(_ anchor: FileAnchor, in url: URL) throws -> Section? {
        guard anchor.kind == .cell, let bang = anchor.value.lastIndex(of: "!") else { return nil }
        var name = String(anchor.value[..<bang])
        if name.hasPrefix("'"), name.hasSuffix("'") { name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
        let address = String(anchor.value[anchor.value.index(after: bang)...]).replacingOccurrences(of: "$", with: "").uppercased()
        guard address.range(of: "^[A-Z]{1,3}[1-9][0-9]*$", options: .regularExpression) != nil else { return nil }
        return try read(url, selectedCell: (name, address)).sections.first
    }

    private func read(_ url: URL, selectedCell: (sheet: String, address: String)?) throws -> Extracted {
        let zip = try ZipArchive(url)
        func small(_ name: String) -> Bool { zip.sizes[name, default: 0] <= Self.maxSheetBytes }
        // One unzip run covers the usual layout; parts at unusual paths are fetched afterwards.
        var parts = zip.read(zip.names.filter { Self.isLikelyPart($0) && small($0) })
        func fetch(_ names: [String]) {
            let missing = names.filter { parts[$0] == nil }
            if !missing.isEmpty { parts.merge(zip.read(missing)) { old, _ in old } }
        }

        let rootRels = OOXMLPath.relationships(parts["_rels/.rels"], owner: "")
        let book = rootRels.values.first { $0.type == "officeDocument" && !$0.external }?.target ?? "xl/workbook.xml"
        let bookRels = OOXMLPath.rels(for: book)
        fetch([book, bookRels])
        guard let bookData = parts[book], let workbook = XML.parse(bookData) else { throw ExtractError.malformed(url.path) }

        let rels = OOXMLPath.relationships(parts[bookRels], owner: book)
        func target(_ rel: OOXMLPath.Relationship?) -> String? { rel.flatMap { $0.external ? nil : $0.target } }
        let sheets = (workbook.first("sheets")?.children("sheet") ?? []).map { s in
            (name: s.attr("name") ?? "", part: target(s.prefixedAttr("id").flatMap { rels[$0] }))
        }
        let sharedPart = target(rels.values.first { $0.type == "sharedStrings" })
        let stylesPart = target(rels.values.first { $0.type == "styles" })
        let selectedSheets = selectedCell.map { cell in sheets.filter { $0.name == cell.sheet } } ?? sheets
        let sheetParts = selectedSheets.compactMap(\.part)
        fetch(sheetParts.filter(small) + [sharedPart, stylesPart].compactMap { $0 })
        for part in sheetParts where !small(part) { parts[part] = zip.readPrefix(part, maxBytes: Self.maxSheetBytes) }

        let context = SheetParser.Context(
            shared: sharedPart.flatMap { parts[$0] }.map(SharedStringsParser.strings) ?? [],
            dateStyles: Self.dateStyles(stylesPart.flatMap { parts[$0] }),
            date1904: ["1", "true"].contains(workbook.first("workbookPr")?.attr("date1904") ?? ""))
        if let cell = selectedCell {
            guard let sheet = selectedSheets.first, let part = sheet.part, let data = parts[part] else { return .empty }
            let found = SheetParser.value(of: data, context, at: cell.address)
            guard found.complete || found.value != nil else { throw ExtractError.malformed("Cell lies outside the parsed worksheet budget.") }
            return Extracted(sections: [Section(anchor: FileAnchor(kind: .cell, value: cell.sheet + "!" + cell.address),
                                                title: cell.sheet + "!" + cell.address, text: found.value ?? "(empty cell)")])
        }
        var complete = true
        let sections = selectedSheets.map { sheet in
            let result = sheet.part.flatMap { parts[$0] }.map { SheetParser.read($0, context) }
            if result?.complete != true { complete = false }
            return Section(anchor: FileAnchor(kind: .sheet, value: sheet.name), title: sheet.name, text: result?.text ?? "")
        }
        var out = Extracted(sections: sections, title: Self.title(parts["docProps/core.xml"]))
        if !complete { out.coverage = ExtractionCoverage(.partial, reason: "A worksheet is missing, truncated, or exceeds the cell/byte budget.") }
        return out
    }

    /// Parts a workbook almost always needs, picked by name so a single unzip run fetches them.
    static func isLikelyPart(_ name: String) -> Bool {
        if name == "_rels/.rels" || name == "docProps/core.xml" { return true }
        let n = name.lowercased()
        if n.hasSuffix(".rels") { return n.hasSuffix("workbook.xml.rels") }
        return n.hasSuffix(".xml") && ["workbook", "sheet", "styles", "sharedstrings"].contains { n.contains($0) }
    }

    static func title(_ core: Data?) -> String? {
        guard let core, let t = XML.parse(core)?.first("title")?.text.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty else { return nil }
        return t
    }

    /// For each `cellXfs` style index, whether its number format shows a date.
    static func dateStyles(_ styles: Data?) -> [Bool] {
        guard let styles, let root = XML.parse(styles) else { return [] }
        var custom: [Int: Bool] = [:]
        for f in root.first("numFmts")?.children("numFmt") ?? [] {
            if let id = f.attr("numFmtId").flatMap({ Int($0) }) { custom[id] = isDateFormat(f.attr("formatCode") ?? "") }
        }
        return (root.first("cellXfs")?.children("xf") ?? []).map { xf in
            let id = xf.attr("numFmtId").flatMap { Int($0) } ?? 0
            return custom[id] ?? (14...22 ~= id || 45...47 ~= id)
        }
    }

    /// Whether a number format code has a date or time token (d, m, y, h, s) outside quoted
    /// literals, `[...]` colors/locales/elapsed units, and `\x`, `_x`, `*x` escapes.
    static func isDateFormat(_ code: String) -> Bool {
        var it = code.unicodeScalars.makeIterator()
        var quoted = false, bracketed = false
        while let c = it.next() {
            if quoted { if c == "\"" { quoted = false }; continue }
            if bracketed { if c == "]" { bracketed = false }; continue }
            switch c {
            case "\"": quoted = true
            case "[": bracketed = true
            case "\\", "_", "*": _ = it.next()
            case "d", "D", "m", "M", "y", "Y", "h", "H", "s", "S": return true
            default: break
            }
        }
        return false
    }

    /// An Excel serial day number as `yyyy-MM-dd`, plus ` HH:mm` when it has a time of day.
    /// Serials below 1 are times alone and render as `HH:mm`. Nil outside 0...9999-12-31.
    static func isoDate(_ serial: Double, date1904: Bool) -> String? {
        guard serial >= 0, serial < (date1904 ? 2_957_004 : 2_958_466) else { return nil }
        let minutes = Int((serial * 1440).rounded())
        let day = minutes / 1440, minute = minutes % 1440
        func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        let time = "\(two(minute / 60)):\(two(minute % 60))"
        if serial < 1 { return time }
        // 1900 system: day 1 is 1900-01-01, and Excel counts a nonexistent 1900-02-29 as day 60.
        let (y, m, d) = civil(fromUnixDay: date1904 ? day - 24_107 : day - (day < 61 ? 25_568 : 25_569))
        let date = "\(y)-\(two(m))-\(two(d))"
        return minute == 0 ? date : "\(date) \(time)"
    }

    /// Proleptic Gregorian (year, month, day) for a count of days since 1970-01-01 (Hinnant's algorithm).
    private static func civil(fromUnixDay days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, doy - (153 * mp + 2) / 5 + 1)
    }

    /// Integers without a fractional part, everything else in its shortest round-trip form.
    static func number(_ d: Double) -> String {
        d == d.rounded() && abs(d) < 1e15 ? Int64(d).description : d.description
    }

    /// Cell text that fits a tab-separated row: `_xHHHH_` escapes decoded, tabs and line breaks
    /// turned into spaces, whitespace-only text dropped.
    static func cellText(_ raw: String) -> String {
        var s = raw
        if s.utf8.contains(UInt8(ascii: "_")), s.contains("_x") {
            s = s.replacing(#/_x([0-9A-Fa-f]{4})_/#) { m in
                UInt32(m.1, radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
            }
        }
        if s.utf8.contains(where: { $0 == 9 || $0 == 10 || $0 == 13 }) {
            s = String(String.UnicodeScalarView(s.unicodeScalars.map { $0 == "\t" || $0 == "\n" || $0 == "\r" ? " " : $0 }))
        }
        return s.unicodeScalars.allSatisfy(\.properties.isWhitespace) ? "" : s
    }

    /// Zero-based column of a cell reference: `A1` → 0, `AB12` → 27.
    static func column(_ ref: String) -> Int? {
        var n = 0
        for b in ref.utf8 {
            switch b {
            case 65...90: n = n * 26 + Int(b) - 64
            case 97...122: n = n * 26 + Int(b) - 96
            default: return n > 0 ? n - 1 : nil
            }
            if n > 1 << 20 { return nil }
        }
        return n > 0 ? n - 1 : nil
    }
}

/// Element names with the SpreadsheetML prefix removed, for generators that write `x:row`.
/// The prefix is the root element's; elements from other namespaces keep theirs and never match.
private struct LocalNames {
    private var prefix: String?
    mutating func callAsFunction(_ name: String) -> String {
        if prefix == nil { prefix = name.firstIndex(of: ":").map { String(name[...$0]) } ?? "" }
        guard let p = prefix, !p.isEmpty, name.hasPrefix(p) else { return name }
        return String(name.dropFirst(p.count))
    }
}

/// Streams one worksheet's cells into tab-separated rows, stopping at `maxCellsPerSheet`.
/// Rows and cells come in document order, which Excel requires to be ascending.
private final class SheetParser: NSObject, XMLParserDelegate {
    struct Context { var shared: [String]; var dateStyles: [Bool]; var date1904: Bool }

    static func read(_ data: Data, _ context: Context) -> (text: String, complete: Bool) {
        let p = SheetParser(context)
        let xml = XMLParser(data: data)
        xml.shouldResolveExternalEntities = false
        xml.delegate = p
        let complete = xml.parse() // A truncated or capped sheet keeps the rows read so far.
        p.endRow()
        return (p.out, complete)
    }

    static func value(of data: Data, _ context: Context, at address: String) -> (value: String?, complete: Bool) {
        let parser = SheetParser(context)
        parser.desiredReference = address
        let xml = XMLParser(data: data)
        xml.shouldResolveExternalEntities = false
        xml.delegate = parser
        let complete = xml.parse()
        return (parser.foundValue, complete)
    }

    private let ctx: Context
    private var local = LocalNames()
    private var out = "", line = "", prev = -1, count = 0
    // The open cell.
    private var col = -1, type = "", style = 0, value = ""
    private var inCell = false, inInline = false, collecting = false, phonetic = 0
    private var desiredReference: String?, currentReference = "", foundValue: String?
    private var rowNumber = 0

    private init(_ context: Context) { ctx = context }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch local(name) {
        case "c":
            if let r = attributes["r"], let c = XLSXExtractor.column(r) { col = c } else { col += 1 }
            var number = col + 1, letters = ""
            while number > 0 { number -= 1; letters = String(UnicodeScalar(65 + number % 26)!) + letters; number /= 26 }
            currentReference = (attributes["r"] ?? letters + String(rowNumber)).uppercased()
            type = attributes["t"] ?? ""
            if let s = attributes["s"], let i = Int(s) { style = i } else { style = 0 }
            value = ""
            inCell = true
        case "v": collecting = inCell && !inInline
        case "is": inInline = inCell
        case "t": collecting = inInline && phonetic == 0
        case "rPh": phonetic += 1
        case "row": col = -1; rowNumber = attributes["r"].flatMap(Int.init) ?? rowNumber + 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch local(name) {
        case "v", "t": collecting = false
        case "c": endCell(parser)
        case "row": endRow()
        case "rPh": phonetic -= 1
        case "is": inInline = false
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collecting { value += string }
    }

    /// Appends the cell to the row, padding skipped columns with empty fields so columns line up,
    /// except runs wider than `maxPaddedGap`, which become one tab.
    private func endCell(_ parser: XMLParser) {
        inCell = false
        if let desiredReference {
            if currentReference == desiredReference { foundValue = render() ?? ""; parser.abortParsing() }
            return
        }
        guard !value.isEmpty, count < XLSXExtractor.maxCellsPerSheet, let text = render(), !text.isEmpty else { return }
        let gap = col - prev - 1
        let tabs = gap > XLSXExtractor.maxPaddedGap ? 1 : max(gap, 0) + (prev < 0 ? 0 : 1)
        if tabs == 1 { line += "\t" } else if tabs > 1 { line += String(repeating: "\t", count: tabs) }
        line += text
        prev = max(col, prev)
        count += 1
        if count == XLSXExtractor.maxCellsPerSheet { parser.abortParsing() }
    }

    private func endRow() {
        if !line.isEmpty {
            if !out.isEmpty { out += "\n" }
            out += line
            line = ""
        }
        prev = -1
    }

    /// The open cell's value as shown: values only, never formulas.
    private func render() -> String? {
        switch type {
        case "s":
            guard let i = Int(value), ctx.shared.indices.contains(i) else { return nil }
            return ctx.shared[i]
        case "b": return value == "1" ? "TRUE" : "FALSE"
        case "str", "inlineStr", "e", "d": return XLSXExtractor.cellText(value)
        default:
            guard let d = Double(value), d.isFinite else { return XLSXExtractor.cellText(value) }
            if ctx.dateStyles.indices.contains(style), ctx.dateStyles[style],
               let date = XLSXExtractor.isoDate(d, date1904: ctx.date1904) { return date }
            return XLSXExtractor.number(d)
        }
    }
}

/// Streams `sharedStrings.xml`. Each `si` is its `t`, or its rich-text runs' `r/t` joined,
/// without `rPh` phonetic guides.
private final class SharedStringsParser: NSObject, XMLParserDelegate {
    static func strings(_ data: Data) -> [String] {
        let p = SharedStringsParser()
        let xml = XMLParser(data: data)
        xml.shouldResolveExternalEntities = false
        xml.delegate = p
        _ = xml.parse()
        return p.strings
    }

    private var local = LocalNames()
    private var strings: [String] = []
    private var item = "", inItem = false, collecting = false, phonetic = 0

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch local(name) {
        case "si": item = ""; inItem = true
        case "t": collecting = inItem && phonetic == 0
        case "rPh": phonetic += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch local(name) {
        case "si": strings.append(XLSXExtractor.cellText(item)); inItem = false
        case "t": collecting = false
        case "rPh": phonetic -= 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collecting { item += string }
    }
}
