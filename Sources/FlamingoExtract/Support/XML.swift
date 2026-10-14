import Foundation

/// A small read-only element tree built with `XMLParser`. Element and attribute names are kept
/// as written (`a:t`, `r:id`); lookups go by local name so files that bind unusual prefixes
/// (`ns0:t`) still match. Character data lands on the element that directly contains it.
/// External entities are never resolved.
final class XElement {
    let name: String
    let localName: String
    let attributes: [String: String]
    fileprivate(set) var children: [XElement] = []
    fileprivate(set) var text = ""
    fileprivate(set) weak var parent: XElement?

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.localName = name.split(separator: ":", maxSplits: 1).last.map(String.init) ?? name
        self.attributes = attributes
    }

    /// Attribute by exact name, else by local name (`attr("id")` finds `r:id` only if there's no plain `id`).
    func attr(_ name: String) -> String? {
        if let v = attributes[name] { return v }
        let suffix = ":" + name
        return attributes.first { $0.key.hasSuffix(suffix) }?.value
    }

    /// A prefixed attribute by local name only, skipping an unprefixed one: `p:sldId` has both `id` and `r:id`.
    func prefixedAttr(_ localName: String) -> String? {
        let suffix = ":" + localName
        return attributes.first { $0.key.hasSuffix(suffix) }?.value
    }

    func first(_ local: String) -> XElement? { children.first { $0.localName == local } }
    func children(_ local: String) -> [XElement] { children.filter { $0.localName == local } }

    /// Follows a path of local names through first-matching children: `el.path("nvSpPr", "nvPr", "ph")`.
    func path(_ locals: String...) -> XElement? {
        var e: XElement? = self
        for l in locals { e = e?.first(l) }
        return e
    }

    /// Every descendant with this local name, in document order.
    func descendants(_ local: String) -> [XElement] {
        var out: [XElement] = []
        walk { if $0.localName == local { out.append($0) }; return true }
        return out
    }

    func firstDescendant(_ local: String) -> XElement? {
        var found: XElement?
        walk { if found == nil, $0.localName == local { found = $0 }; return found == nil }
        return found
    }

    /// All character data beneath this element: its own text, then each child's. Exact for leaves
    /// and runs; for containers, collect the leaves you mean (`a:t`, `w:t`) so indentation and
    /// interleaving don't leak in.
    var allText: String {
        var s = ""
        func go(_ e: XElement) { s += e.text; e.children.forEach(go) }
        go(self)
        return s
    }

    /// Depth-first, pre-order, excluding self. Return false from `visit` to skip an element's children.
    func walk(_ visit: (XElement) -> Bool) {
        for c in children where visit(c) { c.walk(visit) }
    }
}

enum XML {
    /// Parses a whole document. Returns the root element, or nil if the data isn't well-formed XML.
    static func parse(_ data: Data) -> XElement? {
        let b = TreeBuilder()
        let p = XMLParser(data: data)
        p.shouldProcessNamespaces = false
        p.shouldReportNamespacePrefixes = false
        p.shouldResolveExternalEntities = false
        p.delegate = b
        guard p.parse() || b.root != nil, let root = b.root else { return nil }
        return root
    }

    /// Decodes the five predefined entities and numeric character references, for text that
    /// arrives escaped outside an XML parser (HTML, plist dumps).
    static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let ent = s[s.index(after: i)..<semi]
                var rep: String?
                switch ent {
                case "amp": rep = "&"
                case "lt": rep = "<"
                case "gt": rep = ">"
                case "quot": rep = "\""
                case "apos": rep = "'"
                case "nbsp": rep = "\u{00A0}"
                default:
                    if ent.hasPrefix("#x") || ent.hasPrefix("#X"), let n = UInt32(ent.dropFirst(2), radix: 16) {
                        rep = Unicode.Scalar(n).map { String(Character($0)) }
                    } else if ent.hasPrefix("#"), let n = UInt32(ent.dropFirst()) {
                        rep = Unicode.Scalar(n).map { String(Character($0)) }
                    }
                }
                if let rep { out += rep; i = s.index(after: semi); continue }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    var root: XElement?
    private var stack: [XElement] = []

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        let e = XElement(name: name, attributes: attributes)
        if let top = stack.last { e.parent = top; top.children.append(e) } else { root = e }
        stack.append(e)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        stack.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        stack.last?.text += String(decoding: block, as: UTF8.self)
    }
}
