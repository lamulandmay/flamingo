import Foundation

/// The folders the sidebar shows as its roots, in order: `<vault>/.flamingo/pins.json`, a JSON
/// array of vault-relative folder paths. `""` is the vault root itself. Everything not under
/// a pin is still indexed and reachable through search and the palette.
public struct Pins: Equatable, Sendable {
    public static let fileName = "pins.json"

    /// What a vault with no `pins.json` starts with, in this order, when they exist.
    public static let defaultFolders = ["Desktop", "Documents", "Downloads"]

    /// Normalized (no leading or trailing `/`), unique, in sidebar order.
    public private(set) var paths: [String]

    public init(_ paths: [String] = []) {
        self.paths = []
        for p in paths { pin(p) }
    }

    /// The vault's pins, or `nil` when `pins.json` doesn't exist or isn't a JSON array of strings.
    public static func load(in vault: Vault) -> Pins? {
        guard let data = try? Data(contentsOf: vault.pinsURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return Pins(list)
    }

    /// First-run pins: `defaultFolders` that exist as folders in the vault. When none does (a
    /// project folder rather than a home), the vault root itself.
    public static func defaults(in vault: Vault) -> Pins {
        let found = defaultFolders.filter { name in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: vault.root.appendingPathComponent(name).path, isDirectory: &isDir)
                && isDir.boolValue
        }
        return Pins(found.isEmpty ? [""] : found)
    }

    /// `load(in:)`, or on first run `defaults(in:)`, saved so the choice sticks. An existing
    /// empty list stays empty: the user unpinned everything.
    public static func loadOrCreate(in vault: Vault) -> Pins {
        if let pins = load(in: vault) { return pins }
        let pins = defaults(in: vault)
        try? pins.save(in: vault)
        return pins
    }

    /// Writes `pins.json` atomically, pretty-printed so `cat` reads it.
    public func save(in vault: Vault) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try AtomicFile.write(try encoder.encode(paths) + Data("\n".utf8), to: vault.pinsURL)
    }

    public func contains(_ path: String) -> Bool { paths.contains(Pins.normalize(path)) }

    /// Adds `path` at `index` (clamped; the end when `nil`). Returns `false` if it was already
    /// pinned, in which case nothing moves.
    @discardableResult
    public mutating func pin(_ path: String, at index: Int? = nil) -> Bool {
        let p = Pins.normalize(path)
        guard !paths.contains(p) else { return false }
        let i = min(max(index ?? paths.count, 0), paths.count)
        paths.insert(p, at: i)
        return true
    }

    /// Removes `path`. Returns the index it had, for undo (`pin(path, at: index)`).
    @discardableResult
    public mutating func unpin(_ path: String) -> Int? {
        guard let i = paths.firstIndex(of: Pins.normalize(path)) else { return nil }
        paths.remove(at: i)
        return i
    }

    /// Moves the pin at `from` so it ends up at index `to` in the result (both clamped).
    public mutating func move(from: Int, to: Int) {
        guard paths.indices.contains(from) else { return }
        let p = paths.remove(at: from)
        paths.insert(p, at: min(max(to, 0), paths.count))
    }

    /// Re-targets pins after a folder rename: `old` and anything under it now live under `new`.
    public mutating func rename(_ old: String, to new: String) {
        let o = Pins.normalize(old), n = Pins.normalize(new)
        guard !o.isEmpty else { return }
        var out: [String] = []
        for p in paths {
            let moved = p == o ? n : p.hasPrefix(o + "/") ? n + p.dropFirst(o.count) : p
            if !out.contains(moved) { out.append(moved) }
        }
        paths = out
    }

    static func normalize(_ path: String) -> String { IgnoreRules.normalize(path) }
}
