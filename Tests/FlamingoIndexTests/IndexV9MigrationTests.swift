import XCTest
import SQLite3
import FlamingoCore
@testable import FlamingoIndex

/// Schema v9 (thought columns) and the in-place metadata updates that keep vectors from churning.
final class IndexV9MigrationTests: XCTestCase {
    var root: URL!
    var vault: Vault!
    let calls = Counter()

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump(_ by: Int) { lock.lock(); n += by; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        func reset() { lock.lock(); n = 0; lock.unlock() }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("v9-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "The supplier agreement binds the manufacturer.".write(to: root.appendingPathComponent("terms.md"), atomically: true, encoding: .utf8)
        try "Price is final.".write(to: root.appendingPathComponent("money.md"), atomically: true, encoding: .utf8)
        vault = Vault(root: root)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func open(readOnly: Bool = false) throws -> IndexStore {
        let store = try IndexStore(vault: vault, readOnly: readOnly)
        if !readOnly {
            let counter = calls
            store.embedding.embedder.fake = { inputs in counter.bump(inputs.count); return inputs.map(SemanticIndexTests.vector) }
        }
        return store
    }

    func embedAll(_ store: IndexStore) { while store.embedPending() > 0 {} }

    /// A v8-shaped database: what `Schema` made before this step.
    func downgradeToV8(_ store: IndexStore) throws {
        try store.writer.exec("""
            DROP INDEX comments_uid; DROP INDEX comments_parent; DROP INDEX comments_triage;
            ALTER TABLE comments DROP COLUMN uid; ALTER TABLE comments DROP COLUMN parent; ALTER TABLE comments DROP COLUMN kind;
            ALTER TABLE comments DROP COLUMN kind_by; ALTER TABLE comments DROP COLUMN state; ALTER TABLE comments DROP COLUMN due;
            ALTER TABLE comments DROP COLUMN snooze_until; ALTER TABLE comments DROP COLUMN modified; ALTER TABLE comments DROP COLUMN origin;
            ALTER TABLE comments DROP COLUMN action; ALTER TABLE comments DROP COLUMN meta;
            DELETE FROM meta WHERE key IN ('comments_reload', 'thought_rules');
            PRAGMA user_version = 8;
            """)
    }

    func thoughtRows(_ store: IndexStore) throws -> [(rowid: Int, id: String, text: String)] {
        try store.read { db in try db.query("SELECT rowid, id, text FROM comments ORDER BY rowid") { ($0.int(0), $0.string(1), $0.string(2)) } }
    }

    func vectorOwners(_ store: IndexStore) throws -> [Int] {
        try store.read { db in try db.query("SELECT comment FROM comment_vectors ORDER BY comment") { $0.int(0) } }
    }

    func testV8DatabaseWithThoughtsAndVectorsMigratesWithoutReEmbedding() throws {
        let notes = SidecarStore(vault: vault)
        let terms = FileRef(relativePath: "terms.md")
        try notes.append(Comment(timestamp: Date(timeIntervalSince1970: 1_800_000_000), text: "The supplier contract needs a signature"), to: terms)
        try notes.append(Comment(timestamp: Date(timeIntervalSince1970: 1_800_000_600), text: "Is the price final?").stamped(), to: terms)
        try notes.append(Comment(timestamp: Date(timeIntervalSince1970: 1_800_001_200), text: "Remember to call the vendor by friday"), to: FileRef(relativePath: "_inbox/2026-10-16"))
        var store: IndexStore? = try open()
        try store!.reindex()
        embedAll(store!)
        let rows = try thoughtRows(store!)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(try vectorOwners(store!), rows.map(\.rowid))
        try downgradeToV8(store!)
        XCTAssertEqual(try store!.writer.userVersion(), 8)
        store = nil

        // A read-only store opened before the migration fails cleanly, and changes nothing.
        XCTAssertThrowsError(try IndexStore(vault: vault, readOnly: true)) { XCTAssertTrue("\($0)".contains("schema 8")) }

        calls.reset()
        let migrated = try open()
        XCTAssertEqual(try migrated.writer.userVersion(), 9)
        XCTAssertEqual(try migrated.metaValue("comments_reload"), "0", "the one-time reload ran at open")
        let after = try thoughtRows(migrated)
        XCTAssertEqual(after.map(\.rowid), rows.map(\.rowid), "rows were updated in place")
        XCTAssertEqual(try vectorOwners(migrated), rows.map(\.rowid), "vectors survived")

        // The new columns are filled from the notes and the rules.
        let kinds = try migrated.read { db in try db.query("SELECT text, kind, kind_by, state, origin, uid IS NOT NULL, due IS NOT NULL FROM comments ORDER BY ts") {
            ($0.string(0), $0.string(1), $0.string(2), $0.string(3), $0.string(4), $0.int(5), $0.int(6)) } }
        XCTAssertEqual(kinds[0].1, "idea")
        XCTAssertEqual(kinds[1].1, "question")
        XCTAssertEqual(kinds[1].5, 1, "the stamped thought has its uid")
        XCTAssertEqual(kinds[2].1, "todo")
        XCTAssertEqual(kinds[2].6, 1, "rules read 'by friday' as a due date")
        XCTAssertTrue(kinds.allSatisfy { $0.2 == "rules" && $0.3 == "open" && $0.4 == "human" })

        embedAll(migrated)
        XCTAssertEqual(calls.count, 0, "re-embedding after the migration asks the model for nothing")
        XCTAssertEqual(try migrated.comments(on: terms).compactMap(\.uid).count, 1)
    }

    func testReloadWithOldRowsBelowTheCacheStillMakesZeroCalls() throws {
        // Even if the old rows are gone (a rebuilt index), the cache by input hash serves every vector.
        let notes = SidecarStore(vault: vault)
        try notes.append(Comment(timestamp: Date(timeIntervalSince1970: 1_800_000_000), text: "The supplier contract needs a signature"), to: FileRef(relativePath: "terms.md"))
        let store = try open()
        try store.reindex(); embedAll(store)
        calls.reset()
        try store.writer.exec("DELETE FROM comments")
        try store.reloadComments()
        embedAll(store)
        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(try vectorOwners(store).count, 1)
    }

    func testStateOnlyChangeKeepsTheRowidAndTheVector() throws {
        let notes = SidecarStore(vault: vault)
        let terms = FileRef(relativePath: "terms.md")
        try notes.append(Comment(timestamp: Date(timeIntervalSince1970: 1_800_000_000), text: "Call the supplier about the contract").stamped(), to: terms)
        let store = try open()
        try store.reindex(); embedAll(store)
        let before = try thoughtRows(store)
        let uid = try XCTUnwrap(try notes.comments(for: terms).first?.uid)
        calls.reset()
        _ = try notes.update(uid: uid, in: terms) { $0.meta?.state = .done; $0.meta?.stateAt = "2026-10-17 10:00" }
        try store.update([terms])
        let after = try thoughtRows(store)
        XCTAssertEqual(after.map(\.rowid), before.map(\.rowid))
        XCTAssertEqual(try vectorOwners(store), before.map(\.rowid), "the done thought still has its vector")
        XCTAssertEqual(try store.read { try $0.query("SELECT state FROM comments") { $0.string(0) } }, ["done"])
        // A snooze, a model's kind and a reply elsewhere in the thread are metadata too.
        _ = try notes.update(uid: uid, in: terms) { $0.meta?.state = .snoozed; $0.meta?.snoozeUntil = "2026-10-18 09:00"; $0.meta?.kind = .todo; $0.meta?.kindBy = .user }
        _ = try notes.appendReply(Comment(timestamp: Date(timeIntervalSince1970: 1_800_000_900), text: "Done, signed"), toUID: uid, in: terms)
        try store.update([terms])
        XCTAssertEqual(try thoughtRows(store).first?.rowid, before.first?.rowid)
        XCTAssertEqual(try store.read { try $0.query("SELECT kind, kind_by, state, snooze_until IS NOT NULL FROM comments WHERE uid = ?", uid) { ($0.string(0), $0.string(1), $0.string(2), $0.int(3)) } }.first?.1, "user")
        embedAll(store)
        XCTAssertEqual(calls.count, 1, "only the new reply needed a vector")
        XCTAssertEqual(try vectorOwners(store).count, 2)
    }

    func testEditedTextReplacesTheRowAndItsVector() throws {
        let notes = SidecarStore(vault: vault)
        let terms = FileRef(relativePath: "terms.md")
        try notes.append(Comment(timestamp: Date(timeIntervalSince1970: 1_800_000_000), text: "Call the supplier").stamped(), to: terms)
        let store = try open()
        try store.reindex(); embedAll(store)
        let uid = try XCTUnwrap(try notes.comments(for: terms).first?.uid)
        _ = try notes.update(uid: uid, in: terms) { $0.text = "Call the manufacturer instead" }
        try store.update([terms])
        XCTAssertEqual(try thoughtRows(store).map(\.text), ["Call the manufacturer instead"])
        XCTAssertEqual(try vectorOwners(store), [], "the old text's vector is gone until the new one is embedded")
        embedAll(store)
        XCTAssertEqual(try vectorOwners(store).count, 1)
    }

    func testRemovedNotesAreRemovedFromTheIndexAndRulesVersionTriggersAReload() throws {
        let notes = SidecarStore(vault: vault)
        let terms = FileRef(relativePath: "terms.md")
        try notes.append(Comment(text: "Call the supplier"), to: terms)
        var store: IndexStore? = try open()
        try store!.reindex()
        XCTAssertEqual(try store!.stats().comments, 1)
        try notes.removeSidecar(for: terms)
        try store!.reloadComments()
        XCTAssertEqual(try store!.stats().comments, 0)
        try notes.append(Comment(text: "Another thought"), to: terms)
        try store!.writer.run("INSERT OR REPLACE INTO meta(key, value) VALUES ('thought_rules', '0')")
        store = nil
        let reopened = try open()
        XCTAssertEqual(try reopened.stats().comments, 1, "a newer ThoughtRules.version re-reads the notes at open")
        XCTAssertEqual(reopened.metaValue("thought_rules"), String(ThoughtRules.version))
    }
}
