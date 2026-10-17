import Foundation
import FlamingoCore

struct CommentEditDraft: Codable, Sendable {
    var file: FileRef
    var comment: Comment
}

/// Separate from new capture drafts: recovering an edit must not append a duplicate thought.
enum CommentEditDraftStore {
    private static let lock = NSLock()
    static func url(in vault: Vault) -> URL { vault.stateDir.appendingPathComponent("comment-edit-drafts.json") }
    static func recoveryKey(for comment: Comment, file: FileRef, in vault: Vault) -> String {
        url(in: vault).path + "|" + file.relativePath + "|" + comment.id.uuidString
    }
    @discardableResult
    static func checkpoint(_ comment: Comment, for file: FileRef, in vault: Vault,
                           completion: @escaping @Sendable (String?) -> Void = { _ in }) -> UInt64 {
        ThoughtDraftCheckpoint.enqueue(key: recoveryKey(for: comment, file: file, in: vault), operation: {
            try save(comment, for: file, in: vault)
        }, completion: completion)!
    }
    private static func read(in vault: Vault) throws -> [CommentEditDraft] {
        let url = url(in: vault)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([CommentEditDraft].self, from: Data(contentsOf: url))
    }
    static func draft(for file: FileRef, in vault: Vault) throws -> Comment? {
        lock.lock(); defer { lock.unlock() }
        return try read(in: vault).last { $0.file == file }?.comment
    }
    static func save(_ comment: Comment?, for file: FileRef, in vault: Vault) throws {
        lock.lock(); defer { lock.unlock() }
        var all = try read(in: vault).filter { $0.file != file || (comment != nil && $0.comment.id != comment?.id) }
        if let comment { all.append(CommentEditDraft(file: file, comment: comment)) }
        try FileManager.default.createDirectory(at: vault.stateDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(all).write(to: url(in: vault), options: .atomic)
    }
    static func removeIfMatching(_ comment: Comment, for file: FileRef, in vault: Vault) throws {
        lock.lock(); defer { lock.unlock() }
        let all = try read(in: vault)
        guard all.contains(where: { $0.file == file && $0.comment == comment }) else { return }
        let remaining = all.filter { !($0.file == file && $0.comment == comment) }
        try JSONEncoder().encode(remaining).write(to: url(in: vault), options: .atomic)
    }
    static func remove(commentID: UUID, for file: FileRef, in vault: Vault) throws {
        lock.lock(); defer { lock.unlock() }
        let all = try read(in: vault)
        let remaining = all.filter { !($0.file == file && $0.comment.id == commentID) }
        guard remaining.count != all.count else { return }
        try JSONEncoder().encode(remaining).write(to: url(in: vault), options: .atomic)
    }
}
