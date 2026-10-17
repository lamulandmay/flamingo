import Foundation

/// The filter field's query. Space-separated terms; a node must match all of them.
///
/// - `ext:pptx` matches by extension. `ext:pptx,key` matches either.
/// - `orphans` matches files with no relationships beyond folder containment.
/// - Anything else matches a substring of the relative path, ignoring case and diacritics.
struct GraphFilter: Equatable {
    enum Term: Equatable {
        case text(String)
        case ext(Set<String>)
        case orphans
    }

    let terms: [Term]

    init(_ query: String) {
        var terms: [Term] = []
        for raw in query.split(whereSeparator: { $0.isWhitespace }) {
            let word = String(raw)
            let lower = word.lowercased()
            if lower.hasPrefix("ext:") {
                let exts = lower.dropFirst(4)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
                    .filter { !$0.isEmpty }
                // A bare `ext:` while typing filters nothing yet.
                if !exts.isEmpty { terms.append(.ext(Set(exts))) }
            } else if lower == "orphans" {
                terms.append(.orphans)
            } else {
                terms.append(.text(Self.fold(word)))
            }
        }
        self.terms = terms
    }

    var isEmpty: Bool { terms.isEmpty }

    /// nil when the filter is empty; otherwise one entry per node, `true` where it matches.
    func mask(for topology: GraphTopology) -> [Bool]? {
        guard !isEmpty else { return nil }
        let folded = terms.contains { if case .text = $0 { return true } else { return false } }
            ? topology.ids.map(Self.fold) : []
        // Containment makes the folder map navigable, but does not turn an otherwise
        // unrelated file into a connected document. Only compute this for orphan queries.
        var related = [Bool]()
        if terms.contains(.orphans) {
            related = Array(repeating: false, count: topology.count)
            for edge in topology.edges where edge.kind != .folder {
                related[edge.a] = true
                related[edge.b] = true
            }
        }
        return (0..<topology.count).map { i in
            terms.allSatisfy { term in
                switch term {
                case .text(let needle): return folded[i].contains(needle)
                case .ext(let exts): return exts.contains(topology.exts[i])
                case .orphans: return !topology.isFolder[i] && !related[i]
                }
            }
        }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
