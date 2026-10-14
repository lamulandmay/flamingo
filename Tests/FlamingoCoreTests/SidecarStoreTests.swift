import XCTest
@testable import FlamingoCore

final class SidecarStoreTests: XCTestCase {
    var tv: TempVault!
    var store: SidecarStore!

    override func setUpWithError() throws {
        tv = try TempVault(name)
        store = SidecarStore(vault: tv.vault)
    }

    override func tearDown() { tv.destroy() }

    func testURLsAndTargets() {
        let ref = FileRef(relativePath: "decks/q3.pptx")
        let url = store.sidecarURL(for: ref)
        XCTAssertEqual(url.path, tv.vault.notesDir.path + "/decks/q3.pptx.md")
        XCTAssertEqual(store.target(ofSidecar: url), ref)
        XCTAssertNil(store.target(ofSidecar: tv.root.appendingPathComponent("decks/q3.pptx")))
        XCTAssertNil(store.target(ofSidecar: tv.vault.notesDir.appendingPathComponent("x.txt")))
        XCTAssertNil(store.target(ofSidecar: tv.vault.notesDir.appendingPathComponent(".md")))
        XCTAssertFalse(store.hasSidecar(for: ref))
    }

    func testMissingSidecarReadsAsEmpty() throws {
        XCTAssertEqual(try store.comments(for: FileRef(relativePath: "nope.txt")), [])
        XCTAssertNil(try store.document(for: FileRef(relativePath: "nope.txt")))
        XCTAssertEqual(try store.commentCount(for: FileRef(relativePath: "nope.txt")), 0)
        XCTAssertEqual(try store.all(), [:])
        XCTAssertEqual(try store.sidecarRefs(), [])
    }

    func testAppendCreatesSidecarWithFrontmatterAndIdentity() throws {
        let ref = try tv.file("decks/q3.pptx")
        try store.append(Comment(timestamp: ts("2026-10-14 22:05"), anchor: FileAnchor(kind: .slide, value: "7"), text: "Pricing contradicts [[q3-model.xlsx]]"), to: ref)
        let id = try XCTUnwrap(FileIdentity.existingID(for: tv.vault.url(for: ref)), "the file was stamped")
        XCTAssertEqual(try tv.contents(ofSidecarFor: "decks/q3.pptx"),
                       "---\ntarget: decks/q3.pptx\nid: \(id.uuidString)\n---\n- [2026-10-14 22:05] (slide 7) Pricing contradicts [[q3-model.xlsx]]\n")
        XCTAssertTrue(store.hasSidecar(for: ref))

        try store.append(Comment(timestamp: ts("2026-10-14 22:09"), text: "Needs a better title\nSecond line"), to: ref)
        let comments = try store.comments(for: ref)
        XCTAssertEqual(comments.map(\.firstLine), ["Pricing contradicts [[q3-model.xlsx]]", "Needs a better title"])
        XCTAssertEqual(comments[1].text, "Needs a better title\nSecond line")
        XCTAssertEqual(try store.commentCount(for: ref), 2)
        XCTAssertEqual(try store.document(for: ref)?.id, id)
    }

    func testAppendToFileThatDoesNotExistStillWorksWithoutID() throws {
        let ref = FileRef(relativePath: "ghost.txt")
        try store.append(Comment(timestamp: ts("2026-10-14 22:05"), text: "boo"), to: ref)
        XCTAssertEqual(try tv.contents(ofSidecarFor: "ghost.txt"), "---\ntarget: ghost.txt\n---\n- [2026-10-14 22:05] boo\n")
        XCTAssertEqual(try store.all(), [ref: try store.comments(for: ref)])
    }

    func testUpdateAndDelete() throws {
        let ref = try tv.file("a.txt")
        try store.append(Comment(timestamp: ts("2026-10-14 22:05"), text: "one"), to: ref)
        try store.append(Comment(timestamp: ts("2026-10-14 22:06"), text: "two"), to: ref)
        try store.append(Comment(timestamp: ts("2026-10-14 22:07"), text: "three"), to: ref)
        var two = try store.comments(for: ref)[1]
        two.text = "two, edited"
        two.anchor = FileAnchor(kind: .line, value: "9")
        try store.update(two, in: ref)
        XCTAssertEqual(try store.comments(for: ref).map(\.text), ["one", "two, edited", "three"])
        XCTAssertEqual(try store.comments(for: ref)[1].anchor, FileAnchor(kind: .line, value: "9"))
        XCTAssertThrowsError(try store.update(two, in: ref)) { error in
            XCTAssertEqual(error as? SidecarError, .commentNotFound(two.id))
        }

        let three = try store.comments(for: ref)[2]
        try store.delete(three.id, from: ref)
        XCTAssertEqual(try store.comments(for: ref).map(\.text), ["one", "two, edited"])
        XCTAssertThrowsError(try store.delete(three.id, from: ref))
        XCTAssertThrowsError(try store.delete(UUID(), from: FileRef(relativePath: "none.txt")))
    }

    func testDeletingTheLastCommentRemovesTheNoteAndEmptyFolders() throws {
        let ref = try tv.file("deep/er/a.txt")
        try store.append(Comment(text: "only"), to: ref)
        XCTAssertTrue(store.hasSidecar(for: ref))
        try store.delete(try store.comments(for: ref)[0].id, from: ref)
        XCTAssertFalse(store.hasSidecar(for: ref))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tv.vault.notesDir.appendingPathComponent("deep").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tv.vault.notesDir.path), "notesDir itself stays")
    }

    func testDeletingLastCommentKeepsNoteWithRawLines() throws {
        let ref = try tv.file("a.txt")
        try FileManager.default.createDirectory(at: tv.vault.notesDir, withIntermediateDirectories: true)
        try "---\ntarget: a.txt\n---\n# Keep me\n- [2026-10-14 22:05] gone soon\n".write(to: store.sidecarURL(for: ref), atomically: true, encoding: .utf8)
        try store.delete(try store.comments(for: ref)[0].id, from: ref)
        let id = try XCTUnwrap(FileIdentity.existingID(for: tv.vault.url(for: ref)), "a missing id is filled on write")
        XCTAssertEqual(try tv.contents(ofSidecarFor: "a.txt"), "---\ntarget: a.txt\nid: \(id.uuidString)\n---\n# Keep me\n")
    }

    func testInsertPutsCommentBackWhereItWas() throws {
        let ref = try tv.file("a.txt")
        for t in ["one", "two", "three"] { try store.append(Comment(timestamp: ts("2026-10-14 22:05"), text: t), to: ref) }
        let two = try store.comments(for: ref)[1]
        try store.delete(two.id, from: ref)
        try store.insert(two, at: 1, in: ref)
        XCTAssertEqual(try store.comments(for: ref).map(\.text), ["one", "two", "three"])
        try store.insert(Comment(timestamp: ts("2026-10-14 22:05"), text: "four"), at: 3, in: ref)
        XCTAssertEqual(try store.comments(for: ref).map(\.text), ["one", "two", "three", "four"])
        XCTAssertThrowsError(try store.insert(Comment(text: "x"), at: 9, in: ref))
    }

    func testHandEditedNoteSurvivesARewrite() throws {
        let ref = try tv.file("a.txt")
        let original = """
        ---
        target: a.txt
        tags: [keep]
        ---
        # My heading

        - [2026-10-14 22:05] (page 1) First
          with a second line
        - a bullet Obsidian users might type
        """ + "\n"
        try FileManager.default.createDirectory(at: tv.vault.notesDir, withIntermediateDirectories: true)
        try original.write(to: store.sidecarURL(for: ref), atomically: true, encoding: .utf8)
        try store.append(Comment(timestamp: ts("2026-10-14 22:10"), text: "Second"), to: ref)
        let after = try tv.contents(ofSidecarFor: "a.txt")
        let id = try XCTUnwrap(FileIdentity.existingID(for: tv.vault.url(for: ref)))
        XCTAssertEqual(after, """
        ---
        target: a.txt
        id: \(id.uuidString)
        tags: [keep]
        ---
        # My heading

        - [2026-10-14 22:05] (page 1) First
          with a second line
        - a bullet Obsidian users might type
        - [2026-10-14 22:10] Second
        """ + "\n")
    }

    func testCommentIDsAreStableAcrossReads() throws {
        let ref = try tv.file("a.txt")
        try store.append(Comment(text: "x"), to: ref)
        let a = try store.comments(for: ref)
        let b = try store.comments(for: ref)
        let c = try store.all()[ref]
        XCTAssertEqual(a.map(\.id), b.map(\.id))
        XCTAssertEqual(a.map(\.id), c?.map(\.id))
        XCTAssertEqual(a.map(\.id), try SidecarStore(vault: tv.vault).comments(for: ref).map(\.id), "another store instance agrees")
    }

    func testAllWalksNestedFoldersAndIncludesOrphans() throws {
        let a = try tv.file("a.txt")
        let b = try tv.file("x/y/b.pdf")
        try store.append(Comment(text: "a"), to: a)
        try store.append(Comment(text: "b"), to: b)
        let orphan = FileRef(relativePath: "gone/c.docx")
        try store.append(Comment(text: "c"), to: orphan)
        try "---\ntarget: hidden\n---\n".write(to: tv.vault.notesDir.appendingPathComponent(".hidden.md"), atomically: true, encoding: .utf8)
        try "not a note".write(to: tv.vault.notesDir.appendingPathComponent("stray.txt"), atomically: true, encoding: .utf8)
        let all = try store.all()
        XCTAssertEqual(Set(all.keys), [a, b, orphan])
        XCTAssertEqual(all[orphan]?.map(\.text), ["c"])
        XCTAssertEqual(try store.sidecarRefs(), [a, orphan, b])
        XCTAssertEqual(try store.allDocuments()[b]?.target, b)
    }

    func testSaveAndRemove() throws {
        let ref = try tv.file("a.txt")
        var doc = SidecarDocument(target: FileRef(relativePath: "wrong.txt"), id: nil, comments: [Comment(timestamp: ts("2026-10-14 22:05"), text: "x")])
        doc.setFrontmatterValue("yes", for: "custom")
        try store.save(doc, for: ref)
        let saved = try XCTUnwrap(try store.document(for: ref))
        XCTAssertEqual(saved.target, ref, "target is corrected on save")
        XCTAssertNotNil(saved.id, "id is filled on save")
        XCTAssertEqual(saved.frontmatterValue(for: "custom"), "yes")
        try store.removeSidecar(for: ref)
        XCTAssertFalse(store.hasSidecar(for: ref))
        try store.removeSidecar(for: ref)
    }

    func testMoveMergesIntoExistingNote() throws {
        let a = try tv.file("a.txt")
        let b = try tv.file("b.txt")
        try store.append(Comment(timestamp: ts("2026-10-14 22:05"), text: "from a"), to: a)
        try store.append(Comment(timestamp: ts("2026-10-14 22:06"), text: "from b"), to: b)
        try store.move(sidecarFor: a, to: b)
        XCTAssertFalse(store.hasSidecar(for: a))
        XCTAssertEqual(try store.comments(for: b).map(\.text), ["from b", "from a"])
        XCTAssertEqual(try store.document(for: b)?.target, b)
        try store.move(sidecarFor: FileRef(relativePath: "none.txt"), to: b)
        XCTAssertEqual(try store.comments(for: b).count, 2)
    }

    func testWritesAreAtomicAndLeaveNoTempFiles() throws {
        let ref = try tv.file("a.txt")
        try store.append(Comment(text: "x"), to: ref)
        let entries = try FileManager.default.contentsOfDirectory(atPath: tv.vault.notesDir.path)
        XCTAssertEqual(entries, ["a.txt.md"])
    }

    func testInvalidUTF8IsRefusedRatherThanCorrupted() throws {
        let ref = try tv.file("a.txt")
        try FileManager.default.createDirectory(at: tv.vault.notesDir, withIntermediateDirectories: true)
        try Data([0x2D, 0x20, 0xFF, 0xFE, 0x0A]).write(to: store.sidecarURL(for: ref))
        XCTAssertThrowsError(try store.comments(for: ref)) { error in
            XCTAssertEqual(error as? SidecarError, .notUTF8(path: store.sidecarURL(for: ref).path))
        }
        XCTAssertThrowsError(try store.append(Comment(text: "x"), to: ref))
    }

    func testInboxTargetsAreNotesNotFiles() throws {
        let inbox = FileRef(relativePath: "_inbox/2026-10-14")
        XCTAssertTrue(inbox.isInbox)
        XCTAssertFalse(FileRef(relativePath: "docs/_inbox.txt").isInbox)
        XCTAssertFalse(FileRef(relativePath: "_inbox").isInbox)
        try store.append(Comment(timestamp: ts("2026-10-14 22:05"), text: "a loose thought"), to: inbox)
        XCTAssertEqual(try tv.contents(ofSidecarFor: "_inbox/2026-10-14"), "---\ntarget: _inbox/2026-10-14\n---\n- [2026-10-14 22:05] a loose thought\n")
        XCTAssertEqual(try store.reconcile(), [], "inbox notes are never orphans to heal")
        XCTAssertEqual(try store.all()[inbox]?.count, 1)
    }

    func testDemoVaultSidecarsRoundTrip() throws {
        let notes = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/vault/.flamingo/notes", isDirectory: true)
        guard FileManager.default.fileExists(atPath: notes.path) else { throw XCTSkip("demo vault not present") }
        let demo = SidecarStore(vault: Vault(root: notes.deletingLastPathComponent().deletingLastPathComponent()))
        let docs = try demo.allDocuments()
        XCTAssertGreaterThanOrEqual(docs.count, 10)
        var kinds: Set<FileAnchor.Kind> = []
        for (ref, doc) in docs {
            let text = try String(contentsOf: demo.sidecarURL(for: ref), encoding: .utf8)
            XCTAssertEqual(SidecarFormat.render(doc), text, "demo sidecar \(ref) does not round-trip")
            XCTAssertEqual(doc.target, ref, "frontmatter target disagrees with path for \(ref)")
            XCTAssertNotNil(doc.id, "\(ref) has no id")
            XCTAssertFalse(doc.comments.isEmpty, "\(ref) has no comments")
            XCTAssertTrue(doc.items.allSatisfy { if case .comment = $0 { return true } else { return false } }, "\(ref) has lines the parser did not understand")
            for c in doc.comments { if let a = c.anchor { kinds.insert(a.kind) } }
        }
        XCTAssertTrue(kinds.isSuperset(of: [.page, .slide, .sheet, .cell, .time, .line, .node]), "saw \(kinds)")
    }

    func testConcurrentAppendsLoseNothing() throws {
        let ref = try tv.file("a.txt")
        let group = DispatchGroup()
        for i in 0..<50 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                try? self.store.append(Comment(timestamp: ts("2026-10-14 22:05"), text: "c\(i)"), to: ref)
            }
        }
        group.wait()
        XCTAssertEqual(Set(try store.comments(for: ref).map(\.text)), Set((0..<50).map { "c\($0)" }))
    }
}
