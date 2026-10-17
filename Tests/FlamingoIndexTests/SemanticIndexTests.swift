import XCTest
import SQLite3
import FlamingoCore
@testable import FlamingoIndex

/// Passages, the in-memory vector index, hybrid ranking and file similarity, with a
/// deterministic fake model: one dimension per concept.
final class SemanticIndexTests: XCTestCase {
    var root: URL!
    var store: IndexStore!

    static let concepts: [[String]] = [
        ["price", "pay", "cost", "dollars", "charge", "pricing", "cheap"],
        ["contract", "agreement", "manufacturer", "supplier", "vendor"],
        ["lamp", "light", "glow", "flicker", "bulb", "brightness"],
        ["dog", "puppy", "vet", "vaccine", "rabies"],
    ]
    static func vector(_ text: String) -> [Float] {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        return concepts.map { c in Float(words.filter(c.contains).count) } + [0.15]
    }
    static let fake: @Sendable ([String]) -> [[Float]]? = { $0.map(vector) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("semantic-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("terms.md", "The supplier agreement binds the manufacturer to the contract.")
        try write("money.md", "We will charge forty dollars; the price is final.")
        try write("lamp.md", "A lamp with a warm glow and no flicker at any brightness.")
        try write("bulb.md", "Replacement bulb: warm light, glow like a filament lamp.")
        try write("dog.md", "The puppy sees the vet for its rabies vaccine in March.")
        store = try IndexStore(vault: Vault(root: root))
        store.embedding.embedder.fake = Self.fake
        try store.reindex()
    }

    override func tearDownWithError() throws { store = nil; try? FileManager.default.removeItem(at: root) }

    func write(_ name: String, _ text: String) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func embedAll() { while store.embedPending() > 0 {} }

    // MARK: Passages

    func testLongTextSplitsAtSentenceEndsWithOverlap() {
        let sentence = "The quarterly plan covers hiring, pricing and the launch calendar in detail. "
        let text = String(repeating: sentence, count: 60)
        let chunks = SemanticChunker.split(text)
        XCTAssertGreaterThan(chunks.count, 3)
        let scalars = Array(text.unicodeScalars)
        for (i, c) in chunks.enumerated() {
            XCTAssertEqual(String(String.UnicodeScalarView(scalars[c.offset..<(c.offset + c.length)])), c.body)
            XCTAssertLessThanOrEqual(c.length, 1300, "about 240 tokens")
            if i + 1 < chunks.count {
                XCTAssertTrue(c.body.hasSuffix(". ") || c.body.hasSuffix("."), "cut after a sentence: \(c.body.suffix(20))")
                XCTAssertLessThan(chunks[i + 1].offset, c.offset + c.length, "overlaps the next passage")
            }
        }
        XCTAssertEqual(chunks.last.map { $0.offset + $0.length }, scalars.count, "covers the end")
        XCTAssertTrue(SemanticChunker.split("12 34 56 —").isEmpty, "nothing worth embedding")
        let han = String(repeating: "这是一个关于定价和发布计划的句子。", count: 40)
        XCTAssertGreaterThan(SemanticChunker.split(han).count, 2, "Han text counts about a token a character")
    }

    func testPassageOffsetsReadBackWithSQLiteSubstr() throws {
        let text = "Café 👩‍👩‍👧 naïve e\u{301}cole — " + String(repeating: "word ", count: 400) + "end"
        let chunks = SemanticChunker.split(text)
        XCTAssertGreaterThan(chunks.count, 1)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let database = try XCTUnwrap(db)
        for c in chunks {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(database, "SELECT substr(?1, ?2 + 1, ?3)", -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int64(stmt, 2, Int64(c.offset))
            sqlite3_bind_int64(stmt, 3, Int64(c.length))
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
            XCTAssertEqual(String(cString: sqlite3_column_text(stmt, 0)), c.body)
            sqlite3_finalize(stmt)
        }
    }

    func testHeadersNameTheFileAndSection() {
        let file = SemanticChunker.FileContext(path: "docs/pricing-memo.docx", title: "Arc Pricing", tags: nil)
        XCTAssertEqual(SemanticChunker.sectionHeader(file, title: "Recommendation", anchor: FileAnchor(kind: .page, value: "2")),
                       "Arc Pricing (pricing-memo.docx) › Recommendation")
        XCTAssertEqual(SemanticChunker.sectionHeader(file, title: nil, anchor: FileAnchor(kind: .slide, value: "3")), "Arc Pricing (pricing-memo.docx) › slide 3")
        XCTAssertEqual(SemanticChunker.fileHeader(file), "Arc Pricing (pricing-memo.docx) in docs")
        XCTAssertTrue(SemanticChunker.card(outline: ["Options", "Risks", "Options"], opening: "To: Priya\nFrom: Tom").hasPrefix("Contents: Options; Risks\n"))
        XCTAssertEqual(SemanticChunker.columnHeader("Tier\tPrice\nArc\t249"), "Tier\tPrice")
    }

    // MARK: Vectors

    func testInt8CodecKeepsCosine() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            let v = Embedder.normalized((0..<768).map { _ in Float.random(in: -1...1, using: &rng) })
            let back = VectorCodec.decode(VectorCodec.encode(v))!
            let cosine = zip(v, back).map(*).reduce(0, +)
            XCTAssertGreaterThan(cosine, 0.999)
            let truncated = VectorCodec.decode(VectorCodec.encode(v), dimensions: 256)!
            XCTAssertEqual(truncated.count, 256)
            XCTAssertEqual(truncated.map { $0 * $0 }.reduce(0, +), 1, accuracy: 0.001)
        }
    }

    func testIndexTopKMatchesBruteForce() throws {
        embedAll()
        let indexes = store.semanticIndexes()
        let (index, _) = try XCTUnwrap(indexes.first)
        let q = Embedder.normalized(Self.vector("supplier contract price"))
        let fast = index.nearest(q, k: 3).map(\.row)
        var all: [(Int32, Float)] = []
        index.forEachRow { row, _, _ in
            let v = index.vector(row)
            all.append((row, zip(v, q).map(*).reduce(0, +)))
        }
        XCTAssertEqual(fast, all.sorted { $0.1 > $1.1 }.prefix(3).map(\.0))
    }

    func testEditsReachTheLoadedIndexWithoutReloading() throws {
        embedAll()
        XCTAssertEqual(try store.semanticSearch("puppy vaccine", limit: 1).first?.hit.file.relativePath, "dog.md")
        try write("dog.md", "Invoice: pay the supplier forty dollars.")
        try store.update([FileRef(relativePath: "dog.md")])
        embedAll()
        let hits = try store.semanticSearch("puppy vaccine", limit: 5)
        XCTAssertFalse(hits.contains { $0.hit.file.relativePath == "dog.md" }, "old vectors are gone")
        XCTAssertTrue(try store.semanticSearch("supplier price", limit: 5).contains { $0.hit.file.relativePath == "dog.md" })
    }

    func testUnchangedTextIsNeverEmbeddedTwice() throws {
        embedAll()
        let calls = Counter()
        store.embedding.embedder.fake = { inputs in calls.add(inputs.count); return inputs.map(Self.vector) }
        // Re-extraction deletes and rewrites every row; the cached vectors come back by hash.
        try store.update(try store.indexedFiles(), force: true)
        embedAll()
        XCTAssertEqual(calls.value, 0)
        let progress = try store.embeddingProgress()
        XCTAssertEqual(progress.embedded, progress.total)
        try write("lamp.md", "A lamp with a cold glow.")
        try store.update([FileRef(relativePath: "lamp.md")])
        embedAll()
        XCTAssertGreaterThan(calls.value, 0, "changed text is embedded")
        XCTAssertLessThanOrEqual(calls.value, 2, "only that file's passages")
    }

    func testThoughtsAreSearchableByMeaning() throws {
        let note = Comment(anchor: FileAnchor(kind: .line, value: "1"), text: "Ask the vet whether the puppy needs a booster.")
        try SidecarStore(vault: Vault(root: root)).append(note, to: FileRef(relativePath: "terms.md"))
        try store.reindex()
        embedAll()
        XCTAssertEqual(store.semanticStatus().embeddedComments, 1)
        let hits = try store.semanticSearch("rabies vaccine dog", limit: 5)
        let thought = try XCTUnwrap(hits.first { $0.hit.commentID != nil })
        XCTAssertEqual(thought.hit.file.relativePath, "terms.md")
        XCTAssertEqual(thought.hit.anchor, note.anchor)
        XCTAssertTrue(thought.passage.contains("booster"))
    }

    func testMeaningHitsExplainThemselvesWithTheirPassage() throws {
        // Plain text gets a line anchor whichever Markdown extractor other suites registered.
        try write("kennel.txt", "Boarding notes.\nThe puppy needs its rabies vaccine before the kennel stay.")
        try store.update([FileRef(relativePath: "kennel.txt")])
        embedAll()
        let hits = try store.semanticSearch("rabies vaccine", limit: 6)
        let hit = try XCTUnwrap(hits.first { $0.hit.file.relativePath == "kennel.txt" && $0.hit.anchor != nil })
        XCTAssertEqual(hit.hit.anchor, FileAnchor(kind: .line, value: "2"), "opens at the passage's best line")
        XCTAssertTrue(hit.hit.snippet.contains("«rabies»") && hit.hit.snippet.contains("«vaccine»"), hit.hit.snippet)
        XCTAssertTrue(hit.passage.contains("kennel stay"))
        let fileHit = try store.search("rabies vaccine", limit: 5).first { $0.file.relativePath == "kennel.txt" }
        XCTAssertEqual(fileHit?.anchor, hit.hit.anchor, "a file-level hit opens at its passage")
        XCTAssertGreaterThan(hit.relevance, 0)
        XCTAssertEqual(hit.model, "fake")
        let unified = try store.unifiedSearch(UnifiedSearchQuery(raw: "glow brightness bulbs"), includeSemantic: true)
        let lamp = try XCTUnwrap(unified.results.first { $0.file.relativePath == "lamp.md" })
        XCTAssertTrue(lamp.hits.contains { $0.snippet.contains("glow") })
    }

    func testMeaningOutranksPartialKeywordMatches() throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("dog.md"))
        try write("pet-notes.md", "Biscuit is due at the vet: rabies vaccine for the puppy in March.")
        try write("misc.md", "Clinic appointment on Tuesday: bring the parking ticket.")
        try store.update([FileRef(relativePath: "pet-notes.md"), FileRef(relativePath: "misc.md"), FileRef(relativePath: "dog.md")])
        embedAll()
        // Lexically only misc.md matches (clinic, appointment); by meaning pet-notes answers.
        let query = "dog clinic appointment"
        XCTAssertEqual(try store.search(query, inFolder: nil, includeSemantic: false).first?.file.relativePath, "misc.md")
        XCTAssertEqual(try store.search(query, limit: 3).first?.file.relativePath, "pet-notes.md")
        XCTAssertEqual(try store.unifiedSearch(UnifiedSearchQuery(raw: query), includeSemantic: true).results.first?.file.relativePath, "pet-notes.md")
        // A full keyword match on a name still leads.
        XCTAssertEqual(try store.unifiedSearch(UnifiedSearchQuery(raw: "terms"), includeSemantic: true).results.first?.file.relativePath, "terms.md")
    }

    func testAnyTermFallbackSkipsQuestionWords() {
        let plan = IndexStore.plan("what did Maya say about flicker")
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan.last, .fts(#""Maya" OR "flicker"*"#))
        XCTAssertEqual(IndexStore.plan("what about").last, .fts(#""what" OR "about"*"#), "all stopwords: kept")
        XCTAssertEqual(IndexStore.plan("the lamp ").last, .fts(#""lamp""#))
    }

    func testReadOnlyReaderSeesVectorsTheWriterAdds() throws {
        embedAll()
        let reader = try IndexStore(vault: Vault(root: root), readOnly: true)
        reader.embedding.embedder.fake = Self.fake
        XCTAssertEqual(try reader.semanticSearch("supplier contract", limit: 1).first?.hit.file.relativePath, "terms.md")
        try write("vendor.md", "Vendor agreement: the manufacturer signs the supplier contract.")
        try store.update([FileRef(relativePath: "vendor.md")])
        embedAll()
        _ = try reader.unifiedSearch(UnifiedSearchQuery(raw: "x"))   // observes the new commit
        XCTAssertTrue(try reader.semanticSearch("supplier contract", limit: 5).contains { $0.hit.file.relativePath == "vendor.md" })
    }

    func testCancelledStoreStopsEmbedding() {
        store.cancelBackgroundWork()
        XCTAssertEqual(store.embedPending(), 0)
    }

    func testNoModelMeansKeywordOnlyAndNoSimilarity() throws {
        store.embedding.embedder.fake = { _ in nil }
        XCTAssertEqual(store.embedPending(), 0)
        XCTAssertTrue(try store.semanticSearch("price", limit: 5).isEmpty)
        XCTAssertTrue(try store.similarFiles(to: FileRef(relativePath: "lamp.md"), limit: 5).isEmpty)
        XCTAssertTrue(try store.similarPairs(minScore: 0.5, perFile: 3).isEmpty)
        XCTAssertEqual(try store.search("price", limit: 5).map(\.file.relativePath), ["money.md"])
    }

    // MARK: Similar files

    func testSimilarFilesFindsNeighboursByMeaning() throws {
        embedAll()
        let similar = try store.similarFiles(to: FileRef(relativePath: "lamp.md"), limit: 3)
        XCTAssertEqual(similar.first?.file.relativePath, "bulb.md")
        XCTAssertFalse(similar.contains { $0.file.relativePath == "lamp.md" }, "not itself")
        XCTAssertFalse(similar.contains { $0.file.relativePath == "dog.md" }, "below the floor")
        let first = try XCTUnwrap(similar.first)
        XCTAssertGreaterThan(first.score, 0.8)
        XCTAssertLessThanOrEqual(first.score, 1)
        XCTAssertTrue(first.passage?.contains("filament") == true, first.passage ?? "nil")
        // Memoized: a second call is the same answer.
        XCTAssertEqual(try store.similarFiles(to: FileRef(relativePath: "lamp.md"), limit: 3).map(\.file), similar.map(\.file))
        XCTAssertTrue(try store.similarFiles(to: FileRef(relativePath: "missing.md"), limit: 3).isEmpty)
    }

    func testSimilarPairsAreDedupedAndOrdered() throws {
        embedAll()
        let pairs = try store.similarPairs(minScore: 0.8, perFile: 2)
        XCTAssertEqual(pairs.first.map { [$0.a, $0.b] }, ["bulb.md", "lamp.md"])
        XCTAssertTrue(pairs.allSatisfy { $0.a < $0.b && $0.score >= 0.8 && $0.score <= 1 })
        XCTAssertEqual(Set(pairs.map { $0.a + "|" + $0.b }).count, pairs.count)
        XCTAssertFalse(pairs.contains { $0.a == "dog.md" || $0.b == "dog.md" })
        XCTAssertEqual(try store.similarPairs(minScore: 0.8, perFile: 0).count, 0)
    }

    func testSimilarFilesFollowEdits() throws {
        embedAll()
        XCTAssertEqual(try store.similarFiles(to: FileRef(relativePath: "money.md"), limit: 1).first?.file.relativePath, nil)
        try write("cheap.md", "Cheap: pay less, the cost in dollars drops.")
        try store.update([FileRef(relativePath: "cheap.md")])
        embedAll()
        // File vectors rebuild at most every 5 seconds; a new generation is picked up by age.
        store.embedding.lock.withLock { store.embedding.similar.removeAll() }
        for (index, _) in store.semanticIndexes() { index.fileVectors = nil }
        XCTAssertEqual(try store.similarFiles(to: FileRef(relativePath: "money.md"), limit: 1).first?.file.relativePath, "cheap.md")
    }

    func testProfilesWordQueriesAndDocumentsPerModel() {
        let qwen = EmbeddingProfile.ollama("qwen3-embedding:0.6b")!
        XCTAssertTrue(qwen.query("lamp").hasSuffix("Query: lamp"))
        XCTAssertEqual(qwen.memoryDimensions, 512)
        XCTAssertEqual(EmbeddingProfile.ollama("nomic-embed-text:latest")!.query("x"), "search_query: x")
        XCTAssertEqual(EmbeddingProfile.ollama("nomic-embed-text")!.document(header: "H", body: "B"), "search_document: H\nB")
        XCTAssertEqual(EmbeddingProfile.ollama("embeddinggemma")!.document(header: "", body: "B"), "title: none | text: B")
        XCTAssertNil(EmbeddingProfile.ollama("gemma3:4b"), "not an embedding model")
        XCTAssertNotNil(EmbeddingProfile.ollama("someone/custom-embed:latest"))
        XCTAssertLessThan(qwen.rank, EmbeddingProfile.ollama("nomic-embed-text")!.rank)
        XCTAssertEqual(qwen.relevance(qwen.floor), 0)
        XCTAssertEqual(qwen.relevance(1), 1)
        var embedder = Embedder()
        embedder.preferred = "none"
        XCTAssertNil(embedder.resolve())
        embedder.fake = Self.fake
        XCTAssertEqual(embedder.resolve()?.id, "fake")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func add(_ k: Int) { lock.withLock { n += k } }
}
