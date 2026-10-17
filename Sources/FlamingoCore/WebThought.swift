import Foundation

/// Thoughts about a web page that no vault file stands behind live in a note of their own:
/// `.flamingo/notes/_web/<host>/<slug>-<hash6>.md`, whose front matter holds `url:` and `title:`.
/// The same URL always maps to the same note.
public enum WebThought {
    /// The note's ref for `url`, nil unless it is an http(s) URL with a host.
    public static func ref(for url: String, title: String? = nil) -> FileRef? {
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = parsed.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        let safeHost = String(host.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "-" })
        var slugSource = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if slugSource.isEmpty { slugSource = parsed.path.split(separator: "/").last.map(String.init) ?? host }
        var name = slug(slugSource)
        if name.isEmpty { name = "page" }
        return FileRef(relativePath: "\(FileRef.webDirectory)/\(safeHost)/\(name)-\(hash6(of: normalized(parsed)))")
    }

    /// Front matter for a new web note, in order.
    public static func frontmatter(url: String, title: String?) -> [String: String] {
        var out = ["url": url]
        if let title, !title.isEmpty { out["title"] = title }
        return out
    }

    static func normalized(_ url: URL) -> String {
        var s = url.absoluteString
        if var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.fragment = nil
            let scheme = c.scheme?.lowercased()
            var host = c.host?.lowercased()
            if host?.hasPrefix("www.") == true { host = String(host!.dropFirst(4)) }
            c.scheme = scheme
            c.host = host
            s = c.string ?? s
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Six lowercase hex digits of a stable hash of the URL.
    static func hash6(of text: String) -> String {
        let id = StableID.uuid(from: "flamingo.web\n" + text).uuid
        return String(format: "%02x%02x%02x", id.0, id.1, id.2)
    }

    static func slug(_ text: String) -> String {
        var out = ""
        var pendingDash = false
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(ch)
            } else { pendingDash = true }
            if out.count >= 48 { break }
        }
        return out
    }
}
