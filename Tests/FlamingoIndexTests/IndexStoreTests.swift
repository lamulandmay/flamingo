import XCTest
@testable import FlamingoIndex
import FlamingoCore
import FlamingoExtract

/// `.fltest` files: `# Title` sets the title, `== slide 7: Pricing` starts a section,
/// everything else is text. Registered ahead of the real extractors so these tests don't
/// depend on plan 04's progress.
struct FixtureExtractor: Extractor {
    static let extensions: Set<String> = ["fltest"]
    init() {}
    func extract(_ url: URL) throws -> Extracted {
        let raw = try String(contentsOf: url, encoding: .utf8)
        var title: String?
        var sections: [Section] = []
        var loose: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("# ") { title = String(line.dropFirst(2)); continue }
            if line.hasPrefix("== ") {
                let spec = line.dropFirst(3)
                let head = spec.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                let kv = head[0].split(separator: " ", maxSplits: 1).map(String.init)
                sections.append(Section(anchor: FileAnchor(kind: FileAnchor.Kind(rawValue: kv[0])!, value: kv[1]),
                                        title: head.count > 1 ? head[1] : nil, text: ""))
                continue
            }
            if sections.isEmpty { loose.append(line) } else { sections[sections.count - 1].text += line + "\n" }
        }
        if sections.isEmpty { return Extracted(text: loose.joined(separator: "\n"), title: title) }
        return Extracted(sections: sections, title: title)
    }
}

class IndexTestCase: XCTestCase {
    var root: URL!
    var vault: Vault!
    var store: IndexStore!

    override class func setUp() {
        super.setUp()
        if !Extract.extractors.contains(where: { $0 == FixtureExtractor.self }) {
            Extract.extractors.insert(FixtureExtractor.self, at: 0)
        }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("flamingo-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vault = Vault(root: root)
        store = try IndexStore(vault: vault)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func write(_ path: String, _ text: String) throws -> FileRef {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return FileRef(relativePath: path)
    }

    func ref(_ p: String) -> FileRef { FileRef(relativePath: p) }

    let deck = """
    # Q3 Business Review
    == slide 1: Agenda
    Where we are and where we go.
    == slide 7: Pricing
    Raise café prices by 8% in Q3. Gross margin improves.
    == slide 9: Risks
    Churn may rise if the margin gross story is unclear.
    """
}

final class IndexStoreTests: IndexTestCase {
    func testSearchOpensAtBestSection() throws {
        try write("decks/q3.fltest", deck)
        try store.reindex()
        let hits = try store.search("prices")
        XCTAssertEqual(hits.first?.file, ref("decks/q3.fltest"))
        XCTAssertEqual(hits.first?.anchor, FileAnchor(kind: .slide, value: "7"))
        XCTAssertTrue(hits.first?.snippet.contains("«prices»") == true, hits.first?.snippet ?? "")
    }

    func testPrefixPhraseAndDiacritics() throws {
        try write("decks/q3.fltest", deck)
        try write("other.fltest", "margin and also gross")
        try store.reindex()
        XCTAssertEqual(try store.search("pric").first?.anchor?.value, "7")
        XCTAssertEqual(try store.search("cafe").first?.file, ref("decks/q3.fltest"))
        XCTAssertEqual(try store.searchSections("\"gross margin\"").map(\.anchor?.value), ["7"])
        XCTAssertEqual(Set(try store.search("margin gross").map(\.file.relativePath)), ["decks/q3.fltest", "other.fltest"])
        XCTAssertEqual(try store.search("pric ").count, 0, "a trailing space ends the word")
        XCTAssertEqual(try store.search("zzzz").count, 0)
        XCTAssertEqual(try store.search("  \"  * ( ").count, 0)
    }

    func testTitleMatchStillOpensAtSection() throws {
        try write("decks/q3.fltest", deck)
        try store.reindex()
        let hit = try XCTUnwrap(try store.search("pricing").first)
        XCTAssertEqual(hit.anchor?.value, "7", "slide title match beats the file-level row")
        let review = try XCTUnwrap(try store.search("business review").first)
        XCTAssertEqual(review.file, ref("decks/q3.fltest"))
    }

    func testFileNameIsSearchable() throws {
        try write("finance/q3-model.fltest", "")
        try store.reindex()
        XCTAssertEqual(try store.search("q3 model").first?.file, ref("finance/q3-model.fltest"))
        XCTAssertNil(try store.search("q3 model").first?.anchor)
    }

    func testAnyTermFallback() throws {
        try write("decks/q3.fltest", deck)
        try store.reindex()
        XCTAssertEqual(try store.search("what did we decide about pricing").first?.anchor?.value, "7")
    }

    func testUnchangedFilesAreSkipped() throws {
        try write("a.fltest", "alpha")
        try write("b.fltest", "beta")
        try store.reindex()
        XCTAssertEqual(store.lastReindex?.extracted, 2)
        try store.reindex()
        XCTAssertEqual(store.lastReindex?.extracted, 0)
        try write("b.fltest", "beta gamma")
        try store.reindex()
        XCTAssertEqual(store.lastReindex?.extracted, 1)
        XCTAssertEqual(try store.search("gamma").first?.file, ref("b.fltest"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.fltest"))
        try store.reindex()
        XCTAssertEqual(store.lastReindex?.removed, 1)
        XCTAssertEqual(try store.search("alpha").count, 0)
        XCTAssertEqual(try store.stats().files, 1)
    }

    func testIndexSurvivesReopen() throws {
        try write("a.fltest", "persistent words")
        try store.reindex()
        store = nil
        store = try IndexStore(vault: vault)
        XCTAssertEqual(try store.search("persistent").count, 1)
        try store.reindex()
        XCTAssertEqual(store.lastReindex?.extracted, 0)
    }

    func testUpdateAddsChangesAndRemoves() throws {
        try store.reindex()
        let r = try write("new.fltest", "fresh content")
        try store.update([r])
        XCTAssertEqual(try store.search("fresh").first?.file, r)
        try write("new.fltest", "stale content replaced")
        try store.update([r])
        XCTAssertEqual(try store.search("fresh").count, 0)
        XCTAssertEqual(try store.search("replaced").count, 1)
        try FileManager.default.removeItem(at: root.appendingPathComponent("new.fltest"))
        try store.update([r])
        XCTAssertEqual(try store.search("replaced").count, 0)
        XCTAssertEqual(try store.stats().files, 0)
    }

    func testUpdateDirectory() throws {
        try write("dir/a.fltest", "apple")
        try write("dir/sub/b.fltest", "banana")
        try write("dir/.hidden.fltest", "cherry")
        try store.update([ref("dir")])
        XCTAssertEqual(try store.indexedFiles().map(\.relativePath), ["dir/a.fltest", "dir/sub/b.fltest"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("dir/sub"))
        try store.update([ref("dir")])
        XCTAssertEqual(try store.indexedFiles().map(\.relativePath), ["dir/a.fltest"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("dir"))
        try store.update([ref("dir")])
        XCTAssertEqual(try store.indexedFiles(), [])
    }

    func testUpdateIgnoresStateAndHiddenPaths() throws {
        try write(".git/x.fltest", "nope")
        try store.update([ref(".git/x.fltest"), ref(".flamingo/index.sqlite")])
        XCTAssertEqual(try store.stats().files, 0)
    }

    func testRemove() throws {
        try write("a/x.fltest", "one")
        try write("a/y.fltest", "two")
        try write("b.fltest", "three")
        try store.reindex()
        try store.remove([ref("a")])
        XCTAssertEqual(try store.indexedFiles(), [ref("b.fltest")])
    }

    func testSectionsAndText() throws {
        let r = try write("decks/q3.fltest", deck)
        try write("plain.fltest", "just some text")
        try store.reindex()
        let sections = try store.sections(of: r)
        XCTAssertEqual(sections.map(\.anchor.value), ["1", "7", "9"])
        XCTAssertEqual(sections[1].title, "Pricing")
        XCTAssertTrue(try store.text(of: r)?.contains("Raise café prices") == true)
        XCTAssertEqual(try store.sections(of: ref("plain.fltest")), [])
        XCTAssertEqual(try store.text(of: ref("plain.fltest")), "just some text")
        XCTAssertNil(try store.text(of: ref("nope.fltest")))
    }

    func testRecentAndFuzzy() throws {
        try write("finance/q3-model.fltest", "")
        try write("finance/quarterly-memo.fltest", "")
        try write("decks/q3.fltest", "")
        try write("archive/mod/q/x.fltest", "")
        try store.reindex()
        XCTAssertEqual(try store.files(matching: "q3mod").first, ref("finance/q3-model.fltest"))
        XCTAssertEqual(try store.files(matching: "q3").first, ref("decks/q3.fltest"))
        XCTAssertTrue(try store.files(matching: "finmemo").contains(ref("finance/quarterly-memo.fltest")))
        XCTAssertEqual(try store.files(matching: "zzz"), [])
        XCTAssertEqual(try store.recent(limit: 10).count, 4)
        XCTAssertEqual(try store.files(matching: "").count, 4)
    }

    func testCorruptIndexIsRebuilt() throws {
        try write("a.fltest", "words")
        try store.reindex()
        store = nil
        let db = vault.stateDir.appendingPathComponent("index.sqlite")
        for s in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db.path + s) }
        try Data("this is not a database".utf8).write(to: db)
        store = try IndexStore(vault: vault)
        try store.reindex()
        XCTAssertEqual(try store.search("words").count, 1)
    }

    func testSearchWhileReindexing() throws {
        for i in 0..<300 { try write("f\(i).fltest", "common word number\(i)") }
        let done = expectation(description: "reindex")
        let s = store!
        DispatchQueue.global().async { try? s.reindex(); done.fulfill() }
        var searches = 0
        while searches < 200 { _ = try store.search("common"); searches += 1 }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(try store.search("number299").count, 1)
    }

    func testProgressReachesOne() throws {
        for i in 0..<450 { try write("p\(i).fltest", "x\(i)") }
        var values: [Double] = []
        try store.reindex { values.append($0) }
        XCTAssertEqual(values.first, 0)
        XCTAssertEqual(values.last, 1)
        XCTAssertEqual(values, values.sorted())
        XCTAssertEqual(try store.stats().files, 450)
    }
}

final class CommentIndexTests: IndexTestCase {
    func comment(_ text: String, _ anchor: FileAnchor? = nil, minutesAgo: Double = 0) -> Comment {
        Comment(timestamp: Date().addingTimeInterval(-minutesAgo * 60), anchor: anchor, text: text)
    }

    func testCommentsAreSearchable() throws {
        try write("decks/q3.fltest", deck)
        try store.reindex()
        let c = comment("Pricing contradicts [[q3-model.xlsx]]", FileAnchor(kind: .slide, value: "7"))
        try store.replaceAllComments([ref("decks/q3.fltest"): [c]])
        let hit = try XCTUnwrap(try store.search("contradicts").first)
        XCTAssertEqual(hit.commentID, c.id)
        XCTAssertEqual(hit.anchor, c.anchor)
        XCTAssertEqual(hit.file, ref("decks/q3.fltest"))
        let ch = try XCTUnwrap(try store.searchComments("contradict").first)
        XCTAssertEqual(ch.comment.id, c.id)
        XCTAssertEqual(ch.comment.text, c.text)
        XCTAssertEqual(try store.commentCounts(), [ref("decks/q3.fltest"): 1])
        XCTAssertEqual(try store.comments(on: ref("decks/q3.fltest")).map(\.id), [c.id])
    }

    func testCommentAndSectionWithSameAnchorDedupe() throws {
        try write("decks/q3.fltest", deck)
        try store.reindex()
        try store.replaceAllComments([ref("decks/q3.fltest"): [comment("prices again", FileAnchor(kind: .slide, value: "7"))]])
        let ids = try store.search("prices").map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "SearchHit ids must be unique for SwiftUI lists")
    }

    func testGraph() throws {
        try write("decks/q3.fltest", deck)
        try write("finance/q3-model.fltest", "numbers")
        try write("notes/plan.fltest", "plan")
        try store.reindex()
        try store.replaceAllComments([
            ref("decks/q3.fltest"): [
                comment("Pricing contradicts [[q3-model.fltest]]"),
                comment("Again [[q3-model]] and [[Pricing Ideas]] and [[pricing ideas|alias]]"),
                comment("Self [[q3.fltest]] is not an edge"),
            ],
            ref("gone/old.fltest"): [comment("Orphan points at [[plan.fltest#page 2]]")],
        ])
        let trail = [Graph.Edge(source: "decks/q3.fltest", target: "notes/plan.fltest", kind: .trail, weight: 2),
                     Graph.Edge(source: "decks/q3.fltest", target: "deleted.fltest", kind: .trail)]
        let g = try store.buildGraph(extraEdges: trail)

        XCTAssertEqual(g.nodes.map(\.id), ["Pricing Ideas", "decks/q3.fltest", "finance/q3-model.fltest", "gone/old.fltest", "notes/plan.fltest"])
        XCTAssertEqual(g.nodes.first { $0.id == "decks/q3.fltest" }?.commentCount, 3)
        XCTAssertEqual(g.nodes.first { $0.id == "gone/old.fltest" }?.commentCount, 1)
        let edges = g.edges.map { "\($0.source)>\($0.target):\($0.kind.rawValue):\(Int($0.weight))" }
        XCTAssertEqual(edges, [
            "decks/q3.fltest>Pricing Ideas:link:1",
            "decks/q3.fltest>finance/q3-model.fltest:link:2",
            "decks/q3.fltest>notes/plan.fltest:trail:2",
            "gone/old.fltest>notes/plan.fltest:link:1",
        ])

        let data = try Data(contentsOf: vault.stateDir.appendingPathComponent("graph.json"))
        XCTAssertEqual(try JSONDecoder().decode(Graph.self, from: data), g)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\\/"))
    }

    func testBacklinks() throws {
        try write("decks/q3.fltest", deck)
        try write("finance/q3-model.fltest", "numbers")
        try write("finance/q3.fltest", "same basename elsewhere")
        try store.reindex()
        let older = comment("See [[q3-model.fltest]]", FileAnchor(kind: .slide, value: "7"), minutesAgo: 10)
        let newer = comment("And [[Q3-MODEL]] again", minutesAgo: 1)
        let unrelated = comment("Links [[q3.fltest]] only")
        let sibling = comment("Sibling [[q3.fltest]]")
        try store.replaceAllComments([ref("decks/q3.fltest"): [older, newer, unrelated],
                                      ref("finance/q3-model.fltest"): [sibling]])
        let back = try store.backlinks(to: ref("finance/q3-model.fltest"))
        XCTAssertEqual(back.map(\.0), [ref("decks/q3.fltest"), ref("decks/q3.fltest")])
        XCTAssertEqual(back.map(\.1.id), [newer.id, older.id])
        // [[q3.fltest]] resolves within the linking file's own folder first.
        XCTAssertEqual(try store.backlinks(to: ref("finance/q3.fltest")).map(\.1.id), [sibling.id])
        XCTAssertTrue(try store.backlinks(to: ref("decks/q3.fltest")).isEmpty)
    }

    func testSidecarsIngestedOnReindexAndUpdate() throws {
        let target = try write("decks/q3.fltest", deck)
        let sidecars = SidecarStore(vault: vault)
        let c = comment("Written through SidecarStore [[q3.fltest]]")
        try sidecars.append(c, to: target)
        guard (try? sidecars.comments(for: target))?.isEmpty == false else {
            throw XCTSkip("SidecarStore (plan 02) does not round-trip comments yet")
        }
        // Sidecars don't store ids; they're derived from the line, so compare with a fresh parse.
        try store.reindex()
        let parsed = try sidecars.comments(for: target)
        XCTAssertEqual(try store.searchComments("SidecarStore").first?.comment.text, c.text)
        XCTAssertEqual(try store.comments(on: target).map(\.id), parsed.map(\.id))
        try sidecars.append(comment("A second thought arrives"), to: target)
        try store.update([target])
        XCTAssertEqual(try store.searchComments("second thought").first?.comment.text, "A second thought arrives")
        XCTAssertEqual(try store.comments(on: target).map(\.id), try sidecars.comments(for: target).map(\.id))
        try FileManager.default.removeItem(at: sidecars.sidecarURL(for: target))
        try store.update([target])
        XCTAssertEqual(try store.commentCounts(), [:])
    }
}

final class RenameTests: IndexTestCase {
    func testRenameKeepsRow() throws {
        let a = try write("a.fltest", "renamed content")
        let url = vault.url(for: a)
        guard let id1 = try? FileIdentity.id(for: url), let id2 = try? FileIdentity.id(for: url), id1 == id2 else {
            throw XCTSkip("FileIdentity (plan 02) is not stable yet")
        }
        try store.reindex()
        let before = try store.stats()
        try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("b.fltest"))
        try store.update([a, ref("b.fltest")])
        XCTAssertEqual(try store.indexedFiles(), [ref("b.fltest")])
        XCTAssertEqual(try store.stats(), before)
        XCTAssertEqual(try store.search("renamed").first?.file, ref("b.fltest"))
        XCTAssertEqual(try store.search("b").first?.file, ref("b.fltest"), "the file-level row carries the new name")
    }

    func testIndexingNeverAssignsIdentity() throws {
        let a = try write("plain.fltest", "no comments here")
        try store.reindex()
        XCTAssertNil(try FileIdentity.existingID(for: vault.url(for: a)))
    }

    func testRenamedFileTakesItsSidecarAlong() throws {
        let a = try write("decks/old.fltest", "deck")
        let sidecars = SidecarStore(vault: vault)
        try sidecars.append(Comment(text: "a thought that should follow"), to: a)
        guard (try? FileIdentity.existingID(for: vault.url(for: a))) != nil,
              (try? sidecars.comments(for: a))?.isEmpty == false else {
            throw XCTSkip("SidecarStore/FileIdentity (plan 02) not ready")
        }
        try store.reindex()
        let b = ref("decks/new.fltest")
        try FileManager.default.moveItem(at: vault.url(for: a), to: vault.url(for: b))
        try store.update([a, b])
        XCTAssertEqual(try sidecars.comments(for: b).map(\.text), ["a thought that should follow"])
        XCTAssertEqual(try store.commentCounts(), [b: 1])
        XCTAssertEqual(try store.searchComments("follow").first?.file, b)
    }

    func testRenameWhileClosedHealsOnReindex() throws {
        let a = try write("old.fltest", "deck")
        let sidecars = SidecarStore(vault: vault)
        try sidecars.append(Comment(text: "still mine"), to: a)
        guard (try? FileIdentity.existingID(for: vault.url(for: a))) != nil else { throw XCTSkip("FileIdentity not ready") }
        try store.reindex()
        try FileManager.default.moveItem(at: vault.url(for: a), to: root.appendingPathComponent("new.fltest"))
        try store.reindex()
        XCTAssertEqual(try store.commentCounts(), [ref("new.fltest"): 1])
    }
}

final class FTSQueryTests: XCTestCase {
    func testBuild() {
        XCTAssertEqual(FTSQuery.build("pricing model"), "\"pricing\" \"model\"*")
        XCTAssertEqual(FTSQuery.build("pricing model "), "\"pricing\" \"model\"")
        XCTAssertEqual(FTSQuery.build("\"gross margin\" q3"), "\"gross margin\" \"q3\"*")
        XCTAssertEqual(FTSQuery.build("q3 \"gross margin\""), "\"q3\" \"gross margin\"")
        XCTAssertEqual(FTSQuery.build("\"gross mar"), "\"gross mar\"*")
        XCTAssertEqual(FTSQuery.build("a OR b", any: true), "\"a\" OR \"OR\" OR \"b\"*")
        XCTAssertEqual(FTSQuery.build("q3-model.xlsx"), "\"q3-model.xlsx\"*")
        XCTAssertNil(FTSQuery.build("  * () \"\" "))
        XCTAssertNil(FTSQuery.build(""))
    }
}

final class FuzzyMatchTests: XCTestCase {
    func testRanking() {
        let paths = ["archive/q/3/m/o/d.txt", "finance/q3-model.xlsx", "q3model-notes/readme.md", "decks/Q3Model.key"]
        let ranked = FuzzyMatch.rank("q3mod", in: paths, limit: 10)
        XCTAssertEqual(Set(ranked.prefix(2)), ["finance/q3-model.xlsx", "decks/Q3Model.key"])
        XCTAssertEqual(ranked.last, "archive/q/3/m/o/d.txt")
        XCTAssertEqual(FuzzyMatch.rank("xyz", in: paths, limit: 10), [])
    }
}

final class IndexPerformanceTests: IndexTestCase {
    /// Done means: a thousand files indexed well inside a minute, search under 20ms.
    func testThousandFiles() throws {
        let words = ["pricing", "churn", "margin", "roadmap", "hiring", "budget", "launch", "review", "risk", "forecast"]
        for i in 0..<1000 {
            let w = words[i % words.count], v = words[(i * 7) % words.count]
            let body = (1...5).map { "== page \($0): \(w) \($0)\n\(v) notes for item \(i) page \($0) about \(w) and \(v)." }
            try write("folder\(i % 20)/\(w)-\(i).fltest", "# \(w.capitalized) \(i)\n" + body.joined(separator: "\n"))
        }
        let t0 = Date()
        try store.reindex()
        let indexSeconds = Date().timeIntervalSince(t0)
        XCTAssertLessThan(indexSeconds, 60)
        XCTAssertEqual(try store.stats().files, 1000)

        var worst = 0.0
        for q in words + ["pric", "\"notes for item\"", "item 999", "margin forecast", "zzz"] {
            let t = Date()
            _ = try store.search(q)
            worst = max(worst, Date().timeIntervalSince(t))
        }
        XCTAssertLessThan(worst, 0.02, "slowest search \(worst * 1000)ms")
        let t = Date()
        _ = try store.files(matching: "pric99")
        XCTAssertLessThan(Date().timeIntervalSince(t), 0.05)
        print("indexed 1000 files in \(String(format: "%.2f", indexSeconds))s, slowest search \(String(format: "%.2f", worst * 1000))ms")
    }
}

final class LiveIndexTests: IndexTestCase {
    /// Done means: touching a file updates the index within a second.
    func testWatcherKeepsIndexFresh() throws {
        try write("seed.fltest", "seed")
        try store.reindex()
        let watcher = VaultWatcher(vault: vault)
        let s = store!
        let found = expectation(description: "indexed")
        var started = Date()
        watcher.onChange = { refs in
            try? s.update(refs)
            if (try? s.search("kumquat").isEmpty) == false { found.fulfill() }
        }
        watcher.start()
        defer { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.3)
        started = Date()
        try write("fresh.fltest", "a kumquat appears")
        wait(for: [found], timeout: 3)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 1.0, "indexed after \(elapsed)s")
    }
}
