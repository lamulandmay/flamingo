import Foundation

/// Errors raised by `SidecarStore`.
public enum SidecarError: Error, Equatable, Sendable, LocalizedError {
    /// `update` or `delete` named a comment id that is not in the sidecar.
    case commentNotFound(UUID)
    /// `insert` was given an index outside `0...comments.count`.
    case indexOutOfRange(Int)
    /// A POSIX call failed while writing a sidecar. `errno` is the raw code.
    case writeFailed(path: String, errno: Int32)
    /// A URL that was expected to be a sidecar is not under `notesDir` or is not a `.md` file.
    case notASidecar(String)
    /// The sidecar exists but is not valid UTF-8, so it cannot be edited without corrupting it.
    case notUTF8(path: String)
    /// A rename could not prove that the source note and destination still share identity.
    case identityMismatch(path: String)
    /// A uid-addressed call named a thought that is not in the sidecar.
    case thoughtNotFound(uid: String)

    public var errorDescription: String? {
        switch self {
        case .commentNotFound(let id): return "Comment \(id.uuidString) is not in this sidecar."
        case .indexOutOfRange(let i): return "Comment index \(i) is out of range."
        case .writeFailed(let path, let code): return "Could not write \(path): \(String(cString: strerror(code)))."
        case .notASidecar(let path): return "\(path) is not a sidecar note."
        case .notUTF8(let path): return "\(path) is not UTF-8 text."
        case .identityMismatch(let path): return "The identity of \(path) changed or is unknown. Its thoughts were preserved."
        case .thoughtNotFound(let uid): return "Thought \(uid) is not in this sidecar."
        }
    }
}

/// Errors raised by `FileIdentity`.
public enum FileIdentityError: Error, Equatable, Sendable, LocalizedError {
    /// `getxattr` failed for a reason other than "no such attribute".
    case readFailed(path: String, errno: Int32)
    /// `setxattr` failed.
    case writeFailed(path: String, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .readFailed(let path, let code): return "Could not read identity of \(path): \(String(cString: strerror(code)))."
        case .writeFailed(let path, let code): return "Could not assign identity to \(path): \(String(cString: strerror(code)))."
        }
    }
}
