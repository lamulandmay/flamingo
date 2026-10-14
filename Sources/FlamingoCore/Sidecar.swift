import Foundation

/// The on-disk format. See CONTRACT.md "Sidecar notes".
///
/// ```
/// ---
/// target: decks/q3.pptx
/// id: 6F9619FF-8B86-D011-B42D-00C04FC964FF
/// ---
/// - [2026-10-14 22:05] (slide 7) Pricing contradicts [[q3-model.xlsx]]
/// - [2026-10-14 22:09] Needs a better title
/// ```
public enum SidecarFormat {
    public static let timestampFormat = "yyyy-MM-dd HH:mm"

    public static func render(target: FileRef, id: UUID?, comments: [Comment]) -> String {
        // TODO(plan 02): full implementation. Minimal version below.
        var s = "---\ntarget: \(target.relativePath)\n"
        if let id { s += "id: \(id.uuidString)\n" }
        s += "---\n"
        let f = DateFormatter(); f.dateFormat = timestampFormat
        for c in comments {
            s += "- [\(f.string(from: c.timestamp))]"
            if let a = c.anchor { s += " \(a.rendered)" }
            s += " \(c.text.replacingOccurrences(of: "\n", with: "\n  "))\n"
        }
        return s
    }

    public static func parse(_ text: String) -> (target: FileRef?, id: UUID?, comments: [Comment]) {
        // TODO(plan 02): robust parser incl. multi-line comments. Returns empty for now.
        return (nil, nil, [])
    }
}

/// Reads and writes sidecar notes under `<vault>/.flamingo/notes/<relativePath>.md`.
public final class SidecarStore: @unchecked Sendable {
    public let vault: Vault
    public init(vault: Vault) { self.vault = vault }

    public func sidecarURL(for ref: FileRef) -> URL {
        vault.notesDir.appendingPathComponent(ref.relativePath + ".md")
    }

    public func comments(for ref: FileRef) throws -> [Comment] {
        // TODO(plan 02)
        return []
    }

    public func append(_ comment: Comment, to ref: FileRef) throws {
        // TODO(plan 02): read, append, atomically write.
    }

    public func update(_ comment: Comment, in ref: FileRef) throws { /* TODO(plan 02) */ }
    public func delete(_ id: UUID, from ref: FileRef) throws { /* TODO(plan 02) */ }

    /// Every sidecar in the vault.
    public func all() throws -> [FileRef: [Comment]] {
        // TODO(plan 02)
        return [:]
    }
}
