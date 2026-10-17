import Foundation
import CryptoKit
import FlamingoCore

/// What a piece of work read, as the files stood: path, modification time and size. A job's
/// id ends in a hash of these, so the same work on unchanged files is never done twice, and a
/// memo is thrown away if a file changed while it was being written.
public enum WorkFingerprint {
    public struct Source: Hashable, Sendable {
        public var path: String
        public var modified: Date
        public var size: Int
        public init(path: String, modified: Date, size: Int) { self.path = path; self.modified = modified; self.size = size }
    }

    /// The paths a request reads: the files its objects name (anchors dropped), then the file
    /// the thought is on (unless it has none). Order kept, duplicates removed.
    public static func paths(objects: [String], target: FileRef?) -> [String] {
        var out: [String] = []
        for object in objects {
            let path = object.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? object
            if !path.isEmpty, !out.contains(path) { out.append(path) }
        }
        if let target, !target.isVirtual, !out.contains(target.relativePath) { out.append(target.relativePath) }
        return out
    }

    /// The state of each path that exists as a file in the vault; missing ones are left out.
    public static func sources(of paths: [String], in vault: Vault) -> [Source] {
        paths.compactMap { path in
            let parts = path.split(separator: "/")
            guard !path.hasPrefix("/"), !parts.contains(".."), !parts.isEmpty,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: vault.url(for: FileRef(relativePath: path)).path),
                  attrs[.size] != nil else { return nil }
            let modified = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            return Source(path: path, modified: modified, size: (attrs[.size] as? NSNumber)?.intValue ?? 0)
        }
    }

    /// Eight hex characters over the sorted `path|mtime|size` lines.
    public static func hash(_ sources: [Source]) -> String {
        let text = sources.sorted { $0.path < $1.path }
            .map { "\($0.path)|\(Int($0.modified.timeIntervalSince1970 * 1000))|\($0.size)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// `<uid>:<recipe>:<8 hex>`.
    public static func jobID(uid: String, recipe: String, hash: String) -> String { "\(uid):\(recipe):\(hash)" }
}
