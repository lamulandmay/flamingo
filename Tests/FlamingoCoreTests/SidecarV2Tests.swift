import XCTest
@testable import FlamingoCore

final class SidecarV2Tests: XCTestCase {
    /// The design's example note, in the canonical form `render` writes.
    static let v2Note = """
    ---
    target: decks/q3-board-review.pptx
    id: 3F2C9A0E-5B1D-4C7E-9A63-1E0B6D2F8C41
    ---
    - [2026-10-13 14:11] (slide 7) Pricing contradicts [[q3-model.xlsx]]. The model still carries Arc at $229.
    - [2026-10-16 18:40] (slide 7) review conflict between this and [[q3-model.xlsx]] before friday
      <!-- flamingo: {"intent":{"action":"review-conflict","at":"2026-10-16 18:41","confidence":0.92,"model":"gemma3:4b","objects":["decks/q3-board-review.pptx#slide 7","finance/q3-model.xlsx"]},"kind":"intent","kindBy":"model","origin":"human","uid":"t8m2k4q9xa"} -->
    - [2026-10-17 02:14] (slide 7) Conflict. Slide 7 prices Arc at $249; [[q3-model.xlsx#cell Revenue!C12]] still multiplies by $229.
      <!-- flamingo: {"model":"qwen3.8-27b","origin":"ai","parent":"t8m2k4q9xa","reason":"review-conflict","uid":"t2c7w5n1pd","work":"work/2026-10-17/arc-price-q3-board-review-q3-model.md"} -->
    - [2026-10-17 09:05] Fixed the model; deck stays at $249
      <!-- flamingo: {"origin":"human","parent":"t2c7w5n1pd","uid":"t5r8b3j6ke"} -->

    """

    func testDesignExampleParsesAndRendersByteExact() {
        let doc = SidecarFormat.parseDocument(Self.v2Note)
        XCTAssertEqual(SidecarFormat.render(doc), Self.v2Note)
        let comments = doc.comments
        XCTAssertEqual(comments.count, 4)
        XCTAssertNil(comments[0].meta)
        XCTAssertEqual(comments[1].meta?.uid, "t8m2k4q9xa")
        XCTAssertEqual(comments[1].meta?.kind, .intent)
        XCTAssertEqual(comments[1].meta?.kindBy, .model)
        XCTAssertEqual(comments[1].meta?.intent?.action, "review-conflict")
        XCTAssertEqual(comments[1].meta?.intent?.objects.count, 2)
        XCTAssertEqual(comments[1].provenance?.origin, .human)
        XCTAssertEqual(comments[2].meta?.parent, "t8m2k4q9xa")
        XCTAssertEqual(comments[2].meta?.work, "work/2026-10-17/arc-price-q3-board-review-q3-model.md")
        XCTAssertEqual(comments[2].provenance?.origin, .ai)
        XCTAssertEqual(comments[2].provenance?.reason, "review-conflict")
        XCTAssertFalse(comments[1].text.contains("flamingo"))
        XCTAssertEqual(comments[3].meta?.parent, "t2c7w5n1pd")
    }

    func testEveryFixtureNoteIsUnchangedByParseAndRender() throws {
        for fixture in try Fixtures.all() {
            XCTAssertEqual(SidecarFormat.render(SidecarFormat.parseDocument(fixture.text)), fixture.text, fixture.name)
        }
        let notes = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../fixtures/vault/.flamingo/notes").standardized
        let walker = FileManager.default.enumerator(at: notes, includingPropertiesForKeys: nil)
        var seen = 0
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(SidecarFormat.render(SidecarFormat.parseDocument(text)), text, url.lastPathComponent)
            seen += 1
        }
        XCTAssertGreaterThan(seen, 10)
    }

    func testUnknownKeysAndUnparsedLinesRoundTrip() {
        let source = """
        - [2026-10-17 09:05] Thought
          <!-- flamingo: not json at all -->
          <!-- flamingo: {"future":{"a":[1,2.5,null,true]},"origin":"human","uid":"t0000000ab"} -->

        """
        let doc = SidecarFormat.parseDocument(source)
        let c = doc.comments[0]
        XCTAssertEqual(c.text, "Thought")
        XCTAssertEqual(c.meta?.unparsed, "not json at all")
        XCTAssertEqual(c.meta?.unknownKeys, ["future"])
        XCTAssertEqual(SidecarFormat.render(doc), source)
    }

    func testMetadataLineWithoutOriginIsMetadataNotText() {
        let doc = SidecarFormat.parseDocument("- [2026-10-17 09:05] Thought\n  <!-- flamingo: {\"uid\":\"t1111111aa\",\"state\":\"done\"} -->\n")
        let c = doc.comments[0]
        XCTAssertEqual(c.text, "Thought")
        XCTAssertEqual(c.meta?.uid, "t1111111aa")
        XCTAssertEqual(c.meta?.state, .done)
        XCTAssertNil(c.provenance)
        // Writing it back adds the origin that older builds need to keep the line out of the text.
        XCTAssertTrue(SidecarFormat.render(doc).contains("\"origin\":\"human\""))
    }

    /// Regression for the bug where any metadata line that did not decode as provenance became thought text.
    func testNonJSONMetadataLineNeverBecomesText() {
        let source = "- [2026-10-17 09:05] Thought\n  <!-- flamingo: {\"a\": -->\n  second line\n"
        let doc = SidecarFormat.parseDocument(source)
        XCTAssertEqual(doc.comments[0].text, "Thought\nsecond line")
        XCTAssertEqual(SidecarFormat.render(doc), "- [2026-10-17 09:05] Thought\n  second line\n  <!-- flamingo: {\"a\": -->\n")
    }

    func testWrongTypedKnownKeysAreKeptNotDropped() {
        let source = "- [2026-10-17 09:05] Thought\n  <!-- flamingo: {\"kind\":\"banana\",\"origin\":\"human\",\"uid\":7} -->\n"
        let doc = SidecarFormat.parseDocument(source)
        XCTAssertNil(doc.comments[0].meta?.kind)
        XCTAssertEqual(SidecarFormat.render(doc), source)
    }

    func testNormalizeMergeAndUpdatePreserveMeta() {
        let target = FileRef(relativePath: "a.md")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var meta = ThoughtMeta(uid: "t2222222bb", state: .snoozed, snoozeUntil: "2026-10-18 09:00")
        meta.kind = .todo; meta.kindBy = .user
        let c = Comment(id: UUID(), timestamp: date, anchor: nil, text: "Call Tom", provenance: nil, meta: meta)
        var doc = SidecarDocument(target: target, id: nil, comments: [c])
        XCTAssertEqual(doc.comments[0].meta, meta)
        var other = SidecarDocument(target: target, id: nil, comments: [])
        other.merge(doc)
        XCTAssertEqual(other.comments[0].meta, meta)
        var edited = doc.comments[0]
        edited.text = "Call Tom Monday"
        XCTAssertTrue(doc.update(edited))   // same id → matches
        XCTAssertEqual(doc.comments[0].meta, meta)
        // A merge of the same thought in two states keeps both (they differ), a repeat of one does not duplicate.
        var twin = doc
        twin.merge(doc)
        XCTAssertEqual(twin.comments.count, 1)
    }

    func testTextEditKeepsUIDAndChangesIDStateChangeKeepsID() throws {
        let tv = try TempVault(); defer { tv.destroy() }
        let store = SidecarStore(vault: tv.vault)
        let ref = try tv.file("note.txt")
        try store.append(Comment(timestamp: Date(timeIntervalSince1970: 1_800_000_000), text: "first words").stamped(), to: ref)
        let original = try XCTUnwrap(store.comments(for: ref).first)
        let uid = try XCTUnwrap(original.uid)
        let done = try store.update(uid: uid, in: ref) { $0.meta?.state = .done }
        XCTAssertEqual(done.id, original.id, "metadata is not part of the derived id")
        let edited = try store.update(uid: uid, in: ref) { $0.text = "other words" }
        XCTAssertNotEqual(edited.id, original.id)
        XCTAssertEqual(edited.uid, uid)
        XCTAssertEqual(edited.meta?.state, .done)
        XCTAssertEqual(try store.comment(uid: uid, in: ref)?.text, "other words")
        XCTAssertThrowsError(try store.update(uid: "tnope", in: ref) { _ in }) {
            XCTAssertEqual($0 as? SidecarError, .thoughtNotFound(uid: "tnope"))
        }
    }

    func testUpdateByUIDFindsAThoughtWhoseTextChangedConcurrently() throws {
        let tv = try TempVault(); defer { tv.destroy() }
        let store = SidecarStore(vault: tv.vault), other = SidecarStore(vault: tv.vault)
        let ref = try tv.file("note.txt")
        try store.append(Comment(text: "draft").stamped(), to: ref)
        let held = try XCTUnwrap(store.comments(for: ref).first)       // a background job holds this
        var edit = held; edit.text = "draft, edited in the UI"
        try other.update(edit, in: ref)                                 // the UI edits the text
        XCTAssertThrowsError(try store.update(held, in: ref), "the derived id went stale")
        let updated = try store.update(uid: try XCTUnwrap(held.uid), in: ref) { $0.meta?.kind = .question; $0.meta?.kindBy = .model }
        XCTAssertEqual(updated.text, "draft, edited in the UI")
        XCTAssertEqual(updated.meta?.kind, .question)
    }

    func testEnsureUIDGivesLegacyThoughtsAUIDOnce() throws {
        let tv = try TempVault(); defer { tv.destroy() }
        let store = SidecarStore(vault: tv.vault)
        let ref = try tv.file("note.txt")
        try store.append(Comment(text: "legacy"), to: ref)
        try store.append(Comment(text: "other legacy"), to: ref)
        let ids = try store.comments(for: ref).map(\.id)
        let uid = try store.ensureUID(forCommentID: ids[0], in: ref)
        XCTAssertTrue(ThoughtUID.isWellFormed(uid))
        XCTAssertEqual(try store.ensureUID(forCommentID: ids[0], in: ref), uid)
        let after = try store.comments(for: ref)
        XCTAssertEqual(after.map(\.id), ids)
        XCTAssertNil(after[1].uid, "notes are never rewritten in bulk")
        XCTAssertThrowsError(try store.ensureUID(forCommentID: UUID(), in: ref))
    }

    func testAppendReplyPlacesTheReplyAfterTheParentsLastDescendant() throws {
        let tv = try TempVault(); defer { tv.destroy() }
        let store = SidecarStore(vault: tv.vault)
        let ref = try tv.file("note.txt")
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        try store.append(Comment(timestamp: t, text: "root one").stamped(), to: ref)
        try store.append(Comment(timestamp: t.addingTimeInterval(60), text: "root two").stamped(), to: ref)
        let roots = try store.comments(for: ref)
        let one = try XCTUnwrap(roots[0].uid)
        let r1 = try store.appendReply(Comment(timestamp: t.addingTimeInterval(120), text: "reply to one"), toUID: one, in: ref)
        let r2 = try store.appendReply(Comment(timestamp: t.addingTimeInterval(180), text: "reply to reply"), toUID: try XCTUnwrap(r1.uid), in: ref)
        let r3 = try store.appendReply(Comment(timestamp: t.addingTimeInterval(240), text: "second reply to one", provenance: CommentProvenance(origin: .ai, model: "m")), toUID: one, in: ref)
        XCTAssertEqual(r1.meta?.parent, one)
        XCTAssertEqual(r2.meta?.parent, r1.uid)
        XCTAssertEqual(r3.provenance?.origin, .ai)
        XCTAssertEqual(try store.comments(for: ref).map(\.text), ["root one", "reply to one", "reply to reply", "second reply to one", "root two"])
        XCTAssertThrowsError(try store.appendReply(Comment(text: "x"), toUID: "tmissing", in: ref))
        // Obsidian sees consecutive bullets: no nesting, no new syntax.
        let text = try tv.contents(ofSidecarFor: "note.txt")
        XCTAssertFalse(text.contains("\n  - "))
    }

    func testAppendWithFrontmatterCreatesWebAndFolderNotes() throws {
        let tv = try TempVault(); defer { tv.destroy() }
        try tv.folder("decks")
        let store = SidecarStore(vault: tv.vault)
        let web = try XCTUnwrap(WebThought.ref(for: "https://www.Example.com/blog/Arc-launch?x=1#top", title: "Arc launch notes"))
        XCTAssertTrue(web.isWeb); XCTAssertTrue(web.isVirtual); XCTAssertFalse(web.isInbox)
        XCTAssertTrue(web.relativePath.hasPrefix("_web/example.com/arc-launch-notes-"), web.relativePath)
        XCTAssertEqual(web, WebThought.ref(for: "https://example.com/blog/Arc-launch?x=1", title: "Arc launch notes"), "the fragment is not part of the page")
        try store.append(Comment(text: "worth reading").stamped(), to: web, frontmatter: WebThought.frontmatter(url: "https://example.com/blog/Arc-launch?x=1", title: "Arc launch notes"))
        try store.append(Comment(text: "again").stamped(), to: web, frontmatter: ["url": "ignored"])
        let doc = try XCTUnwrap(store.document(for: web))
        XCTAssertEqual(doc.target, web)
        XCTAssertEqual(doc.frontmatterValue(for: "url"), "https://example.com/blog/Arc-launch?x=1")
        XCTAssertEqual(doc.frontmatterValue(for: "title"), "Arc launch notes")
        XCTAssertEqual(doc.comments.count, 2)
        XCTAssertNil(doc.id, "a web page has no file identity")

        let folder = FileRef(relativePath: "decks")
        try store.append(Comment(text: "tidy these up").stamped(), to: folder, frontmatter: ["subject": "folder"])
        let note = try XCTUnwrap(store.document(for: folder))
        XCTAssertTrue(note.isFolderNote)
        XCTAssertNil(note.id, "the folder itself is never marked")
        XCTAssertEqual(store.sidecarURL(for: folder).path, tv.vault.notesDir.path + "/decks.md")
        XCTAssertTrue(Set(try store.sidecarRefs()).isSuperset(of: [web, folder]))
        // A file `x.md` and a folder `x` do not share a note.
        XCTAssertNotEqual(store.sidecarURL(for: FileRef(relativePath: "decks.md")), store.sidecarURL(for: folder))
    }

    func testStampedAndCodableCompatibility() throws {
        let c = Comment(text: "hello").stamped()
        XCTAssertTrue(ThoughtUID.isWellFormed(try XCTUnwrap(c.uid)))
        XCTAssertEqual(c.provenance?.origin, .human)
        XCTAssertEqual(c.stamped().uid, c.uid, "stamping twice keeps the uid")
        XCTAssertEqual(c.modified(at: Date(timeIntervalSince1970: 1_800_000_000)).meta?.modified,
                       ThoughtDates.stamp(Date(timeIntervalSince1970: 1_800_000_000)))
        let old = try JSONEncoder().encode(Comment(text: "Old thought"))
        XCTAssertNil(try JSONDecoder().decode(Comment.self, from: old).meta)
        let round = try JSONDecoder().decode(Comment.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(round, c)
        XCTAssertEqual(ThoughtDates.parse("2026-10-17 09:05").map { ThoughtDates.string(from: $0.date, hasTime: $0.hasTime) }, "2026-10-17 09:05")
        XCTAssertNil(ThoughtDates.parse("2026-02-30"))
    }

    func testVirtualRefs() {
        XCTAssertTrue(FileRef(relativePath: "_inbox/2026-10-14").isVirtual)
        XCTAssertTrue(FileRef(relativePath: "_web/a.com/x-abcdef").isVirtual)
        XCTAssertFalse(FileRef(relativePath: "docs/_web/x").isVirtual)
        XCTAssertFalse(FileRef(relativePath: "_web").isVirtual)
        XCTAssertEqual(FileRef.webDirectory, "_web")
        let v = Vault(root: URL(fileURLWithPath: "/tmp/v"))
        XCTAssertEqual(v.workDir.path, "/tmp/v/.flamingo/work")
        XCTAssertEqual(v.workLedgerURL.path, "/tmp/v/.flamingo/work/ledger.jsonl")
    }
}
