import XCTest
import FlamingoCore
import FlamingoTrail
@testable import FlamingoIndex
@testable import FlamingoThoughts

final class BriefingSnapshotTests: ThoughtsTestCase {
    var index: IndexStore!
    var trail: TrailStore!
    let now = at("2026-10-17 08:30")

    override func setUpWithError() throws {
        try super.setUpWithError()
        index = try IndexStore(vault: vault)
        trail = TrailStore(vault: vault)
        trail.flushDelay = 3600
        // The files were last saved long before any thought in these tests.
        for path in ["decks/q3-board-review.pptx", "finance/q3-model.xlsx", "docs/pricing-memo.docx"] {
            try FileManager.default.setAttributes([.modificationDate: at("2026-10-01 09:00")], ofItemAtPath: root.appendingPathComponent(path).path)
        }
    }

    func builder() -> BriefingBuilder {
        var b = BriefingBuilder(vault: vault, index: index, trail: trail)
        b.calendar = testCalendar
        return b
    }

    @discardableResult
    func think(_ text: String, on file: FileRef = ThoughtsTestCase.deck, anchor: FileAnchor? = nil, at date: Date, uid: String,
               meta: ThoughtMeta? = nil, origin: CommentProvenance.Origin = .human) throws -> Comment {
        var m = meta ?? ThoughtMeta(); m.uid = uid
        try store.append(Comment(timestamp: date, anchor: anchor, text: text, provenance: CommentProvenance(origin: origin), meta: m), to: file)
        return try XCTUnwrap(store.comment(uid: uid, in: file))
    }

    func build(history: BriefingHistory? = nil, drafts: [String] = []) throws -> BriefingSnapshot {
        try index.reindex()
        return try builder().build(now: now, history: history ?? BriefingHistory(vault: vault), recoveredDrafts: drafts)
    }

    // MARK: The whole thing

    func testASnapshotHasEverythingTheBriefingShows() throws {
        var overdue = ThoughtMeta(); overdue.due = "2026-10-15"
        try think("Name the two retail buyers", at: at("2026-10-14 10:00"), uid: "t1", meta: overdue)
        try think("Maybe a darker finish", at: at("2026-10-15 10:00"), uid: "t2")
        var done = ThoughtMeta(); done.state = .done
        try think("Send the deck", at: at("2026-10-13 10:00"), uid: "t3", meta: done)
        var asleep = ThoughtMeta(); asleep.state = .snoozed; asleep.snoozeUntil = "2026-10-17 06:00"
        try think("Fix the footnote on slide 3", at: at("2026-10-12 10:00"), uid: "t4", meta: asleep)
        var stillAsleep = ThoughtMeta(); stillAsleep.state = .snoozed; stillAsleep.snoozeUntil = "2026-10-18 09:00"
        try think("Update the supplier list", at: at("2026-10-12 11:00"), uid: "t5", meta: stillAsleep)

        let intent = try think("review conflict between this and [[q3-model.xlsx]]", anchor: FileAnchor(kind: .slide, value: "7"), at: at("2026-10-16 18:40"), uid: "t6",
                               meta: ThoughtMeta(kind: .intent, kindBy: .model, intent: ThoughtIntent(action: "review-conflict", objects: ["decks/q3-board-review.pptx#slide 7", "finance/q3-model.xlsx"])))
        var work = ThoughtMeta(); work.work = "work/2026-10-17/arc.md"
        _ = intent
        try store.appendReply(Comment(timestamp: at("2026-10-17 02:14"), anchor: intent.anchor, text: "Conflict. Slide 7 says $249.",
                                      provenance: CommentProvenance(origin: .ai, model: "m"), meta: work), toUID: "t6", in: Self.deck)

        let memo = WorkMemo(thought: "t6", on: "decks/q3-board-review.pptx#slide 7", recipe: "review-conflict", verdict: "conflict",
                            sources: ["decks/q3-board-review.pptx#slide 7 · 2026-10-13 14:02"], model: "fake", created: "2026-10-17 02:14",
                            title: "Arc price: deck $249, model $229", body: "Slide 7 says $249; the model says $229.\n\n## Next step\nFix it.")
        try memo.write(in: vault)
        let seen = WorkMemo(thought: "t6", on: "x", recipe: "summarize", sources: [], model: "fake", created: "2026-10-16 02:14", title: "Old", body: "Old news.")
        let seenPath = try seen.write(in: vault)
        try store.append(Comment(timestamp: at("2026-10-16 22:00"), text: "Call the printer", provenance: CommentProvenance(origin: .human), meta: ThoughtMeta(uid: "t7")),
                         to: FileRef(relativePath: "_inbox/2026-10-16"))

        let history = BriefingHistory(vault: vault)
        history.markMemoSeen(seenPath)
        let snapshot = try build(history: history, drafts: ["half a thought"])

        XCTAssertEqual(snapshot.day, "2026-10-17")
        XCTAssertEqual(snapshot.memos.map(\.path), ["work/2026-10-17/arc-price-deck-249-model-229.md"], "the seen memo is not shown")
        XCTAssertEqual(snapshot.memos.first?.tldr, "Slide 7 says $249; the model says $229.")
        XCTAssertEqual(snapshot.memos.first?.thought?.uid, "t6")

        let uids = snapshot.address.map { $0.record.uid ?? "" }
        XCTAssertEqual(uids.first, "t1", "overdue is pinned first")
        XCTAssertTrue(snapshot.address.first?.pinned ?? false)
        XCTAssertTrue(uids.contains("t4"), "its snooze ended")
        XCTAssertFalse(uids.contains("t5"), "still asleep")
        XCTAssertFalse(uids.contains("t3"), "done")
        XCTAssertFalse(uids.contains("t2"), "an idea nothing happened around")
        XCTAssertTrue(uids.contains("t6"))
        let t6 = try XCTUnwrap(snapshot.address.first { $0.record.uid == "t6" })
        XCTAssertEqual(t6.reason, .awaiting, "a memo and a reply wait for you")
        XCTAssertEqual(t6.terms.awaiting, 1)
        XCTAssertEqual(t6.terms.kind, 1.0, "an intent with a memo ready")
        XCTAssertFalse(uids.contains("t7"), "the inbox capture is listed below, not up here as a root of a file")
        XCTAssertFalse(snapshot.address.contains { $0.record.origin == .ai })

        XCTAssertEqual(snapshot.looseCaptures.map(\.uid), ["t7"])
        XCTAssertEqual(snapshot.recoveredDrafts, ["half a thought"])
        XCTAssertFalse(snapshot.isEmpty)
        XCTAssertTrue(snapshot.summary.hasPrefix("memos=1 address="), snapshot.summary)
    }

    func testWhatHasBeenSeenAndSkippedChangesTheRanking() throws {
        try think("Name the two retail buyers", at: at("2026-10-14 10:00"), uid: "ta")
        try think("Send the deck to legal", at: at("2026-10-14 10:00"), uid: "tb")
        let plain = try build()
        let order = plain.address.map { $0.record.uid ?? "" }
        XCTAssertEqual(Set(order), ["ta", "tb"])
        let last = try XCTUnwrap(order.last), first = try XCTUnwrap(order.first)

        let history = BriefingHistory(vault: vault)
        history.recordShown([first], day: "2026-10-15"); history.recordShown([first], day: "2026-10-16")
        let skipped = try builder().build(now: now, history: history)
        XCTAssertEqual(skipped.address.first { $0.record.uid == first }?.terms.skips, 2)
        XCTAssertGreaterThan(plain.address.first { $0.record.uid == first }!.score, skipped.address.first { $0.record.uid == first }!.score)
        XCTAssertEqual(skipped.address.first { $0.record.uid == last }?.terms.skips, 0)
    }

    func testAnUnseenAIReplyCountsUntilItIsSeen() throws {
        let c = try think("review conflict between this and [[q3-model.xlsx]]", at: at("2026-10-16 18:40"), uid: "t6",
                          meta: ThoughtMeta(kind: .intent, kindBy: .model))
        let reply = try store.appendReply(Comment(timestamp: at("2026-10-17 02:14"), text: "Conflict.", provenance: CommentProvenance(origin: .ai, model: "m")),
                                          toUID: "t6", in: Self.deck)
        XCTAssertEqual(try build().address.first?.terms.awaiting, 1)
        let history = BriefingHistory(vault: vault)
        history.markReplySeen(try XCTUnwrap(reply.uid))
        let after = try builder().build(now: now, history: history)
        XCTAssertEqual(after.address.first { $0.record.uid == "t6" }?.terms.awaiting ?? 0, 0)
        _ = c
    }

    func testAFileEditedAfterTheThoughtAndTheLastOpenNeedsAttention() throws {
        try think("Check the footnote", at: at("2026-10-12 10:00"), uid: "t1")
        try trail.record(TrailEvent(at: at("2026-10-13 09:00"), kind: .opened, file: Self.deck))
        trail.flush()
        // The deck is saved on the 16th: after the thought, after the last open.
        try FileManager.default.setAttributes([.modificationDate: at("2026-10-16 17:00")], ofItemAtPath: root.appendingPathComponent(Self.deck.relativePath).path)
        let edited = try build()
        XCTAssertEqual(edited.editedFiles.map(\.file), [Self.deck])
        XCTAssertEqual(edited.editedFiles.first?.openThoughts, 1)
        XCTAssertEqual(edited.address.first?.terms.activity, 1.0, "and the thought gets the activity boost")

        // Opened since: no longer news.
        try trail.record(TrailEvent(at: at("2026-10-16 18:00"), kind: .opened, file: Self.deck))
        trail.flush()
        XCTAssertTrue(try builder().build(now: now, history: BriefingHistory(vault: vault)).editedFiles.isEmpty)
    }

    func testResumeIsYesterdaysLastSessionWithFilesThatStillExist() throws {
        trail.record(TrailEvent(at: at("2026-10-15 10:00"), kind: .opened, file: Self.model))
        trail.record(TrailEvent(at: at("2026-10-15 10:01"), kind: .opened, file: Self.memo))
        trail.record(TrailEvent(at: at("2026-10-16 21:00"), kind: .opened, file: Self.deck, anchor: FileAnchor(kind: .slide, value: "7")))
        trail.record(TrailEvent(at: at("2026-10-16 21:03"), kind: .opened, file: Self.model))
        trail.record(TrailEvent(at: at("2026-10-16 21:06"), kind: .opened, file: FileRef(relativePath: "gone/deleted.pdf")))
        trail.record(TrailEvent(at: at("2026-10-17 07:00"), kind: .opened, file: Self.memo)) // today: not yesterday
        trail.flush()
        let snapshot = try build()
        XCTAssertEqual(snapshot.resume.map(\.file.relativePath).sorted(), ["decks/q3-board-review.pptx", "finance/q3-model.xlsx"])
        XCTAssertTrue(snapshot.resume.contains { $0.anchor == FileAnchor(kind: .slide, value: "7") })
        XCTAssertLessThanOrEqual(snapshot.resume.count, 6)
    }

    func testAnEmptyVaultHasAnEmptySnapshot() throws {
        for path in ["decks", "finance", "docs"] { try FileManager.default.removeItem(at: root.appendingPathComponent(path)) }
        let snapshot = try build()
        XCTAssertTrue(snapshot.isEmpty)
        XCTAssertEqual(snapshot.summary, "memos=0 address=0 attention=0 resume=0")
    }

    func testBuildingDoesNotWriteAnything() throws {
        try think("Name the two retail buyers", at: at("2026-10-14 10:00"), uid: "t1")
        try index.reindex()
        let before = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") && !$0.contains("index.sqlite") }
        _ = try builder().build(now: now, history: BriefingHistory(vault: vault))
        let after = try FileManager.default.subpathsOfDirectory(atPath: root.path).filter { !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") && !$0.contains("index.sqlite") }
        XCTAssertEqual(after, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: BriefingHistory.url(in: vault).path), "the shell records what was shown")
    }
}

/// The demo vault, for shape and speed.
final class BriefingSnapshotFixtureTests: XCTestCase {
    func testTheFixtureVaultBuildsFastAndPlausibly() throws {
        let fixture = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/vault").resolvingSymlinksInPath()
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("briefing-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixture, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        for name in ["index.sqlite", "index.sqlite-wal", "index.sqlite-shm", "graph.json"] {
            try? FileManager.default.removeItem(at: copy.appendingPathComponent(".flamingo/\(name)"))
        }
        let vault = Vault(root: copy)
        let index = try IndexStore(vault: vault)
        try index.reindex()
        var builder = BriefingBuilder(vault: vault, index: index, trail: TrailStore(vault: vault))
        builder.calendar = testCalendar
        let history = BriefingHistory(vault: vault)

        let now = at("2026-10-17 08:30")
        let snapshot = try builder.build(now: now, history: history)
        print("briefing on the fixture vault: \(snapshot.summary) in \(Int(snapshot.elapsed * 1000)) ms")
        XCTAssertFalse(snapshot.address.isEmpty)
        XCTAssertLessThanOrEqual(snapshot.address.count, 12)
        XCTAssertLessThan(snapshot.elapsed, 1.0, "target 250 ms; this allows a slow, busy machine")
        let again = try builder.build(now: now, history: history)
        XCTAssertEqual(again.address.map(\.id), snapshot.address.map(\.id), "same vault, same briefing")
        XCTAssertTrue(snapshot.address.allSatisfy { $0.record.state == .open || $0.record.state == .snoozed })
        XCTAssertTrue(snapshot.address.contains { $0.record.kind == .todo })
    }
}
