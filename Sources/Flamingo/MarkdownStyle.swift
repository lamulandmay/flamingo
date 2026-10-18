import AppKit
import CoreText
import FlamingoDesign

/// The typeface notes are written in, picked in Settings ▸ General. Code and plain text files
/// stay monospaced.
enum WritingFont: String, CaseIterable {
    case system, newYork, helvetica, arial, avenir

    var title: String {
        switch self {
        case .system: "San Francisco"
        case .newYork: "New York"
        case .helvetica: "Helvetica Neue"
        case .arial: "Arial"
        case .avenir: "Avenir Next"
        }
    }

    static let sizes: [CGFloat] = [14, 15, 16, 17, 18, 20]

    func font(_ size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        let font: NSFont
        switch self {
        case .system, .newYork:
            let system = NSFont.systemFont(ofSize: size, weight: weight)
            let serif = self == .newYork ? system.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } : nil
            font = serif ?? system
        case .helvetica, .arial, .avenir:
            let w = weight.rawValue >= NSFont.Weight.bold.rawValue ? 9 : weight.rawValue >= NSFont.Weight.semibold.rawValue ? 8 : 5
            font = NSFontManager.shared.font(withFamily: title, traits: [], weight: w, size: size)
                ?? .systemFont(ofSize: size, weight: weight)
        }
        return italic ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
    }
}

extension Notification.Name {
    /// Settings changed the writing font or size; open notes restyle.
    static let writingFontChanged = Notification.Name("FlamingoWritingFontChanged")
}

extension NSAttributedString.Key {
    /// A list marker, drawn as a bullet.
    static let markdownBullet = NSAttributedString.Key("FlamingoMarkdownBullet")
    /// `[ ]` or `[x]`, drawn as a box; the value is whether it's ticked.
    static let markdownCheckbox = NSAttributedString.Key("FlamingoMarkdownCheckbox")
    /// A fenced code block, drawn on a card. One value per block, so neighbours stay apart.
    static let markdownCodeBlock = NSAttributedString.Key("FlamingoMarkdownCodeBlock")
    /// `code` in a line, drawn on a pill the height of its letters.
    static let markdownInlineCode = NSAttributedString.Key("FlamingoMarkdownInlineCode")
}

/// Styles Markdown in place as it's typed: the first line as the title, headings, lists with
/// bullets and hanging indents, bold, italic, underline, code. The text never changes; the
/// syntax stays, quiet in tertiary, the way Bear and iA Writer show it.
@MainActor
final class MarkdownStyler: NSObject, @preconcurrency NSTextStorageDelegate {
    static let extensions: Set<String> = ["md", "markdown"]

    var font = Defaults.writingFont { didSet { fonts.removeAll() } }
    var size = Defaults.writingSize { didSet { fonts.removeAll() } }
    private(set) var structure = Structure()
    private var fonts: [FontKey: NSFont] = [:]

    /// One indent level: a tab, or four spaces.
    var indentStep: CGFloat { round(size * 1.75) }
    /// A readable line: about 70 characters.
    var measure: CGFloat { round(size * 45) }

    // MARK: Structure

    /// The lines whose meaning depends on lines above them: frontmatter, the title (the first
    /// line after any frontmatter), and fenced code. Compared after every edit; when it moves,
    /// everything restyles, otherwise just the edited lines.
    struct Structure: Equatable {
        struct Block: Equatable { var open: Int; var close: Int? }
        private static let fenceCharacters = CharacterSet(charactersIn: "`~")
        /// Where the frontmatter ends: the start of the line after its closing `---`.
        var frontmatterEnd: Int?
        var title = 0
        /// Line starts of each block's fences.
        var blocks: [Block] = []

        static func of(_ ns: NSString) -> Structure {
            var s = Structure()
            func lineEnd(_ p: Int) -> Int { NSMaxRange(ns.lineRange(for: NSRange(location: p, length: 0))) }
            func trimmed(_ p: Int) -> String {
                var start = 0, end = 0
                ns.getLineStart(&start, end: nil, contentsEnd: &end, for: NSRange(location: p, length: 0))
                return ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespaces)
            }
            if ns.length >= 3, trimmed(0) == "---" {
                var p = lineEnd(0)
                while p < ns.length {
                    let line = trimmed(p)
                    p = lineEnd(p)
                    if line == "---" || line == "..." { s.frontmatterEnd = p; break }
                }
            }
            s.title = s.frontmatterEnd ?? 0
            var search = lineEnd(s.title)
            var open: (start: Int, char: unichar, count: Int)?
            while search < ns.length {
                // One pass for either fence character; a line that doesn't open with one is skipped whole.
                let hit = ns.rangeOfCharacter(from: Self.fenceCharacters, options: [], range: NSRange(location: search, length: ns.length - search))
                guard hit.location != NSNotFound else { break }
                let start = ns.lineRange(for: NSRange(location: hit.location, length: 0)).location
                search = lineEnd(hit.location)
                guard hit.location - start <= 3, ns.substring(with: NSRange(location: start, length: hit.location - start)).allSatisfy({ $0 == " " }) else { continue }
                let char = ns.character(at: hit.location)
                var count = 0
                while hit.location + count < ns.length, ns.character(at: hit.location + count) == char { count += 1 }
                guard count >= 3 else { continue }
                var contentsEnd = 0
                ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: hit.location, length: 0))
                let info = ns.substring(with: NSRange(location: hit.location + count, length: contentsEnd - hit.location - count))
                if let o = open {
                    if char == o.char, count >= o.count, info.trimmingCharacters(in: .whitespaces).isEmpty {
                        s.blocks.append(Block(open: o.start, close: start)); open = nil
                    }
                } else if !(char == 0x60 && info.contains("`")) {
                    open = (start, char, count)
                }
            }
            if let o = open { s.blocks.append(Block(open: o.start, close: nil)) }
            return s
        }

        /// Equal to `other` once this structure's positions move with an edit. A line start at
        /// the edit stays put, as text typed there joins its line.
        func matches(_ other: Structure, edited: NSRange, delta: Int) -> Bool {
            let oldEnd = NSMaxRange(edited) - delta
            func shift(_ p: Int?) -> Int?? {
                guard let p else { return .some(nil) }
                if p <= edited.location { return p }
                return p >= oldEnd ? p + delta : nil
            }
            guard let fm = shift(frontmatterEnd), fm == other.frontmatterEnd,
                  let t = shift(title), t == other.title, blocks.count == other.blocks.count else { return false }
            for (a, b) in zip(blocks, other.blocks) {
                guard let o = shift(a.open), o == b.open, let c = shift(a.close), c == b.close else { return false }
            }
            return true
        }

        enum Kind: Equatable { case frontmatter, title, fence(Int), code(Int), body }

        func kind(ofLineAt start: Int) -> Kind {
            if let end = frontmatterEnd, start < end { return .frontmatter }
            if start == title { return .title }
            // The last block opening at or before this line.
            var low = 0, high = blocks.count
            while low < high { let mid = (low + high) / 2; if blocks[mid].open <= start { low = mid + 1 } else { high = mid } }
            guard low > 0 else { return .body }
            let block = blocks[low - 1]
            if start == block.open || start == block.close { return .fence(block.open) }
            if block.close.map({ start < $0 }) ?? true { return .code(block.open) }
            return .body
        }
    }

    // MARK: Restyling

    /// Lines an edit left to restyle. Styling waits until the edit is done: attributes changed
    /// past the typed characters while it's processed make AppKit move the caret to their end.
    private var pending: NSRange?

    func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let ns = textStorage.string as NSString
        let old = structure
        structure = Structure.of(ns)
        // The edited lines and one each side: a new line break restyles its neighbours.
        var region = ns.lineRange(for: editedRange)
        if region.location > 0 { region = NSUnionRange(region, ns.lineRange(for: NSRange(location: region.location - 1, length: 0))) }
        if NSMaxRange(region) < ns.length { region = NSUnionRange(region, ns.lineRange(for: NSRange(location: NSMaxRange(region), length: 0))) }
        // A moved fence or title: everything.
        if !old.matches(structure, edited: editedRange, delta: delta) { region = NSRange(location: 0, length: ns.length) }
        // Edits before a flush (an input method composing) add up; the older range grows with this one.
        if let earlier = pending {
            let grown = NSRange(location: earlier.location, length: max(0, earlier.length + delta))
            region = NSIntersectionRange(NSUnionRange(grown, region), NSRange(location: 0, length: ns.length))
        }
        pending = region
        // The text view flushes in didChangeText; anything else is caught on the next turn.
        DispatchQueue.main.async { [weak self, weak textStorage] in
            if let self, let textStorage { self.flush(textStorage) }
        }
    }

    /// True while styling must wait: an input method's marked text carries its own underline.
    var isComposing: () -> Bool = { false }

    /// Styles what the last edits left. Called once an edit is complete, never during one.
    func flush(_ storage: NSTextStorage) {
        guard let region = pending, !isComposing() else { return }
        pending = nil
        let clamped = NSIntersectionRange(region, NSRange(location: 0, length: storage.length))
        guard clamped.length > 0 else { return }
        storage.beginEditing()
        style(storage, clamped)
        storage.endEditing()
    }

    func restyleAll(_ storage: NSTextStorage) {
        pending = nil
        structure = Structure.of(storage.string as NSString)
        storage.beginEditing()
        style(storage, NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }

    /// What typing at this point starts out as, until the line restyles: the title's size on
    /// the first line, a heading's on a heading, body text elsewhere. Never a bullet or a box.
    func typingAttributes(at location: Int, in ns: NSString) -> [NSAttributedString.Key: Any] {
        let line = MarkdownSyntax.line(in: ns, at: location)
        let kind = structure.kind(ofLineAt: line.range.location)
        switch kind {
        case .title: return lineAttributes(titleFont, Line.title)
        case .fence, .code, .frontmatter: return lineAttributes(mono(size * 0.85), Line.code)
        case .body: return line.heading.map { lineAttributes(headingFont($0), Line.heading) } ?? base
        }
    }

    private func style(_ storage: NSTextStorage, _ region: NSRange) {
        guard region.length > 0 else { return }
        let ns = storage.string as NSString
        storage.setAttributes(base, range: region)
        var position = region.location
        while position < NSMaxRange(region) {
            var start = 0, end = 0, contentsEnd = 0
            ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: position, length: 0))
            styleLine(storage, ns, NSRange(location: start, length: contentsEnd - start), whole: NSRange(location: start, length: end - start))
            guard end > position else { break }
            position = end
        }
    }

    private func styleLine(_ storage: NSTextStorage, _ ns: NSString, _ range: NSRange, whole: NSRange) {
        switch structure.kind(ofLineAt: range.location) {
        case .frontmatter:
            storage.addAttributes(lineAttributes(mono(size * 0.8), Line.frontmatter), range: whole)
            dim(storage, whole)
        case .fence(let block):
            // Room outside the card: above the opening fence, below the closing one.
            let code = lineAttributes(mono(size * 0.85), Line.code) { p in
                let inset = round(self.size * 0.9)
                p.firstLineHeadIndent = inset; p.headIndent = inset; p.tailIndent = -inset
                if range.location == block { p.paragraphSpacingBefore = round(self.size * 0.75) } else { p.paragraphSpacing = round(self.size * 0.75) }
            }
            storage.addAttributes(code.merging([.markdownCodeBlock: block, .foregroundColor: Theme.NS.textTertiary]) { $1 }, range: whole)
        case .code(let block):
            let code = lineAttributes(mono(size * 0.85), Line.code) { p in
                let inset = round(self.size * 0.9)
                p.firstLineHeadIndent = inset; p.headIndent = inset; p.tailIndent = -inset
            }
            storage.addAttributes(code.merging([.markdownCodeBlock: block]) { $1 }, range: whole)
        case .title:
            let line = MarkdownSyntax.parse(ns, range)
            storage.addAttributes(lineAttributes(titleFont, Line.title) { $0.paragraphSpacing = round(self.size * 0.5) }, range: whole)
            if line.heading != nil { dim(storage, NSRange(location: range.location, length: line.content.location - range.location)) }
            styleInline(storage, ns, line.content)
        case .body:
            styleBody(storage, ns, range, whole: whole)
        }
    }

    private static let rule = try! NSRegularExpression(pattern: #"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)

    private func styleBody(_ storage: NSTextStorage, _ ns: NSString, _ range: NSRange, whole: NSRange) {
        guard range.length > 0 else { return }
        if Self.rule.firstMatch(in: ns as String, range: range) != nil { return dim(storage, range) }
        let line = MarkdownSyntax.parse(ns, range)
        dim(storage, line.quote)
        if line.quote.length > 0 {
            storage.addAttribute(.foregroundColor, value: Theme.NS.textSecondary, range: NSRange(location: NSMaxRange(line.quote), length: NSMaxRange(range) - NSMaxRange(line.quote)))
        }
        if let level = line.heading {
            storage.addAttributes(lineAttributes(headingFont(level), Line.heading) { $0.paragraphSpacingBefore = round(self.size * (level <= 2 ? 0.7 : 0.4)) }, range: whole)
            dim(storage, NSRange(location: NSMaxRange(line.indent), length: line.content.location - NSMaxRange(line.indent)))
        } else if let marker = line.marker {
            styleList(storage, ns, line, marker, whole: whole)
        } else if line.quote.length > 0 {
            storage.addAttribute(.paragraphStyle, value: hanging(width(ns.substring(with: line.quote), body)), range: whole)
        }
        styleInline(storage, ns, line.content)
    }

    private func styleList(_ storage: NSTextStorage, _ ns: NSString, _ line: MarkdownSyntax.Line, _ marker: NSRange, whole: NSRange) {
        let space = width(" ", body), step = indentStep
        var x = width(ns.substring(with: line.quote), body)
        // Spaces in an indent are widened to a quarter step each, so four make a level.
        for i in 0..<line.indent.length {
            let at = line.indent.location + i
            if ns.character(at: at) == 9 {
                x = (floor(x / step + 0.01) + 1) * step
            } else {
                x += step / 4
                storage.addAttribute(.kern, value: step / 4 - space, range: NSRange(location: at, length: 1))
            }
        }
        let gapEnd = line.checkbox?.location ?? line.content.location
        let gap = NSRange(location: NSMaxRange(marker), length: gapEnd - NSMaxRange(marker))
        if line.checkbox != nil {
            // The box stands in for the bullet: `- ` takes no room and isn't drawn.
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: marker.location, length: gapEnd - marker.location))
            for i in marker.location..<gapEnd {
                storage.addAttribute(.kern, value: -width(ns.substring(with: NSRange(location: i, length: 1)), body), range: NSRange(location: i, length: 1))
            }
        } else {
            storage.addAttribute(.foregroundColor, value: Theme.NS.textSecondary, range: marker)
            if line.number == nil {
                storage.addAttribute(.markdownBullet, value: true, range: marker)
                x += width("•", body)
            } else {
                x += width(ns.substring(with: marker), body)
            }
            x += width(ns.substring(with: gap), body)
        }
        if let box = line.checkbox {
            let checked = ns.substring(with: NSRange(location: box.location + 1, length: 1)) != " "
            storage.addAttributes([.markdownCheckbox: checked, .foregroundColor: NSColor.clear], range: box)
            // Room for the drawn box, which is wider than `[ ]`.
            storage.addAttribute(.kern, value: round(size * 0.3), range: NSRange(location: NSMaxRange(box) - 1, length: 1))
            x += width(ns.substring(with: NSRange(location: box.location, length: line.content.location - box.location)), body) + round(size * 0.3)
            if checked {
                storage.addAttributes([.foregroundColor: Theme.NS.textTertiary, .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                       .strikethroughColor: Theme.NS.textTertiary], range: line.content)
            }
        }
        storage.addAttribute(.paragraphStyle, value: hanging(x), range: whole)
    }

    private func styleInline(_ storage: NSTextStorage, _ ns: NSString, _ range: NSRange) {
        guard range.length > 0 else { return }
        for span in MarkdownSyntax.spans(in: ns, range) {
            switch span.kind {
            case .strong: restyleFonts(storage, span.content, bold: true, italic: false)
            case .emphasis: restyleFonts(storage, span.content, bold: false, italic: true)
            case .strongEmphasis: restyleFonts(storage, span.content, bold: true, italic: true)
            case .underline:
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: span.content)
            case .strike:
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                       .foregroundColor: Theme.NS.textSecondary], range: span.content)
            case .code:
                let current = storage.attribute(.font, at: span.range.location, effectiveRange: nil) as? NSFont
                storage.addAttributes([.font: mono((current?.pointSize ?? size) * 0.88), .markdownInlineCode: true], range: span.range)
            case .link, .wikilink, .url:
                storage.addAttribute(.foregroundColor, value: Theme.NS.accent, range: span.content)
            }
            for marker in span.markers where marker.length > 0 { dim(storage, marker) }
        }
    }

    /// Bold or italic on top of whatever size and weight the run already has.
    private func restyleFonts(_ storage: NSTextStorage, _ range: NSRange, bold: Bool, italic: Bool) {
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
            guard let current = value as? NSFont, !current.isFixedPitch else { return }
            let traits = current.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
            let weight = (traits?[.weight] as? CGFloat) ?? 0
            let font = self.font(current.pointSize, weight: bold ? max(weight, NSFont.Weight.bold.rawValue) : weight,
                                 italic: italic || current.fontDescriptor.symbolicTraits.contains(.italic))
            storage.addAttribute(.font, value: font, range: run)
        }
    }

    private func dim(_ storage: NSTextStorage, _ range: NSRange) {
        guard range.length > 0 else { return }
        storage.addAttribute(.foregroundColor, value: Theme.NS.textTertiary, range: range)
    }

    // MARK: Type

    private struct FontKey: Hashable { var size: CGFloat; var weight: CGFloat; var italic: Bool }

    func font(_ size: CGFloat, weight: CGFloat = 0, italic: Bool = false) -> NSFont {
        let key = FontKey(size: size, weight: weight, italic: italic)
        if let cached = fonts[key] { return cached }
        let made = font.font(size, weight: NSFont.Weight(weight), italic: italic)
        fonts[key] = made
        return made
    }

    private func mono(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: round(size * 2) / 2, weight: .regular) }

    var body: NSFont { font(size) }
    var titleFont: NSFont { font(round(size * 1.75), weight: NSFont.Weight.bold.rawValue) }

    func headingFont(_ level: Int) -> NSFont {
        let scale: [CGFloat] = [1.5, 1.3, 1.15, 1.05, 1, 1]
        return font(round(size * scale[min(max(level, 1), 6) - 1]), weight: (level <= 2 ? NSFont.Weight.bold : .semibold).rawValue)
    }

    private func width(_ text: String, _ font: NSFont) -> CGFloat {
        var x: CGFloat = 0
        for part in text.split(separator: "\t", omittingEmptySubsequences: false).enumerated() {
            if part.offset > 0 { x = (floor(x / indentStep + 0.01) + 1) * indentStep }
            x += (String(part.element) as NSString).size(withAttributes: [.font: font]).width
        }
        return x
    }

    var base: [NSAttributedString.Key: Any] { lineAttributes(body, Line.body) }

    /// Line heights, as multiples of each font's own.
    private enum Line {
        static let body: CGFloat = 1.5, title: CGFloat = 1.2, heading: CGFloat = 1.3, code: CGFloat = 1.45, frontmatter: CGFloat = 1.3
    }

    private static let metrics = NSLayoutManager()

    /// A fixed line height with the text centred in it, so the caret and the selection sit
    /// evenly around the letters instead of hanging below them.
    private func lineAttributes(_ font: NSFont, _ factor: CGFloat, _ adjust: (NSMutableParagraphStyle) -> Void = { _ in }) -> [NSAttributedString.Key: Any] {
        let natural = Self.metrics.defaultLineHeight(for: font), height = round(natural * factor)
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = height; p.maximumLineHeight = height
        p.defaultTabInterval = indentStep; p.tabStops = []
        adjust(p)
        return [.font: font, .foregroundColor: Theme.NS.text, .paragraphStyle: p, .baselineOffset: ((height - natural) / 2).rounded()]
    }

    private func hanging(_ indent: CGFloat) -> NSParagraphStyle {
        let p = (base[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
        p.headIndent = indent
        return p
    }
}

/// Draws what the styler marks: bullets in place of `-`, boxes in place of `[ ]`, and cards
/// behind fenced code. TextKit 1, which lets glyphs be swapped and backgrounds drawn.
final class MarkdownLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = textStorage, glyphRange.length > 0 else { return 0 }
        let first = characterIndexes[0], last = characterIndexes[glyphRange.length - 1]
        guard last < storage.length else { return 0 }
        var bulleted = false
        storage.enumerateAttribute(.markdownBullet, in: NSRange(location: first, length: last - first + 1)) { value, _, stop in
            if value != nil { bulleted = true; stop.pointee = true }
        }
        var dot: UniChar = 0x2022, bullet: CGGlyph = 0
        guard bulleted, CTFontGetGlyphsForCharacters(font as CTFont, &dot, &bullet, 1) else { return 0 }
        var swapped = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
        for i in 0..<glyphRange.length where storage.attribute(.markdownBullet, at: characterIndexes[i], effectiveRange: nil) != nil {
            swapped[i] = bullet
        }
        setGlyphs(swapped, properties: properties, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        // Under the selection, which super draws.
        drawCodeBlocks(glyphsToShow, at: origin)
        drawInlineCode(glyphsToShow, at: origin)
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        storage.enumerateAttribute(.markdownCheckbox, in: characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)) { value, range, _ in
            guard let checked = value as? Bool, let box = checkboxRect(for: range)?.offsetBy(dx: origin.x, dy: origin.y) else { return }
            let radius = round(box.width * 0.24)
            if checked {
                Theme.NS.accent.setFill()
                NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: box.minX + box.width * 0.26, y: box.midY + box.height * 0.02))
                tick.line(to: NSPoint(x: box.minX + box.width * 0.43, y: box.maxY - box.height * 0.27))
                tick.line(to: NSPoint(x: box.maxX - box.width * 0.24, y: box.minY + box.height * 0.29))
                tick.lineWidth = max(1.5, box.width * 0.12)
                tick.lineCapStyle = .round; tick.lineJoinStyle = .round
                Theme.NS.onAccent.setStroke()
                tick.stroke()
            } else {
                let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.6, dy: 0.6), xRadius: radius, yRadius: radius)
                path.lineWidth = 1.2
                Theme.NS.textTertiary.setStroke()
                path.stroke()
            }
        }
    }

    /// The box over a `[ ]`, in text container coordinates: cap-height centred on the line.
    func checkboxRect(for range: NSRange) -> NSRect? {
        guard let storage = textStorage, let container = textContainers.first, NSMaxRange(range) <= storage.length else { return nil }
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let bounds = boundingRect(forGlyphRange: NSRange(location: glyphs.location, length: min(glyphs.length, 3)), in: container)
        let baseline = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil).minY + location(forGlyphAt: glyphs.location).y
        let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 16)
        let side = round(font.capHeight + font.pointSize * 0.3)
        return NSRect(x: round(bounds.midX - side / 2), y: round(baseline - font.capHeight / 2 - side / 2), width: side, height: side)
    }

    private func drawCodeBlocks(_ glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return }
        var drawn = Set<Int>()
        storage.enumerateAttribute(.markdownCodeBlock, in: characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)) { value, range, _ in
            guard let id = value as? Int, drawn.insert(id).inserted else { return }
            var block = NSRange()
            storage.attribute(.markdownCodeBlock, at: range.location, longestEffectiveRange: &block, in: NSRange(location: 0, length: storage.length))
            // Used rects leave out the spacing around the block, so the card sits clear of its neighbours.
            var rect = NSRect.null
            enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: block, actualCharacterRange: nil)) { _, used, _, _, _ in
                rect = rect.union(used)
            }
            guard !rect.isNull else { return }
            rect.origin.x = 0
            rect.size.width = container.size.width
            Theme.NS.fill.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: -Theme.Space.xs).offsetBy(dx: origin.x, dy: origin.y),
                         xRadius: Theme.Radius.m, yRadius: Theme.Radius.m).fill()
        }
    }

    /// A pill around each line's part of a code span, from its letters' ascender to descender.
    private func drawInlineCode(_ glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage else { return }
        storage.enumerateAttribute(.markdownInlineCode, in: characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)) { value, range, _ in
            guard value != nil else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, container, line, _ in
                let part = NSIntersectionRange(glyphs, line)
                guard part.length > 0, let font = storage.attribute(.font, at: self.characterIndexForGlyph(at: part.location), effectiveRange: nil) as? NSFont else { return }
                let bounds = self.boundingRect(forGlyphRange: part, in: container)
                let baseline = fragment.minY + self.location(forGlyphAt: part.location).y
                let pill = NSRect(x: bounds.minX - 1, y: baseline - font.ascender - 1.5, width: bounds.width + 2, height: font.ascender - font.descender + 3)
                Theme.NS.fill.setFill()
                NSBezierPath(roundedRect: pill.offsetBy(dx: origin.x, dy: origin.y), xRadius: Theme.Radius.s, yRadius: Theme.Radius.s).fill()
            }
        }
    }
}

/// The Markdown editor: the pane's text view on TextKit 1 with the styler and layout manager,
/// a centred column, and keys that keep lists going and toggle bold, italic and underline.
final class MarkdownTextView: PaneTextView {
    let styler = MarkdownStyler()
    private var fontObserver: NSObjectProtocol?

    static func scrollView() -> NSScrollView {
        let storage = NSTextStorage()
        let layout = MarkdownLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = MarkdownTextView(frame: .zero, textContainer: container)
        storage.delegate = view.styler
        view.styler.isComposing = { [weak view] in view?.hasMarkedText() == true }
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.font = view.styler.body
        view.typingAttributes = view.styler.base
        view.fontObserver = NotificationCenter.default.addObserver(forName: .writingFontChanged, object: nil, queue: .main) { [weak view] _ in
            MainActor.assumeIsolated { view?.restyle() }
        }
        // As NSTextView.scrollableTextView() sets it up: the text view fills the pane, however short the note.
        view.autoresizingMask = [.width, .height]
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = view
        return scroll
    }

    deinit { fontObserver.map(NotificationCenter.default.removeObserver) }

    private func restyle() {
        styler.font = Defaults.writingFont
        styler.size = Defaults.writingSize
        if let storage = textStorage { styler.restyleAll(storage) }
        typingAttributes = styler.typingAttributes(at: selectedRange().location, in: string as NSString)
        setFrameSize(frame.size)
    }

    /// Wide panes keep the text to a readable column, centred.
    override func setFrameSize(_ newSize: NSSize) {
        let side = max(Theme.Space.xl, floor((newSize.width - styler.measure) / 2))
        if textContainerInset.width != side { textContainerInset = NSSize(width: side, height: Theme.Space.xxl) }
        super.setFrameSize(newSize)
    }

    override func didChangeText() {
        if let textStorage { styler.flush(textStorage) }
        super.didChangeText()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !stillSelecting else { return }
        typingAttributes = styler.typingAttributes(at: selectedRange().location, in: string as NSString)
    }

    // MARK: Keys

    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText(), let edit = MarkdownEditing.newline(in: string as NSString, selection: selectedRange()) else {
            return super.insertNewline(sender)
        }
        apply(edit)
    }

    override func deleteBackward(_ sender: Any?) {
        guard !hasMarkedText(), let edit = MarkdownEditing.deleteBackward(in: string as NSString, selection: selectedRange()) else {
            return super.deleteBackward(sender)
        }
        apply(edit)
    }

    override func insertTab(_ sender: Any?) {
        guard !hasMarkedText(), let edit = MarkdownEditing.indent(in: string as NSString, selection: selectedRange(), outdent: false) else {
            return super.insertTab(sender)
        }
        apply(edit)
    }

    override func insertBacktab(_ sender: Any?) {
        guard !hasMarkedText(), let edit = MarkdownEditing.indent(in: string as NSString, selection: selectedRange(), outdent: true) else {
            return super.insertBacktab(sender)
        }
        apply(edit)
    }

    @objc func toggleMarkdownBold(_ sender: Any?) { toggle(.bold) }
    @objc func toggleMarkdownItalic(_ sender: Any?) { toggle(.italic) }
    @objc func toggleMarkdownUnderline(_ sender: Any?) { toggle(.underline) }

    private func toggle(_ style: MarkdownEditing.Inline) {
        guard isEditable, !hasMarkedText() else { return }
        apply(MarkdownEditing.toggle(style, in: string as NSString, selection: selectedRange()))
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleMarkdownBold(_:)), #selector(toggleMarkdownItalic(_:)), #selector(toggleMarkdownUnderline(_:)):
            return isEditable
        default:
            return super.validateMenuItem(item)
        }
    }

    /// One undo step per edit, never merged into the typing around it.
    func apply(_ edit: MarkdownEdit) {
        if edit.changesText {
            breakUndoCoalescing()
            guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
            textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
            didChangeText()
            breakUndoCoalescing()
        }
        if let selection = edit.selection {
            setSelectedRange(selection)
            scrollRangeToVisible(selection)
        }
    }

    // MARK: Checkboxes

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard event.clickCount == 1, let index = checkbox(at: point),
              let edit = MarkdownEditing.toggleCheckbox(in: string as NSString, at: index) else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        apply(edit)
    }

    private func checkbox(at point: NSPoint) -> Int? {
        guard let layout = layoutManager as? MarkdownLayoutManager, let container = textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let index = layout.characterIndexForGlyph(at: layout.glyphIndex(for: p, in: container))
        var box = NSRange()
        guard index < storage.length, storage.attribute(.markdownCheckbox, at: index, effectiveRange: &box) != nil,
              layout.checkboxRect(for: box)?.insetBy(dx: -4, dy: -4).contains(p) == true else { return nil }
        return index
    }
}
