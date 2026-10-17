import XCTest
import FlamingoCore
@testable import FlamingoIndex

final class UnifiedSearchTests: IndexTestCase {
    func testOneQueryFindsNamesContentsAndThoughtsWithExactLocations() throws {
        try write("budget-export.bin", "")
        try write("decks/review.fltest", "== slide 7: Forecast\nThe revised budget includes three teams.")
        let annotated = try write("notes/meeting.fltest", "Completely separate text")
        let thought = Comment(anchor: FileAnchor(kind: .page, value: "4"), text: "budget needs approval")
        let sidecars = SidecarStore(vault: vault)
        try sidecars.append(thought, to: annotated)
        let storedThought = try XCTUnwrap(sidecars.comments(for: annotated).first)
        try store.reindex()

        let result = try store.unifiedSearch(UnifiedSearchQuery(raw: "budget"))
        let files = Dictionary(result.results.map { ($0.file.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertNotNil(files["budget-export.bin"])
        XCTAssertEqual(files["decks/review.fltest"]?.hits.first?.anchor, FileAnchor(kind: .slide, value: "7"))
        XCTAssertTrue(files["decks/review.fltest"]?.hits.first?.snippet.contains("«budget»") == true)
        XCTAssertEqual(files["notes/meeting.fltest"]?.hits.first?.commentID, storedThought.id)
        XCTAssertEqual(files["notes/meeting.fltest"]?.hits.first?.anchor, thought.anchor)
    }

    func testFilterBeforeLimitsFindsAnOtherwiseBuriedMatch() throws {
        // Hundreds of stronger matches elsewhere must not consume a small filtered limit.
        try store.writer.transaction {
            for index in 0..<500 {
                try insert(path: "outside/\(index).pdf", text: "budget budget budget budget", modified: 1_700_000_000)
            }
            try insert(path: "O'Brien 100%_done/deep/needle.md", text: "There is one budget entry.", modified: 1_750_000_000)
            try insert(path: "O'Brien 100%_done/deep/old.md", text: "budget budget", modified: 1_650_000_000)
        }
        let query = UnifiedSearchQuery(raw: #"budget path:"O'Brien 100%_done" ext:md after:2024-01-01 before:2026-01-01"#)
        let response = try store.unifiedSearch(query, limit: 1)
        XCTAssertEqual(response.results.map(\.file.relativePath), ["O'Brien 100%_done/deep/needle.md"])
        XCTAssertFalse(response.isTruncated)
    }

    func testFilterOnlyAndBlankQueriesReturnUsefulRecentFiles() throws {
        try insert(path: "older.pdf", text: "", modified: 1_650_000_000)
        try insert(path: "newer.md", text: "", modified: 1_750_000_000)
        try insert(path: "newest.pdf", text: "", modified: 1_760_000_000)
        let filtered = try store.unifiedSearch(UnifiedSearchQuery(raw: "type:pdf"))
        XCTAssertEqual(filtered.results.map(\.file.relativePath), ["newest.pdf", "older.pdf"])
        let recents = try store.unifiedSearch(UnifiedSearchQuery(raw: ""), recentPaths: ["older.pdf"], limit: 1)
        XCTAssertEqual(recents.results.first?.file.relativePath, "older.pdf")
        XCTAssertTrue(recents.isTruncated)
    }

    func testChineseSubstringMatchesAlongsideTokenBoundaryMatches() throws {
        try write("one.fltest", "== slide 3: 费用\n这里是修改后的预算数据。")
        try write("two.fltest", "== page 2: 预算\n预算 数据")
        try store.reindex()
        let results = try store.unifiedSearch(UnifiedSearchQuery(raw: "预算")).results
        XCTAssertEqual(Set(results.map(\.file.relativePath)), ["one.fltest", "two.fltest"])
        XCTAssertEqual(results.first { $0.file.relativePath == "one.fltest" }?.hits.first?.anchor, FileAnchor(kind: .slide, value: "3"))
    }

    func testFoldersIncludeIndexedAncestorsAndProvidedEmptyFolders() throws {
        try write("Research/Experiments/run.fltest", "data")
        try store.reindex()
        let all = try store.unifiedSearch(UnifiedSearchQuery(raw: "type:folder"), directoryPaths: ["Research/Empty", ".flamingo", "../outside"])
        XCTAssertEqual(Set(all.results.map(\.file.relativePath)), ["Research", "Research/Experiments", "Research/Empty"])
        XCTAssertTrue(all.results.allSatisfy(\.isDirectory))
        let scoped = try store.unifiedSearch(UnifiedSearchQuery(raw: #"Exper path:"Research""#))
        XCTAssertTrue(scoped.results.contains { $0.file.relativePath == "Research/Experiments" && $0.isDirectory })
        let typed = try store.unifiedSearch(UnifiedSearchQuery(raw: "type:pdf"), directoryPaths: ["PDF archives"])
        XCTAssertTrue(typed.results.isEmpty)
    }

    func testMetadataOnlyFilesAreDiscoverableWithoutReadingTheirContents() throws {
        let file = try write("budget.pdf", "This is not a real PDF")
        try store.updateMetadata([file], reason: "Cloud file is not downloaded")
        let result = try store.unifiedSearch(UnifiedSearchQuery(raw: "budget")).results.first
        XCTAssertEqual(result?.file, file)
        XCTAssertEqual(result?.coverage, "Filename only: Cloud file is not downloaded")
    }

    func testFuzzyPathAndScopeDoNotNeedExactNames() throws {
        try write("finance/q3-model.fltest", "")
        try write("unrelated/q3-model.fltest", "")
        try store.reindex()
        let result = try store.unifiedSearch(UnifiedSearchQuery(raw: "q3mod path:finance"))
        XCTAssertEqual(result.results.map(\.file.relativePath), ["finance/q3-model.fltest"])
    }

    func testInvalidFiltersAreVisibleAndDoNotBroadenSearch() throws {
        try write("budget.fltest", "budget")
        try store.reindex()
        for raw in ["budget after:2026-02-30", "budget after:tomorrow", "path:../elsewhere", "after:2026-10-20 before:2026-10-01", "type:folder ext:pdf"] {
            let query = UnifiedSearchQuery(raw: raw)
            XCTAssertFalse(query.issues.isEmpty, raw)
            let response = try store.unifiedSearch(query)
            XCTAssertTrue(response.results.isEmpty, raw)
            XCTAssertNotNil(response.notice, raw)
        }
    }

    func testNaturalCuesExposeDeterministicFilters() {
        let now = Date(timeIntervalSince1970: 1_792_130_400)
        let query = UnifiedSearchQuery(raw: "PDFs from last week", now: now)
        XCTAssertEqual(query.extensions, ["pdf"])
        XCTAssertEqual(query.text, "")
        let start = Calendar.current.dateInterval(of: .weekOfYear, for: now)!.start
        XCTAssertEqual(query.before, start)
        XCTAssertEqual(query.after, Calendar.current.date(byAdding: .day, value: -7, to: start))
        XCTAssertEqual(query.summary.count, 3)
        let presentations = UnifiedSearchQuery(raw: "presentations budget")
        XCTAssertEqual(presentations.extensions, ["ppt", "pptx", "key"])
        XCTAssertEqual(presentations.text, "budget")
    }

    func testLexicalSearchNeverRequestsAnEmbeddingEvenWithVectorsAvailable() throws {
        try write("money.fltest", "The budget is final")
        try store.reindex()
        store.embedding.embedder.fake = { inputs in inputs.map { _ in [1, 0] } }
        XCTAssertGreaterThan(store.embedPending(), 0)
        let calls = UnifiedSearchCallCounter()
        store.embedding.embedder.fake = { inputs in calls.increment(); return inputs.map { _ in [1, 0] } }
        XCTAssertFalse(try store.unifiedSearch(UnifiedSearchQuery(raw: "budget")).results.isEmpty)
        XCTAssertEqual(calls.value, 0)
    }

    func testSemanticFiltersApplyBeforeRankingCap() throws {
        for index in 0..<210 { try insert(path: "outside/\(index).pdf", text: "supplier contract", modified: 1_750_000_000) }
        try insert(path: "inside/target.md", text: "supplier agreement", modified: 1_750_000_000)
        store.embedding.embedder.fake = { inputs in inputs.map { _ in [1, 0] } }
        XCTAssertGreaterThan(store.embedPending(), 0)
        let result = try store.unifiedSearch(UnifiedSearchQuery(raw: "manufacturer ext:md path:inside after:2024-01-01"), limit: 1, includeSemantic: true)
        XCTAssertEqual(result.results.map(\.file.relativePath), ["inside/target.md"])
    }


    func testQuotedPhrasesRemainLiteralText() {
        let query = UnifiedSearchQuery(raw: #""from last week" "path:archive""#)
        XCTAssertNil(query.after)
        XCTAssertNil(query.folder)
        XCTAssertEqual(query.text, #""from last week" "path:archive""#)
        XCTAssertTrue(query.summary.isEmpty)
    }

    func testExactCellAndLineAnchorsSurviveUnifiedSearch() throws {
        try write("sheet.fltest", "== cell Q3!B12: Forecast\nExactneedle allocation")
        try write("source.txt", "first line\nsecond line\nExactneedle allocation\nfourth line")
        try store.reindex()
        let results = try store.unifiedSearch(UnifiedSearchQuery(raw: "Exactneedle")).results
        XCTAssertEqual(results.first { $0.file.relativePath == "sheet.fltest" }?.hits.first?.anchor, FileAnchor(kind: .cell, value: "Q3!B12"))
        XCTAssertEqual(results.first { $0.file.relativePath == "source.txt" }?.hits.first?.anchor, FileAnchor(kind: .line, value: "3"))
    }

    func testReadOnlyDiagnosticsDoNotRefreshVersionsOrCreateMissingIndexes() throws {
        try store.writer.run("UPDATE meta SET value = ? WHERE key = 'extract_version'", "older-extraction-version")
        let readonly = try IndexStore(vault: vault, readOnly: true)
        XCTAssertEqual(try readonly.stats().files, 0)
        XCTAssertEqual(try store.read { try $0.query("SELECT value FROM meta WHERE key = 'extract_version'") { $0.string(0) }.first }, "older-extraction-version")
        XCTAssertThrowsError(try readonly.writer.run("INSERT INTO meta(key,value) VALUES('readonly-test','write')"))
        let missing = root.appendingPathComponent("uncreated")
        XCTAssertThrowsError(try IndexStore(vault: Vault(root: missing), readOnly: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testLiveCatalogFindsUnindexedFilesWithFiltersWithoutReadingOrIndexing() throws {
        let target = try write("Existing mess/LibrosShare_INTERNAL.pptx", "These bytes must not be parsed")
        let other = try write("Elsewhere/LibrosShare.pdf", "")
        let stamp = Date(timeIntervalSince1970: 1_750_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: vault.url(for: target).path)
        let catalog = [other, target]
        let query = UnifiedSearchQuery(raw: #"librosshare type:presentations path:"Existing mess" after:2024-01-01 before:2026-01-01"#)
        let response = try store.unifiedSearch(query, limit: 1, catalogFiles: catalog)
        XCTAssertEqual(response.results.map(\.file), [target])
        XCTAssertEqual(response.results.first?.coverage, "Content not indexed yet")
        XCTAssertEqual(response.results.first?.modified, stamp)
        XCTAssertTrue(response.results.first?.hits.isEmpty == true)
        XCTAssertEqual(try store.stats().files, 0)
    }

    func testCatalogFallbackDoesNotDuplicateAnIndexedFileOrDowngradeCoverage() throws {
        let file = try write("budget.fltest", "== slide 8: Revised\nbudget details")
        try store.reindex()
        let response = try store.unifiedSearch(UnifiedSearchQuery(raw: "budget"), catalogFiles: [file])
        XCTAssertEqual(response.results.count, 1)
        XCTAssertNil(response.results.first?.coverage)
        XCTAssertEqual(response.results.first?.hits.first?.anchor, FileAnchor(kind: .slide, value: "8"))
    }

    func testDedicatedReaderSearchesWhileGraphReaderAndIndexWriterAreBusy() throws {
        let file = try write("project/budget.fltest", "== slide 7: Revised\nbudget details")
        try store.reindex()
        let interactive = try IndexStore(vault: vault, readOnly: true)
        let graphEntered = DispatchSemaphore(value: 0)
        let releaseGraph = DispatchSemaphore(value: 0)
        let graphFinished = expectation(description: "background graph reader released")
        let original = try XCTUnwrap(store)
        DispatchQueue.global(qos: .utility).async {
            defer { graphFinished.fulfill() }
            try? original.read(snapshot: true) { db in
                _ = try db.scalarInt("SELECT count(*) FROM files")
                graphEntered.signal()
                _ = releaseGraph.wait(timeout: .now() + 5)
            }
        }
        XCTAssertEqual(graphEntered.wait(timeout: .now() + 2), .success)
        original.writeLock.lock()
        do {
            try original.writer.exec("BEGIN IMMEDIATE")
            let started = Date()
            let result = try interactive.unifiedSearch(UnifiedSearchQuery(raw: "budget"))
            XCTAssertEqual(result.results.first?.file, file)
            XCTAssertEqual(result.results.first?.hits.first?.anchor, FileAnchor(kind: .slide, value: "7"))
            XCTAssertLessThan(Date().timeIntervalSince(started), 1, "interactive reads must not wait for the graph reader or writer")
            try original.writer.exec("ROLLBACK")
        } catch {
            try? original.writer.exec("ROLLBACK")
            original.writeLock.unlock()
            releaseGraph.signal()
            wait(for: [graphFinished], timeout: 2)
            throw error
        }
        original.writeLock.unlock()
        releaseGraph.signal()
        wait(for: [graphFinished], timeout: 2)
    }

    func testDedicatedReaderRefreshesFolderCacheAfterExternalCommit() throws {
        try write("Older/one.fltest", "first")
        try store.reindex()
        let interactive = try IndexStore(vault: vault, readOnly: true)
        XCTAssertEqual(try interactive.unifiedSearch(UnifiedSearchQuery(raw: "type:folder")).results.map(\.file.relativePath), ["Older"])
        let added = try write("New folder/two.fltest", "second")
        try store.update([added])
        XCTAssertEqual(Set(try interactive.unifiedSearch(UnifiedSearchQuery(raw: "type:folder")).results.map(\.file.relativePath)), ["Older", "New folder"])
        try store.remove([added])
        XCTAssertEqual(try interactive.unifiedSearch(UnifiedSearchQuery(raw: "type:folder")).results.map(\.file.relativePath), ["Older"])
    }

    func testCancellationStopsBeforeDoingWork() {
        XCTAssertThrowsError(try store.unifiedSearch(UnifiedSearchQuery(raw: "budget"), shouldCancel: { true })) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    private func insert(path: String, text: String, modified: Double) throws {
        try store.writer.run("INSERT INTO files(path, mtime, size, ext, indexed_at) VALUES(?, ?, 0, ?, 0)", path, modified, (path as NSString).pathExtension.lowercased())
        try store.writer.run("INSERT INTO sections(path, ord, anchor_kind, anchor_value, title, text) VALUES(?, 1, 'page', '3', ?, ?)", path, (path as NSString).lastPathComponent, text)
    }
}

private final class UnifiedSearchCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

final class UnifiedNameScoreTests: XCTestCase {
    func testSeparatorsAndExtensionsDoNotHideAnExactName() {
        XCTAssertEqual(IndexStore.unifiedNameScore("q3-board-review.pptx", tokens: ["q3", "board", "review"], fuzzy: 0), 110)
        XCTAssertEqual(IndexStore.unifiedNameScore("Pricing_Memo v2.docx", tokens: ["pricing", "memo"], fuzzy: 0), 85)
        XCTAssertLessThan(IndexStore.unifiedNameScore("pricing-memo.docx", tokens: ["board"], fuzzy: 100), 85)
    }
}
