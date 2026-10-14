import Foundation

/// Stable identity that survives rename and move, stored as an extended
/// attribute on the file (`com.flamingo.id`). Plan 02 implements.
public enum FileIdentity {
    public static let xattrName = "com.flamingo.id"

    /// Returns the existing id or assigns a new one.
    public static func id(for url: URL) throws -> UUID {
        // TODO(plan 02): read xattr; if absent, generate, write, return.
        return UUID()
    }

    /// Finds the file in `vault` currently carrying `id`, if any.
    public static func locate(id: UUID, in vault: Vault) -> FileRef? {
        // TODO(plan 02)
        return nil
    }
}
