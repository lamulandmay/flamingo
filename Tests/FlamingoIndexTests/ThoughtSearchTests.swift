import XCTest
import FlamingoCore
@testable import FlamingoIndex

/// Thoughts as search results, with the deterministic fake model of `SemanticIndexTests`.
final class ThoughtSearchTests: XCTestCase {
    var root: URL!
    var store: IndexStore!
    var notes: SidecarStore!
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { base.addingTimeInterval(30 * 86_400) }
    var inbox: FileRef { FileRef(relativePath: "_inbox/2026-10-14") }
    var web: FileRef { WebThought.ref(for: "https://vets.example.com/schedule", title: "Vaccine schedule")! }
    let folder = FileRef(relativePath: "docs")

    func at(_ minutes: Int) -> Date { base.addingTimeInterval(Double(minutes) * 60) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("thought-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        for (name, text) in [("terms.md", "The supplier agreement binds the manufacturer to the contract."),
                             ("money.md", "We will charge forty dollars; the price is final."),
                             ("lamp.md", "A lamp with a warm glow and no flicker at any brightness."),
                             ("dog.md", "The puppy sees the vet for its rabies vaccine in March."),
                             ("docs/readme.md", "Where the documents live.")] {
            try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        notes = SidecarStore(vault: Vault(root: root))
        try notes.append(Comment(timestamp: at(0), text: "Take the puppy for its rabies shot").stamped(), to: inbox)
        try notes.append(Comment(timestamp: at(1), text: "Good vet article about the vaccine schedule").stamped(), to: web,
                         frontmatter: WebThought.frontmatter(url: "https://vets.example.com/schedule", title: "Vaccine schedule"))
        try notes.append(Comment(timestamp: at(2), text: "Collect the pricing documents here").stamped(), to: folder, frontmatter: ["subject": "folder"])
        try notes.append(Comment(timestamp: at(3), anchor: nil, text: "The glow is lovely but there is flicker at low brightness").stamped(), to: FileRef(relativePath: "lamp.md"))
        try notes.append(Comment(timestamp: at(4), text: "Is the price final? See [[lamp.md]]").stamped(), to: FileRef(relativePath: "money.md"))
        try notes.append(Comment(timestamp: at(5), text: "The supplier contract is signed").stamped(), to: FileRef(relativePath: "terms.md"))
        let lampThought = try XCTUnwrap(notes.comments(for: FileRef(relativePath: "lamp.md")).first?.uid)
        try notes.appendReply(Comment(timestamp: at(6), text: "Dim the brightness at night and see",
                                      provenance: nil), toUID: lampThought, in: FileRef(relativePath: "lamp.md"))
        store = try IndexStore(vault: Vault(root: root))
        store.embedding.embedder.fake = SemanticIndexTests.fake
        try store.reindex()
        while store.embedPending() > 0 {}
    }

    override func tearDownWithError() throws { store = nil; try? FileManager.default.removeItem(at: root) }

    func testEveryKindOfFilelessThoughtIsIndexedWithItsColumns() throws {
        XCTAssertEqual(try store.stats().comments, 7)
        let all = try store.thoughts(ThoughtQuery(states: nil))
        XCTAssertEqual(all.count, 7)
        XCTAssertEqual(Set(all.filter { !$0.hasFile }.map(\.file.relativePath)), [inbox.relativePath, web.relativePath, folder.relativePath])
        let question = try XCTUnwrap(all.first { $0.comment.text.hasPrefix("Is the price final") })
        XCTAssertEqual(question.kind, .question)
        XCTAssertEqual(question.kindBy, .rules)
        XCTAssertNotNil(question.uid)
        XCTAssertTrue(all.allSatisfy { $0.state == .open && $0.origin == .human })
    }

    func testAnInboxThoughtIsFoundByKeyword() throws {
        let hits = try store.searchThoughts("rabies", includeSemantic: false)
        XCTAssertEqual(hits.first?.record.file, inbox)
        XCTAssertTrue(hits.first?.snippet.contains("«rabies»") == true, hits.first?.snippet ?? "")
        XCTAssertNil(hits.first?.relevance)
    }

    func testInboxWebAndFolderThoughtsAreFoundByMeaning() throws {
        // None of these words is in the thoughts; only the idea is shared.
        let hits = try store.searchThoughts("vet vaccine reminder")
        let files = hits.map(\.record.file)
        XCTAssertTrue(files.contains(inbox), "\(files)")
        XCTAssertTrue(files.contains(web), "\(files)")
        XCTAssertNotNil(hits.first?.relevance)
        let documents = try store.searchThoughts("price list of pricing")
        XCTAssertTrue(documents.map(\.record.file).contains(folder))
        // The file-level hybrid search no longer drops them either.
        let files2 = try store.search("vet vaccine reminder", limit: 20).map(\.file)
        XCTAssertTrue(files2.contains(inbox), "\(files2)")
        // Scoped to a folder, only what is under it.
        XCTAssertTrue(try store.searchThoughts("vet vaccine reminder", inFolder: "docs").isEmpty)
    }

    func testCommandKGetsThoughtRowsAndKeepsFileResultsClean() throws {
        let lexical = try store.unifiedSearch(UnifiedSearchQuery(raw: "rabies"), limit: 20)
        XCTAssertEqual(lexical.thoughts.first?.record.file, inbox)
        let semantic = try store.unifiedSearch(UnifiedSearchQuery(raw: "vet vaccine reminder"), limit: 20, includeSemantic: true)
        XCTAssertTrue(semantic.thoughts.map(\.record.file).contains(inbox))
        XCTAssertTrue(semantic.thoughts.map(\.record.file).contains(web))
        let listed = semantic.results.map(\.file)
        XCTAssertFalse(listed.contains(inbox) || listed.contains(web) || listed.contains(folder), "a thought with no file is not a file result")
        XCTAssertTrue(listed.contains(FileRef(relativePath: "dog.md")))
        // File filters are about files.
        let typed = try store.unifiedSearch(UnifiedSearchQuery(raw: "type:md rabies"), limit: 20)
        XCTAssertTrue(typed.thoughts.isEmpty)
    }

    func testThreadContextIsAttachedToReplies() throws {
        let hits = try store.searchThoughts("Dim the brightness", includeSemantic: false)
        let reply = try XCTUnwrap(hits.first { $0.record.comment.text.hasPrefix("Dim the brightness") })
        XCTAssertEqual(reply.parentLine, "The glow is lovely but there is flicker at low brightness")
        XCTAssertNotNil(reply.record.parent)
        let root = try XCTUnwrap(try store.thoughts(ThoughtQuery(states: nil, limit: 50)).first { $0.comment.text.hasPrefix("The glow") })
        XCTAssertEqual(root.replies, 1)
        let thread = try store.thread(rootUID: try XCTUnwrap(root.uid), in: FileRef(relativePath: "lamp.md"))
        XCTAssertEqual(thread.map { Comment.firstLine($0.comment) }, ["The glow is lovely but there is flicker at low brightness", "Dim the brightness at night and see"])
    }

    func testEchoShowsRelatedEarlierThoughtsAndNothingForUnrelatedDrafts() throws {
        let related = store.similarThoughts(to: "my puppy needs a vaccine from the vet", wait: 5)
        XCTAssertTrue(related.map(\.record.file).contains(inbox), "\(related.map(\.record.file))")
        XCTAssertLessThanOrEqual(related.count, 3)
        XCTAssertTrue(related.allSatisfy { ($0.relevance ?? 0) >= 0.45 })
        XCTAssertTrue(store.similarThoughts(to: "quarterly hiring plan for the engineering team", wait: 5).isEmpty)
        let mine = try XCTUnwrap(related.first?.record.uid)
        XCTAssertFalse(store.similarThoughts(to: "my puppy needs a vaccine from the vet", excludingUID: mine, wait: 5).contains { $0.record.uid == mine })
        XCTAssertTrue(store.similarThoughts(to: "my puppy needs a vaccine from the vet", minRelevance: 5, wait: 5).isEmpty)
        XCTAssertEqual(store.similarThoughts(to: "my puppy needs a vaccine from the vet", limit: 1, wait: 5).count, 1)
    }

    func testResurfacePrefersRelatedUnseenThoughtsAndIsNotRandom() throws {
        let lamp = FileRef(relativePath: "lamp.md"), money = FileRef(relativePath: "money.md")
        let first = try XCTUnwrap(try store.resurfaceableThought(near: [lamp], olderThan: 86_400, now: now, seen: []))
        XCTAssertEqual(first.0, lamp, "a thought on the open file")
        for _ in 0..<5 {
            XCTAssertEqual(try store.resurfaceableThought(near: [lamp], olderThan: 86_400, now: now, seen: [])?.1.id, first.1.id)
        }
        // Seen once, the thought that links to the open file comes next.
        let second = try XCTUnwrap(try store.resurfaceableThought(near: [lamp], olderThan: 86_400, now: now, seen: [first.1.id.uuidString]))
        XCTAssertEqual(second.0, money)
        let both: Set<String> = [first.1.id.uuidString, second.1.id.uuidString]
        let lamps = try store.thoughts(ThoughtQuery(states: nil, limit: 50)).filter { $0.file == lamp }
        XCTAssertNil(try store.resurfaceableThought(near: [lamp], olderThan: 86_400, now: now, seen: both.union(lamps.compactMap(\.uid)).union(lamps.map { $0.comment.id.uuidString })))
        // Nothing bears on an unrelated file, so nothing comes back (the old pick was random).
        XCTAssertNil(try store.resurfaceableThought(near: [FileRef(relativePath: "docs/readme.md")], olderThan: 86_400, now: now, seen: []))
        // Too recent, or no files open.
        XCTAssertNil(try store.resurfaceableThought(near: [lamp], olderThan: 90 * 86_400, now: now, seen: []))
        XCTAssertNil(try store.resurfaceableThought(near: [], olderThan: 0, now: now, seen: []))
        // Done thoughts do not come back.
        _ = try notes.update(uid: try XCTUnwrap(first.1.uid ?? lamps.first?.uid), in: lamp) { $0.meta?.state = .done }
        try store.update([lamp])
        let third = try store.resurfaceableThought(near: [lamp], olderThan: 86_400, now: now, seen: [])
        XCTAssertNotEqual(third?.1.id, first.1.id)
    }

    func testTriageQueries() throws {
        let money = FileRef(relativePath: "money.md")
        let uid = try XCTUnwrap(try notes.comments(for: money).first?.uid)
        _ = try notes.update(uid: uid, in: money) { $0.meta?.due = "2026-10-20"; $0.meta?.kind = .todo; $0.meta?.kindBy = .model }
        let lamp = FileRef(relativePath: "lamp.md")
        let lampUID = try XCTUnwrap(try notes.comments(for: lamp).first?.uid)
        _ = try notes.update(uid: lampUID, in: lamp) { $0.meta?.state = .snoozed; $0.meta?.snoozeUntil = "2026-11-01 09:00" }
        try store.reloadComments()

        XCTAssertEqual(try store.thoughts(ThoughtQuery()).count, 6, "open only: the snoozed one is out")
        XCTAssertEqual(try store.thoughts(ThoughtQuery(states: [.snoozed])).map(\.uid), [lampUID])
        let ended = Date(timeIntervalSince1970: ThoughtDates.parse("2026-11-02")!.date.timeIntervalSince1970)
        var q = ThoughtQuery(); q.snoozeEndedBy = ended
        XCTAssertEqual(try store.thoughts(q).count, 7, "a snooze that has ended brings it back")
        q.snoozeEndedBy = ThoughtDates.parse("2026-10-30")!.date
        XCTAssertEqual(try store.thoughts(q).count, 6)
        XCTAssertEqual(try store.thoughts(ThoughtQuery(kinds: [.todo])).map(\.uid).contains(uid), true)
        var due = ThoughtQuery(); due.requiresDue = true; due.order = .due
        let withDue = try store.thoughts(due)
        XCTAssertEqual(withDue.first?.uid, uid)
        XCTAssertEqual(withDue.first?.kindBy, .model)
        due = ThoughtQuery(); due.dueBefore = ThoughtDates.parse("2026-10-19")!.date
        XCTAssertTrue(try store.thoughts(due).isEmpty)
        due.dueBefore = ThoughtDates.parse("2026-10-21")!.date
        XCTAssertEqual(try store.thoughts(due).count, 1)
        var virtualOff = ThoughtQuery(states: nil); virtualOff.includeVirtual = false
        XCTAssertEqual(try store.thoughts(virtualOff).count, 4)
        var one = ThoughtQuery(states: nil); one.uid = uid
        XCTAssertEqual(try store.thoughts(one).count, 1)
        var replies = ThoughtQuery(states: nil); replies.isReply = true
        XCTAssertEqual(try store.thoughts(replies).count, 1)
        var inFolder = ThoughtQuery(states: nil); inFolder.folder = "_inbox"
        XCTAssertEqual(try store.thoughts(inFolder).map(\.file), [inbox])
        XCTAssertEqual(try store.thoughts(ThoughtQuery(states: nil, order: .oldest, limit: 2)).count, 2)
    }

    func testThoughtDegreeCountsFilesJoinedByThoughtLinks() throws {
        let degree = try store.thoughtDegree(of: ["money.md", "lamp.md", "dog.md", "nope.md"])
        XCTAssertEqual(degree, ["money.md": 1, "lamp.md": 1, "dog.md": 0, "nope.md": 0])
    }

    func testGraphCountsFolderThoughtsAndTreatsAILinksAsSuggestions() throws {
        let terms = FileRef(relativePath: "terms.md")
        let uid = try XCTUnwrap(try notes.comments(for: terms).first?.uid)
        try notes.appendReply(Comment(timestamp: at(7), text: "See [[dog.md]]", provenance: CommentProvenance(origin: .ai, model: "m")), toUID: uid, in: terms)
        try notes.append(Comment(timestamp: at(8), text: "Compare with [[lamp.md]]").stamped(), to: folder, frontmatter: ["subject": "folder"])
        try store.reloadComments()
        let graph = try store.buildGraph()
        XCTAssertEqual(graph.nodes.first { $0.id == "docs/" }?.commentCount, 2, "folder thoughts count on the folder node")
        XCTAssertNil(graph.nodes.first { $0.id == "docs" }, "no stray file node for the folder note")
        XCTAssertTrue(graph.edges.contains { $0.source == "docs/" && $0.target == "lamp.md" && $0.kind == .link })
        XCTAssertTrue(graph.edges.contains { $0.source == "terms.md" && $0.target == "dog.md" && $0.kind == .related }, "an AI reply's link is a suggestion")
        XCTAssertFalse(graph.edges.contains { $0.source == "terms.md" && $0.target == "dog.md" && $0.kind == .link })
        XCTAssertTrue(graph.edges.contains { $0.source == "money.md" && $0.target == "lamp.md" && $0.kind == .link })
    }

    func testThoughtEvalKeysAndTheEvalHarness() throws {
        let key = SemanticEval.thoughtKey(path: "lamp.md", timestamp: at(3))
        XCTAssertEqual(key, "thought:lamp.md|" + SidecarFormat.string(fromTimestamp: at(3)))
        let cases: [SemanticEval.Case] = [
            .init(query: "flicker at low brightness", relevant: [key], kind: "para"),
            .init(query: "my puppy needs a vaccine from the vet", relevant: [SemanticEval.thoughtKey(path: inbox.relativePath, timestamp: at(0))], kind: "echo-related"),
            .init(query: "quarterly hiring plan for the engineering team", relevant: [], kind: "echo-unrelated"),
        ]
        let report = try ThoughtEval.run(cases, on: store)
        XCTAssertEqual(report.search?.overall.recall, 1)
        XCTAssertEqual(report.echoRelatedTop2, 1)
        XCTAssertEqual(report.echoUnrelatedSilent, 1)
        XCTAssertTrue(report.text.contains("echo:"))
        let all = try JSONDecoder().decode([SemanticEval.Case].self, from: Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../fixtures/thought-cases.json")))
        XCTAssertGreaterThanOrEqual(all.filter { !$0.kind.hasPrefix("echo") }.count, 25)
        XCTAssertEqual(all.filter { $0.kind == "echo-related" }.count, 10)
        XCTAssertEqual(all.filter { $0.kind == "echo-unrelated" }.count, 10)
        XCTAssertTrue(all.contains { $0.kind == "zh" })
    }
}

private extension Comment {
    static func firstLine(_ c: Comment) -> String { c.firstLine }
}
