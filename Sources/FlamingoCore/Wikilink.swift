import Foundation

/// `[[target]]` and `[[target|alias]]` and `[[target#anchor]]`.
public enum Wikilink {
    /// Returns the bare targets (without alias or anchor), in order, de-duplicated.
    public static func parse(_ text: String) -> [String] {
        // TODO(plan 02): real parser with alias and anchor handling. Minimal version:
        var out: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "[["), let close = rest[open.upperBound...].range(of: "]]") {
            var inner = String(rest[open.upperBound..<close.lowerBound])
            if let p = inner.firstIndex(of: "|") { inner = String(inner[..<p]) }
            if let h = inner.firstIndex(of: "#") { inner = String(inner[..<h]) }
            let t = inner.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !out.contains(t) { out.append(t) }
            rest = rest[close.upperBound...]
        }
        return out
    }

    /// Resolves a link target to a file in the vault. Matches by relative path,
    /// then by basename with or without extension. Plan 02 implements.
    public static func resolve(_ target: String, in vault: Vault, candidates: [FileRef]) -> FileRef? {
        if let exact = candidates.first(where: { $0.relativePath == target }) { return exact }
        let lower = target.lowercased()
        return candidates.first { $0.name.lowercased() == lower }
            ?? candidates.first { ($0.name as NSString).deletingPathExtension.lowercased() == lower }
    }
}
