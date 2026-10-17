import XCTest
import FlamingoCore
import FlamingoExtract
@testable import FlamingoIndex

private struct CoverageFixtureExtractor: Extractor {
    static let extensions: Set<String> = ["coveragefixture"]
    init() {}
    func extract(_ url: URL) throws -> Extracted {
        let text = try String(contentsOf: url, encoding: .utf8)
        if text == "SLOW" { Thread.sleep(forTimeInterval: 0.4) }
        if text == "FAIL" {
            var out = Extracted.empty
            out.coverage = ExtractionCoverage(.failed, reason: "Fixture read failure")
            return out
        }
        return Extracted(text: text)
    }
}

final class IndexReliabilityTests: IndexTestCase {
    override class func setUp() {
        super.setUp()
        if !Extract.extractors.contains(where: { $0 == CoverageFixtureExtractor.self }) {
            Extract.extractors.insert(CoverageFixtureExtractor.self, at: 0)
        }
    }

    func testFolderIsAppliedBeforeEveryResultLimit() throws {
        for n in 0..<60 { try write("outside/\(n).fltest", "needle") }
        try write("client's work/inside.fltest", "needle")
        try store.reindex()
        let folder = "client's work"
        XCTAssertEqual(try store.search("needle", inFolder: folder, limit: 1).map(\.file.relativePath), [folder + "/inside.fltest"])
        XCTAssertEqual(try store.searchSections("needle", inFolder: folder, limit: 1).map(\.file.relativePath), [folder + "/inside.fltest"])
        XCTAssertEqual(try store.files(matching: "fltest", inFolder: folder, limit: 1), [ref(folder + "/inside.fltest")])
        var comments = Dictionary(uniqueKeysWithValues: (0..<60).map { (ref("outside/\($0).fltest"), [Comment(text: "needle")]) })
        comments[ref(folder + "/inside.fltest")] = [Comment(text: "needle")]
        try store.replaceAllComments(comments)
        XCTAssertEqual(try store.searchComments("needle", inFolder: folder, limit: 1).map(\.file.relativePath), [folder + "/inside.fltest"])
    }

    func testCJKMergesFTSAndSubstringAndGroupsBeforeLimit() throws {
        try write("a.fltest", "定价策略")
        let many = (1...100).map { "== page \($0): 页\n我们的定价策略在第三季度调整。" }.joined(separator: "\n")
        try write("b.fltest", many)
        try write("c.fltest", "我们的定价策略在第三季度调整。")
        try store.reindex()
        XCTAssertEqual(Set(try store.search("定价策略", limit: 3).map(\.file.relativePath)), ["a.fltest", "b.fltest", "c.fltest"])
        try store.replaceAllComments([ref("a.fltest"): [Comment(text: "定价策略")], ref("c.fltest"): [Comment(text: "我们的定价策略已经改变。")]])
        XCTAssertEqual(try store.searchComments("定价策略").count, 2)
    }

    func testFailurePreservesGoodTextPersistsStatusAndCanRetryWithoutStampChange() throws {
        let file = try write("brief.coveragefixture", "previous trustworthy words")
        try store.update([file])
        try write(file.relativePath, "FAIL")
        try store.update([file])
        XCTAssertEqual(try store.search("trustworthy").first?.file, file)
        let failed = try XCTUnwrap(try store.coverage(for: file))
        XCTAssertEqual(failed.coverage.state, .failed)
        XCTAssertNotNil(failed.retryAfter)
        store = try IndexStore(vault: vault)
        XCTAssertEqual(try store.coverage(for: file)?.coverage.reason, "Fixture read failure")
        try store.retryFailed()
        XCTAssertEqual(try store.coverage(for: file)?.attemptCount, failed.attemptCount + 1)
        try write(file.relativePath, "recovered accurate words")
        try store.update([file], force: true)
        XCTAssertEqual(try store.health().complete, 1)
        XCTAssertEqual(try store.search("recovered").first?.file, file)
        XCTAssertNil(try store.coverage(for: file)?.retryAfter)
    }

    func testOversizedFileStillHasSearchableMetadata() throws {
        let file = try write("enormous-planning-notes.txt", "")
        let handle = try FileHandle(forWritingTo: vault.url(for: file))
        try handle.truncate(atOffset: 51 * 1024 * 1024)
        try handle.close()
        try store.update([file])
        XCTAssertEqual(try store.indexedFiles(), [file])
        XCTAssertEqual(try store.search("enormous planning").first?.file, file)
        XCTAssertEqual(try store.coverage(for: file)?.coverage.state, .metadataOnly)
        XCTAssertEqual(try store.health().metadataOnly, 1)
    }

    func testKeywordHitPointsToMatchingSourceLine() throws {
        let file = try write("source.txt", "one\ntwo\nthree\nneedle appears here\nfive\n")
        try store.update([file])
        XCTAssertEqual(try store.search("needle").first?.anchor, FileAnchor(kind: .line, value: "4"))
        XCTAssertEqual(try store.searchSections("needle").first?.anchor, FileAnchor(kind: .line, value: "4"))
    }

    func testCommentProvenanceSurvivesAllQueryPathsAndReopen() throws {
        let file = try write("source.txt", "source")
        try store.update([file])
        let provenance = CommentProvenance(origin: .ai, model: "fixture-model", appName: "Flamingo", reason: "Analysis")
        let comment = Comment(text: "Analytical 定价策略 decision", provenance: provenance)
        try store.replaceAllComments([file: [comment]])
        store = try IndexStore(vault: vault)
        XCTAssertEqual(try store.comments(on: file).first?.provenance, provenance)
        XCTAssertEqual(try store.searchComments("Analytical").first?.comment.provenance, provenance)
        XCTAssertEqual(try store.searchComments("定价策略").first?.comment.provenance, provenance)
    }

    func testMarkdownSourceLinkAppearsInBacklinksAndGraph() throws {
        let target = try write("target.txt", "target")
        let source = try write("note.mdown", "A source link to [[target.txt]]")
        try store.reindex()
        XCTAssertTrue(try store.buildGraph().edges.contains { $0.source == source.relativePath && $0.target == target.relativePath })
        XCTAssertTrue(try store.backlinks(to: target).contains { $0.0 == source && $0.1.text.contains("[[target.txt]]") })
    }

    func testDOCXNoteOnlyTermIsIndexedAtItsNote() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FlamingoExtractTests/Fixtures/report.docx")
        let file = ref("report.docx")
        try FileManager.default.copyItem(at: fixture, to: vault.url(for: file))
        try store.update([file])
        let hit = try XCTUnwrap(try store.search("unaudited", inFolder: nil, includeSemantic: false).first)
        XCTAssertEqual(hit.file, file)
        XCTAssertEqual(hit.anchor, FileAnchor(kind: .node, value: "Note 2"))
    }

    func testCancelStopsWaitingForTheRestOfAnExtractionBatch() throws {
        let refs = try (0..<100).map { try write("slow-\($0).coveragefixture", "SLOW") }
        let started = Date()
        try store.update(refs, force: true, shouldCancel: { Date().timeIntervalSince(started) > 0.05 })
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertLessThan(try store.stats().files, 100)
        // Already-active native operations finish independently; queued ones never start.
    }

    func testCancelledReindexNeverDeletesUnseenRows() throws {
        try write("a.fltest", "alpha")
        try write("b.fltest", "beta")
        try store.reindex()
        try store.reindex(force: false, progress: { _ in }, shouldCancel: { true })
        XCTAssertEqual(try store.stats().files, 2)
    }
    func testPruningRechecksDiskAndPreservesUnreadableContent() throws {
        let hidden = try write("locked/known.fltest", "preserved trustworthy words")
        let live = try write("live.fltest", "created concurrently with a scan")
        try store.update([hidden, live])
        let folder = root.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        XCTAssertEqual(try store.pruneUnseen([hidden, live]), 0)
        XCTAssertEqual(try store.search("trustworthy", inFolder: nil, includeSemantic: false).first?.file, hidden)
        XCTAssertEqual(try store.coverage(for: hidden)?.coverage.state, .failed)
        try store.update([ref("locked")])
        XCTAssertTrue(try store.indexedFiles().contains(hidden))
        try store.reindex()
        XCTAssertTrue(try store.indexedFiles().contains(hidden))
        XCTAssertTrue(try store.indexedFiles().contains(live))
    }

    func testPruningRemovesConfirmedDeletionAndNewlyIgnoredRows() throws {
        let deleted = try write("deleted.fltest", "old")
        let excluded = try write("excluded.fltest", "old")
        try store.update([deleted, excluded])
        try FileManager.default.removeItem(at: vault.url(for: deleted))
        try "excluded.fltest\n".write(to: vault.ignoreURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(try store.pruneUnseen([deleted, excluded]), 2)
        XCTAssertEqual(try store.stats().files, 0)
    }

    func testIdentityRenamesPersistUntilAcknowledgedAndAdvanceAcrossChains() throws {
        let a = try write("a.fltest", "durable move")
        _ = try FileIdentity.id(for: vault.url(for: a))
        try store.update([a])
        let b = ref("b.fltest"), c = ref("c.fltest")
        try FileManager.default.moveItem(at: vault.url(for: a), to: vault.url(for: b))
        try store.update([a, b])
        let first = try XCTUnwrap(try store.pendingRenames().first)
        XCTAssertEqual(first.from, a); XCTAssertEqual(first.to, b)
        store = try IndexStore(vault: vault)
        XCTAssertEqual(try store.pendingRenames(), [first])
        try FileManager.default.moveItem(at: vault.url(for: b), to: vault.url(for: c))
        try store.update([b, c])
        try store.acknowledgeRename(first)
        let pending = try store.pendingRenames()
        XCTAssertEqual(Set(pending.map(\.from)), [a, b])
        XCTAssertTrue(pending.allSatisfy { $0.to == c })
        for move in pending { try store.acknowledgeRename(move) }
        XCTAssertEqual(try store.pendingRenames(), [])
        XCTAssertEqual(try store.indexedFiles(), [c])
    }

    func testIgnoreChangeRemovesContentAndCommentHitsButKeepsSidecarBytes() throws {
        let file = try write("private/brief.fltest", "confidential source")
        let notes = SidecarStore(vault: vault)
        try notes.append(Comment(text: "confidential thought"), to: file)
        try store.update([file])
        let saved = try Data(contentsOf: notes.sidecarURL(for: file))
        try "private/\n".write(to: vault.ignoreURL, atomically: true, encoding: .utf8)
        try store.reindex()
        XCTAssertEqual(try store.search("confidential", inFolder: nil, includeSemantic: false), [])
        XCTAssertEqual(try store.searchComments("confidential"), [])
        XCTAssertEqual(try Data(contentsOf: notes.sidecarURL(for: file)), saved)
    }

    func testUnreadableSidecarPreservesIndexedThoughtAndReturnsFailure() throws {
        let file = try write("brief.fltest", "source")
        let notes = SidecarStore(vault: vault)
        try notes.append(Comment(text: "remember my decision"), to: file)
        try store.update([file])
        let url = notes.sidecarURL(for: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        XCTAssertThrowsError(try store.update([file]))
        XCTAssertEqual(try store.searchComments("decision").first?.file, file)
    }

    func testHistoricalWikilinksStillProduceBacklinksAndGraphAfterRename() throws {
        let old = try write("original.fltest", "source")
        let note = try write("note.md", "See [[original.fltest]]")
        let other = try write("thought.fltest", "thought source")
        try SidecarStore(vault: vault).append(Comment(text: "Decision linked to [[original.fltest]]"), to: other)
        _ = try FileIdentity.id(for: vault.url(for: old))
        try store.update([old, note, other])
        let moved = ref("renamed.fltest")
        try FileManager.default.moveItem(at: vault.url(for: old), to: vault.url(for: moved))
        try store.update([old, moved])
        try PathAliases(vault: vault).reconcile(oldPath: old.relativePath, newPath: moved.relativePath)
        XCTAssertEqual(Set(try store.backlinks(to: moved).map { $0.0 }), [note, other])
        let graph = try store.buildGraph()
        XCTAssertTrue(graph.edges.contains { $0.source == note.relativePath && $0.target == moved.relativePath })
        XCTAssertTrue(graph.edges.contains { $0.source == other.relativePath && $0.target == moved.relativePath })
    }

    func testVersionFiveMigrationKeepsExistingSearchContent() throws {
        let file = try write("existing.fltest", "migration preserved content")
        try store.update([file])
        try store.writer.exec("DROP TABLE pending_renames; PRAGMA user_version = 5")
        store = try IndexStore(vault: vault)
        XCTAssertEqual(try store.search("preserved", inFolder: nil, includeSemantic: false).first?.file, file)
        XCTAssertEqual(try store.pendingRenames(), [])
        XCTAssertEqual(try store.writer.userVersion(), IndexStore.schemaVersion)
        XCTAssertEqual(try store.writer.scalarInt("SELECT count(*) FROM sqlite_master WHERE name IN ('semantic_cache', 'comment_vectors')"), 2,
                       "the v8 step creates the semantic tables")
    }

    func testOutboxRetryDoesNotMoveReplacementOldPathNote() throws {
        let old = try write("old.fltest", "original")
        let notes = SidecarStore(vault: vault)
        try notes.append(Comment(text: "original thought"), to: old)
        try store.update([old])
        let moved = ref("moved.fltest")
        try FileManager.default.moveItem(at: vault.url(for: old), to: vault.url(for: moved))
        try store.update([old, moved])
        let event = try XCTUnwrap(try store.pendingRenames().first)
        let identity = try XCTUnwrap(event.fileIdentity)
        XCTAssertEqual(try notes.comments(for: moved).map(\.text), ["original thought"])
        try write(old.relativePath, "replacement")
        try notes.append(Comment(text: "replacement thought"), to: old)
        let oldBytes = try Data(contentsOf: notes.sidecarURL(for: old))
        let newBytes = try Data(contentsOf: notes.sidecarURL(for: moved))
        XCTAssertFalse(try notes.move(sidecarFor: event.from, to: event.to, matching: identity))
        XCTAssertEqual(try Data(contentsOf: notes.sidecarURL(for: old)), oldBytes)
        XCTAssertEqual(try Data(contentsOf: notes.sidecarURL(for: moved)), newBytes)
    }

    func testOutboxRetryRejectsReplacedDestinationBeforeChangingNotes() throws {
        let old = try write("old.fltest", "original")
        let notes = SidecarStore(vault: vault)
        try notes.append(Comment(text: "original thought"), to: old)
        let identity = try XCTUnwrap(try FileIdentity.existingID(for: vault.url(for: old)))
        let destination = try write("destination.fltest", "unrelated")
        try notes.append(Comment(text: "unrelated thought"), to: destination)
        let oldBytes = try Data(contentsOf: notes.sidecarURL(for: old))
        let newBytes = try Data(contentsOf: notes.sidecarURL(for: destination))
        XCTAssertThrowsError(try notes.move(sidecarFor: old, to: destination, matching: identity))
        XCTAssertEqual(try Data(contentsOf: notes.sidecarURL(for: old)), oldBytes)
        XCTAssertEqual(try Data(contentsOf: notes.sidecarURL(for: destination)), newBytes)
    }

    func testDeliberateUnindexedRenameIsDurableAndDoesNotRedirectOtherIdentity() throws {
        let original = try write("first.fltest", "first")
        let firstID = try FileIdentity.id(for: vault.url(for: original))
        let middle = ref("middle.fltest"), final = ref("final.fltest")
        try FileManager.default.moveItem(at: vault.url(for: original), to: vault.url(for: middle))
        try store.recordRename(from: original, to: middle, identity: firstID)
        try FileManager.default.moveItem(at: vault.url(for: middle), to: vault.url(for: final))
        try write(middle.relativePath, "replacement")
        let secondID = try FileIdentity.id(for: vault.url(for: middle))
        let other = ref("other.fltest")
        try FileManager.default.moveItem(at: vault.url(for: middle), to: vault.url(for: other))
        try store.recordRename(from: middle, to: other, identity: secondID)
        // A different file reusing 'middle' must not redirect the original event to 'other'.
        XCTAssertEqual(try store.pendingRenames().first(where: { $0.from == original })?.to, middle)
        try store.recordRename(from: middle, to: final, identity: firstID)
        store = try IndexStore(vault: vault)
        let events = try store.pendingRenames()
        XCTAssertEqual(events.first(where: { $0.from == original })?.to, final)
        XCTAssertEqual(events.first(where: { $0.fileIdentity == secondID })?.to, other)
        XCTAssertEqual(try store.stats().files, 0, "journaling does not require an indexed file")
    }

    func testLegacyOutboxRecoversOnlyMatchingIndexedIdentity() throws {
        let file = try write("current.fltest", "source")
        let id = try FileIdentity.id(for: vault.url(for: file))
        try store.update([file])
        try store.writer.run("INSERT INTO pending_renames(from_path, to_path) VALUES(?, ?)", "previous.fltest", file.relativePath)
        XCTAssertEqual(try store.pendingRenames().first?.fileIdentity, id)
        try store.writer.run("UPDATE pending_renames SET file_identity = NULL")
        try FileIdentity.assign(UUID(), to: vault.url(for: file))
        XCTAssertNil(try store.pendingRenames().first?.fileIdentity)
    }

}
