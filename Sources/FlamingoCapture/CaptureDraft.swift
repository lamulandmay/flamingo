import Foundation
import FlamingoCore

/// A recoverable draft is independent of the editor and survives process termination.
struct CaptureDraft: Codable, Equatable, Sendable {
    var file: FileRef
    var anchor: FileAnchor?
    var text: String
    var provenance: CommentProvenance?
    /// The uid of the thought the draft answers.
    var replyParent: String?
    /// Front matter and kind of a note with no file behind it (folder, web page), so a recovered draft lands the same way.
    var frontmatter: [String: String]?
    var isFolder: Bool?
    var updatedAt = Date()
}

public enum CaptureDraftStore {
    private static let lock = NSLock()
    static func url(in vault: Vault) -> URL { vault.stateDir.appendingPathComponent("capture-drafts.json") }
    static func recoveryKey(for file: FileRef, in vault: Vault) -> String {
        url(in: vault).path + "|" + file.relativePath
    }
    static func checkpoint(_ draft: CaptureDraft, in vault: Vault,
                           completion: @escaping @Sendable (String?) -> Void = { _ in }) {
        ThoughtDraftCheckpoint.enqueue(key: recoveryKey(for: draft.file, in: vault), operation: {
            try save(draft, in: vault)
        }, completion: completion)
    }
    /// The first lines of the unsaved thoughts left behind, newest first (the briefing lists them).
    public static func pending(in vault: Vault) -> [String] {
        drafts(in: vault).sorted { $0.updatedAt > $1.updatedAt }
            .map { $0.text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? $0.text }
    }
    static func drafts(in vault: Vault) -> [CaptureDraft] {
        lock.lock(); defer { lock.unlock() }
        return (try? read(in: vault)) ?? []
    }
    private static func read(in vault: Vault) throws -> [CaptureDraft] {
        let file = url(in: vault)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([CaptureDraft].self, from: Data(contentsOf: file))
    }
    static func save(_ draft: CaptureDraft, in vault: Vault) throws {
        lock.lock(); defer { lock.unlock() }
        var drafts = try read(in: vault).filter { $0.file != draft.file }
        if !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { drafts.append(draft) }
        try FileManager.default.createDirectory(at: vault.stateDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(drafts).write(to: url(in: vault), options: .atomic)
    }
    static func remove(_ file: FileRef, in vault: Vault) throws {
        try save(CaptureDraft(file: file, text: ""), in: vault)
    }
}
