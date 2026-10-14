import Foundation

/// Stable identity that survives rename and move, stored as an extended attribute on
/// the file (`com.flamingo.id`). Packages get the attribute on the package folder.
/// Extended attributes are metadata: Flamingo never changes a file's bytes.
public enum FileIdentity {
    public static let xattrName = "com.flamingo.id"

    private static let lock = NSLock()
    private static var cache: [Vault: [UUID: FileRef]] = [:]

    /// Returns the existing id or assigns a new one.
    public static func id(for url: URL) throws -> UUID {
        if let existing = try existingID(for: url) { return existing }
        let fresh = UUID()
        try assign(fresh, to: url)
        return fresh
    }

    /// Reads the id without assigning one. Nil when the file has none (or carries
    /// something that is not a UUID). Throws if the file cannot be read at all.
    public static func existingID(for url: URL) throws -> UUID? {
        let path = url.path
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
    /// same id (a copy), the one with the shortest path, then the first in Finder order, wins.
    public static func ids(in vault: Vault) -> [UUID: FileRef] {
        var map: [UUID: FileRef] = [:]
        for ref in VaultScanner.files(in: vault) {
            guard let id = try? existingID(for: vault.url(for: ref)) else { continue }
            if let existing = map[id] {
                if ref.components.count < existing.components.count { map[id] = ref }
            } else {
                map[id] = ref
            }
        }
        lock.lock(); cache[vault] = map; lock.unlock()
        return map
    }

    /// Drops the cached id map for a vault (e.g. when the vault is closed).
    public static func invalidateCache(for vault: Vault) {
        lock.lock(); cache[vault] = nil; lock.unlock()
    }
}
