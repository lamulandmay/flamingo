import Foundation

/// A folder the user has opened. Everything is addressed relative to `root`.
public struct Vault: Hashable, Sendable {
    public let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL }

    /// `<root>/.flamingo` — all Flamingo state lives here, never inside user files.
    public var stateDir: URL { root.appendingPathComponent(".flamingo", isDirectory: true) }
    public var notesDir: URL { stateDir.appendingPathComponent("notes", isDirectory: true) }
    /// `<root>/.flamingo/index.sqlite` (plan 05).
    public var indexURL: URL { stateDir.appendingPathComponent("index.sqlite") }
    /// `<root>/.flamingo/graph.json` (plan 05 writes, plan 06 reads).
    public var graphURL: URL { stateDir.appendingPathComponent("graph.json") }
    /// `<root>/.flamingo/trail.jsonl` (plan 07).
    public var trailURL: URL { stateDir.appendingPathComponent("trail.jsonl") }

    /// The folder's display name.
    public var name: String { root.lastPathComponent }

    public func relativePath(of url: URL) -> String? {
        let r = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(r) else { return nil }
        return String(url.standardizedFileURL.path.dropFirst(r.count))
    }

    /// The `FileRef` for a URL inside the vault, or nil if the URL is outside it.
    public func ref(for url: URL) -> FileRef? {
        guard let rel = relativePath(of: url), !rel.isEmpty else { return nil }
        return FileRef(relativePath: rel)
    }

    /// True if `url` is inside the vault's root (including inside `.flamingo`).
    public func contains(_ url: URL) -> Bool { relativePath(of: url) != nil }

    /// True if `url` is inside `.flamingo`, i.e. Flamingo's own state rather than a user file.
    public func isState(_ url: URL) -> Bool {
        guard let rel = relativePath(of: url) else { return false }
        return rel == ".flamingo" || rel.hasPrefix(".flamingo/")
    }

    public func url(for ref: FileRef) -> URL { root.appendingPathComponent(ref.relativePath) }

    /// Whether the user file `ref` points at currently exists on disk.
    public func exists(_ ref: FileRef) -> Bool { FileManager.default.fileExists(atPath: url(for: ref).path) }
}

/// Identity of a file inside a vault. Tonight identity is the relative path;
/// `FileIdentity` adds a stable id that survives renames.
public struct FileRef: Hashable, Codable, Sendable {
    public let relativePath: String
    public init(relativePath: String) { self.relativePath = relativePath }
    public var name: String { (relativePath as NSString).lastPathComponent }
    public var ext: String { (relativePath as NSString).pathExtension.lowercased() }

    /// `name` without its extension: `q3` for `decks/q3.pptx`.
    public var stem: String { (name as NSString).deletingPathExtension }
    /// The containing folder, relative to the vault root. `""` for files at the root.
    public var directory: String {
        let d = (relativePath as NSString).deletingLastPathComponent
        return d == "." ? "" : d
    }
    /// Path components, `["decks", "q3.pptx"]`.
    public var components: [String] { relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init) }
}

extension FileRef: Comparable {
    /// Finder order (`file2` before `file10`).
    public static func < (lhs: FileRef, rhs: FileRef) -> Bool {
        lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
    }
}

extension FileRef: CustomStringConvertible {
    public var description: String { relativePath }
}
