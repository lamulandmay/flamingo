import Foundation

/// Stable identity that survives rename and move, stored as an extended attribute on
/// the file (`com.flamingo.id`). Packages get the attribute on the package folder.
/// Extended attributes are metadata: Flamingo never changes a file's bytes.
public enum FileIdentity {
    public static let xattrName = "com.flamingo.id"

    private static let lock = NSLock()
    private static var cache: [Vault: [UUID: FileRef]] = [:]

    /// Returns the existing id or assigns a new one. Two processes racing to stamp the
    /// same file agree: the first `setxattr` wins (`XATTR_CREATE`) and the loser reads it back.
    public static func id(for url: URL) throws -> UUID {
        if let existing = try existingID(for: url) { return existing }
        let fresh = UUID()
        let value = Array(fresh.uuidString.utf8)
        if setxattr(url.path, xattrName, value, value.count, 0, XATTR_CREATE) == 0 { return fresh }
        let code = errno
        if code == EEXIST, let winner = try existingID(for: url) { return winner }
        if code == EEXIST { try assign(fresh, to: url); return fresh }   // junk value: replace it
        throw FileIdentityError.writeFailed(path: url.path, errno: code)
    }

    /// Reads the id without assigning one. Nil when the file has none (or carries
    /// something that is not a UUID). Throws if the file cannot be read at all.
    public static func existingID(for url: URL) throws -> UUID? {
        try existingID(atPath: url.path)
    }

    /// `existingID(for:)` for a file-system path, for loops over many files that would
    /// otherwise build a URL per file.
    public static func existingID(atPath path: String) throws -> UUID? {
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = getxattr(path, xattrName, &buffer, buffer.count, 0, 0)
        if n < 0 {
            let code = errno
            if code == ENOATTR || code == ERANGE { return nil }
            throw FileIdentityError.readFailed(path: path, errno: code)
        }
        guard let s = String(bytes: buffer[0..<n], encoding: .utf8) else { return nil }
        return UUID(uuidString: s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Stamps `url` with `id`, replacing any existing id.
    public static func assign(_ id: UUID, to url: URL) throws {
        let value = Array(id.uuidString.utf8)
        if setxattr(url.path, xattrName, value, value.count, 0, 0) != 0 {
            throw FileIdentityError.writeFailed(path: url.path, errno: errno)
        }
    }

    /// Finds the file in `vault` currently carrying `id`, if any. Uses an in-memory map
    /// per vault; a cached answer is verified against the file before it is returned, and
    /// a miss or a stale entry triggers one rescan of the vault.
    public static func locate(id: UUID, in vault: Vault) -> FileRef? {
        lock.lock()
        let cached = cache[vault]?[id]
        lock.unlock()
        if let cached, (try? existingID(for: vault.url(for: cached))) == id { return cached }
        return ids(in: vault)[id]
    }

    /// Every identified file in the vault, by id. Walks the vault (honouring the same
    /// rules as `VaultScanner.files`) and refreshes the cache. When two files carry the
    /// same id (a copy), the one with the shortest path, then the first in Finder order, wins;
    /// use `carriers(in:)` to see all of them.
    public static func ids(in vault: Vault) -> [UUID: FileRef] {
        carriers(in: vault).compactMapValues { refs in
            refs.min { a, b in a.components.count != b.components.count ? a.components.count < b.components.count : a < b }
        }
    }

    /// Every file carrying each id, in Finder order. Duplicated files (Finder's Duplicate,
    /// `cp -p`) keep their xattrs, so an id can have several carriers. Refreshes the cache.
    public static func carriers(in vault: Vault) -> [UUID: [FileRef]] {
        var map: [UUID: [FileRef]] = [:]
        // Unsorted walk; only the (short) per-id lists need Finder order.
        VaultScanner.scan(in: vault, ignore: VaultScanner.ignoreRules(in: vault)) { ref in
            if let id = try? existingID(for: vault.url(for: ref)) { map[id, default: []].append(ref) }
            return true
        }
        for (id, refs) in map where refs.count > 1 { map[id] = FinderOrder.sorted(refs, by: \.relativePath) }
        let best = map.compactMapValues { refs in
            refs.min { a, b in a.components.count != b.components.count ? a.components.count < b.components.count : a < b }
        }
        lock.lock(); cache[vault] = best; lock.unlock()
        return map
    }

    /// Drops the cached id map for a vault (e.g. when the vault is closed).
    public static func invalidateCache(for vault: Vault) {
        lock.lock(); cache[vault] = nil; lock.unlock()
    }
}
