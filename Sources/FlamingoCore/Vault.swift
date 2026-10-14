import Foundation

/// A folder the user has opened. Everything is addressed relative to `root`.
public struct Vault: Hashable, Sendable {
    public let root: URL
    public init(root: URL) { self.root = root.standardizedFileURL }

    /// `<root>/.flamingo` — all Flamingo state lives here, never inside user files.
    public var stateDir: URL { root.appendingPathComponent(".flamingo", isDirectory: true) }
    public var notesDir: URL { stateDir.appendingPathComponent("notes", isDirectory: true) }

    public func relativePath(of url: URL) -> String? {
        let r = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(r) else { return nil }
        return String(url.standardizedFileURL.path.dropFirst(r.count))
    }

    public func url(for ref: FileRef) -> URL { root.appendingPathComponent(ref.relativePath) }
}

/// Identity of a file inside a vault. Tonight identity is the relative path;
/// `FileIdentity` adds a stable id that survives renames.
public struct FileRef: Hashable, Codable, Sendable {
    public let relativePath: String
    public init(relativePath: String) { self.relativePath = relativePath }
    public var name: String { (relativePath as NSString).lastPathComponent }
    public var ext: String { (relativePath as NSString).pathExtension.lowercased() }
}
