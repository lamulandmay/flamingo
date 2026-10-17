import Foundation

/// Historical vault-relative paths. Renames preserve links without rewriting source files.
public final class PathAliases: @unchecked Sendable {
    public let vault: Vault
    public var fileURL: URL { vault.stateDir.appendingPathComponent("path-aliases.json") }
    private static let lock = NSRecursiveLock()

    public init(vault: Vault) { self.vault = vault }

    /// Missing metadata is empty. Unreadable, malformed, unsafe or cyclic metadata throws;
    /// a later rename must never silently replace recoverable user data.
    public func all() throws -> [String: String] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        return try Self.validated(JSONDecoder().decode([String: String].self, from: Data(contentsOf: fileURL)))
    }

    /// Call only after confirming that this file or folder moved. Longest matching folder
    /// prefixes apply to descendants, so nested and repeated renames remain addressable.
    public func reconcile(oldPath: String, newPath: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let old = try Self.path(oldPath), new = try Self.path(newPath)
        var aliases = try all()
        guard old != new else { return }
        // Moving back to an earlier name makes that destination current again. Retire
        // redirects from it into the moved subtree, while retaining unrelated children
        // that were moved elsewhere and historical paths pointing into this destination.
        let retired = aliases.keys.filter { key in
            if key == new { return true }
            guard key.hasPrefix(new + "/"), let destination = Self.resolvedPath(key, aliases: aliases) else { return false }
            return destination == old || destination.hasPrefix(old + "/")
        }
        if !retired.isEmpty {
            // Preserve older incoming links before reusing a historical destination name.
            // For Z → A → B followed by X → A, Z must still mean B, while X now means A.
            let prior = aliases
            for key in aliases.keys where key != old && !retired.contains(key) {
                guard let destination = Self.resolvedPath(key, aliases: prior) else { throw Failure.cycle }
                aliases[key] = destination == old || destination.hasPrefix(old + "/")
                    ? new + destination.dropFirst(old.count) : destination
            }
        }
        for key in retired { aliases.removeValue(forKey: key) }
        aliases[old] = new
        aliases = try Self.validated(aliases)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: vault.stateDir, withIntermediateDirectories: true)
        try AtomicFile.write(encoder.encode(aliases), to: fileURL)
    }

    enum Failure: LocalizedError {
        case unsafePath(String), cycle
        var errorDescription: String? {
            switch self {
            case .unsafePath(let path): return "Cannot preserve a link for the unsafe vault path ‘\(path)’."
            case .cycle: return "Path aliases contain a rename cycle. Existing aliases were preserved."
            }
        }
    }

    private static func path(_ value: String) throws -> String {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty, !value.contains("\\"), !value.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".flamingo" }) else {
            throw Failure.unsafePath(value)
        }
        return value.precomposedStringWithCanonicalMapping
    }

    static func validated(_ input: [String: String]) throws -> [String: String] {
        var aliases: [String: String] = [:]
        for (old, new) in input { aliases[try path(old)] = try path(new) }
        for old in aliases.keys where resolvedPath(old, aliases: aliases) == nil { throw Failure.cycle }
        return aliases
    }

    /// Resolves exact aliases and ancestor aliases, preferring the longest prefix at each
    /// step. Bounded even for malformed input with an expanding cycle (a → a/child).
    static func resolvedPath(_ original: String, aliases: [String: String]) -> String? {
        var current = original
        var visited = Set<String>()
        for _ in 0...max(32, aliases.count * 2) {
            guard visited.insert(current).inserted else { return nil }
            var prefix = current
            var next: String?
            while !prefix.isEmpty {
                if let replacement = aliases[prefix] {
                    next = replacement + current.dropFirst(prefix.count)
                    break
                }
                guard let slash = prefix.lastIndex(of: "/") else { break }
                prefix = String(prefix[..<slash])
            }
            guard let next else { return current }
            current = next
        }
        return nil
    }
}
