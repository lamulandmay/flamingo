import XCTest
@testable import FlamingoCore

/// One test per defect found in review, so none of them come back.
final class RegressionTests: XCTestCase {
    var tv: TempVault!
    var store: SidecarStore!

    override func setUpWithError() throws {
        tv = try TempVault(name)
        store = SidecarStore(vault: tv.vault)
    }

    override func tearDown() { FileIdentity.invalidateCache(for: tv.vault); tv.destroy() }

    // 1 + 9: the note's id follows the file's actual identity.

    func testMergedNoteCarriesTheIdOfTheFileItNowDescribes() throws {
        let a = try tv.file("a.txt")
        let b = try tv.file("b.txt")
        try store.append(Comment(timestamp: ts("2026-10-14 22:05"), text: "about a"), to: a)
        try store.append(Comment(timestamp: ts("2026-10-14 22:06"), text: "about b"), to: b)
        let idA = try XCTUnwrap(try store.document(for: a)?.id)
        try tv.remove("b.txt")
        try tv.rename("a.txt", to: "b.txt")
        XCTAssertEqual(try store.reconcile(), [SidecarStore.Move(from: a, to: b)])
        XCTAssertEqual(try store.document(for: b)?.id, idA, "merged note carries the id of the file now at b.txt")

        try tv.rename("b.txt", to: "c.txt")
        let c = FileRef(relativePath: "c.txt")
        XCTAssertEqual(try store.reconcile(), [SidecarStore.Move(from: b, to: c)])
        XCTAssertEqual(try store.comments(for: c).map(\.text), ["about b", "about a"])
    }

    func testStaleIdIsCorrectedOnWrite() throws {
        let a = try tv.file("a.txt")
        try store.append(Comment(text: "x"), to: a)
        let old = try XCTUnwrap(try store.document(for: a)?.id)
        try tv.remove("a.txt")
        try tv.file("a.txt", "a brand new file, no xattr")
        try store.append(Comment(text: "y"), to: a)
        let now = try XCTUnwrap(FileIdentity.existingID(for: tv.vault.url(for: a)), "the new file was stamped")
        XCTAssertNotEqual(now, old)
        XCTAssertEqual(try store.document(for: a)?.id, now)
    }

    // 2: duplicated files must not share an id.

    func testDuplicatedFileGetsItsOwnIdAndItsOwnRenameHeals() throws {
        let a = try tv.file("a.txt")
        try store.append(Comment(timestamp: ts("2026-10-14 22:05"), text: "on original"), to: a)
        try FileManager.default.copyItem(at: tv.vault.url(for: a), to: tv.root.appendingPathComponent("a copy.txt"))
        let copy = FileRef(relativePath: "a copy.txt")
        XCTAssertEqual(try FileIdentity.existingID(for: tv.vault.url(for: copy)), try FileIdentity.existingID(for: tv.vault.url(for: a)), "copy preserved the xattr")
        try store.append(Comment(timestamp: ts("2026-10-14 22:06"), text: "on copy"), to: copy)
        XCTAssertNotEqual(try store.document(for: copy)?.id, try store.document(for: a)?.id)
        try tv.rename("a copy.txt", to: "renamed.txt")
        let renamed = FileRef(relativePath: "renamed.txt")
        XCTAssertEqual(try store.reconcile(), [SidecarStore.Move(from: copy, to: renamed)])
        XCTAssertEqual(try store.comments(for: a).map(\.text), ["on original"])
        XCTAssertEqual(try store.comments(for: renamed).map(\.text), ["on copy"])
    }

    func testCommentingOnARenamedFileAdoptsItsOrphanNoteImmediately() throws {
        let a = try tv.file("a.txt")
        try store.append(Comment(timestamp: ts("2026-10-14 22:05"), text: "before rename"), to: a)
        try tv.rename("a.txt", to: "b.txt")
        let b = FileRef(relativePath: "b.txt")
        try store.append(Comment(timestamp: ts("2026-10-14 22:06"), text: "after rename"), to: b)
        XCTAssertEqual(try store.comments(for: b).map(\.text), ["before rename", "after rename"])
        XCTAssertFalse(store.hasSidecar(for: a))
    }

    func testAmbiguousCopiesAreLeftAlone() throws {
        let a = try tv.file("a.txt")
        try store.append(Comment(text: "x"), to: a)
        let id = try XCTUnwrap(FileIdentity.existingID(for: tv.vault.url(for: a)))
        try FileIdentity.assign(id, to: tv.vault.url(for: try tv.file("c1.txt")))
        try FileIdentity.assign(id, to: tv.vault.url(for: try tv.file("c2.txt")))
        try tv.remove("a.txt")
        XCTAssertEqual(try store.reconcile(), [], "two candidates without notes: cannot choose")
        XCTAssertTrue(store.hasSidecar(for: a))
    }

    // 3: ids of identical comments stay usable while deleting them one by one.

    func testDeletingIdenticalCommentsByTheirOriginalIds() throws {
        let a = try tv.file("a.txt")
        let same = Comment(timestamp: ts("2026-10-14 22:05"), text: "same")
        try store.append(same, to: a)
        try store.append(same, to: a)
        try store.append(Comment(timestamp: ts("2026-10-14 22:06"), text: "other"), to: a)
        let rows = try store.comments(for: a)
        XCTAssertNotEqual(rows[0].id, rows[1].id)
        try store.delete(rows[0].id, from: a)
        try store.delete(rows[1].id, from: a)
        XCTAssertEqual(try store.comments(for: a).map(\.text), ["other"])
        var edited = rows[1]
        edited.text = "edited"
        XCTAssertThrowsError(try store.update(edited, in: a), "group is gone now")
    }

    func testUpdatingARenumberedDuplicateEditsOneOfTheGroup() throws {
        let a = try tv.file("a.txt")
        let same = Comment(timestamp: ts("2026-10-14 22:05"), text: "same")
        try store.append(same, to: a)
        try store.append(same, to: a)
        let rows = try store.comments(for: a)
        try store.delete(rows[0].id, from: a)
        var edited = rows[1]
        edited.text = "edited"
        try store.update(edited, in: a)
        XCTAssertEqual(try store.comments(for: a).map(\.text), ["edited"])
    }

    // 4 + 11: CRLF and lone CR.

    func testCRLFNotesParseAndRoundTrip() throws {
        let x = "---\r\ntarget: a.txt\r\n---\r\n- [2026-10-14 22:05] (slide 7) hi\r\n  more\r\n"
        let doc = SidecarFormat.parseDocument(x)
        XCTAssertEqual(doc.target, FileRef(relativePath: "a.txt"))
        XCTAssertEqual(doc.comments.count, 1)
        XCTAssertEqual(doc.comments[0].anchor, FileAnchor(kind: .slide, value: "7"))
        XCTAssertEqual(doc.comments[0].text, "hi\nmore")
        XCTAssertEqual(doc.lineTerminator, "\r\n")
        XCTAssertEqual(SidecarFormat.render(doc), x)

        let a = try tv.file("a.txt")
        try FileManager.default.createDirectory(at: tv.vault.notesDir, withIntermediateDirectories: true)
        try x.write(to: store.sidecarURL(for: a), atomically: true, encoding: .utf8)
        try store.append(Comment(timestamp: ts("2026-10-14 22:06"), text: "new\nline"), to: a)
        XCTAssertEqual(try store.comments(for: a).map(\.firstLine), ["hi", "new"])
        let after = try tv.contents(ofSidecarFor: "a.txt")
        XCTAssertFalse(after.unicodeScalars.contains("\n") && after.contains("\n") && after.replacingOccurrences(of: "\r\n", with: "").unicodeScalars.contains("\n"), "no bare LF in a CRLF note: \(after.debugDescription)")
        XCTAssertTrue(after.hasSuffix("- [2026-10-14 22:06] new\r\n  line\r\n"), after.debugDescription)
    }

    func testTextEndingInCarriageReturnRoundTrips() {
        for text in ["a\r", "\r", "x\r\ny", "\r\n"] {
            let doc = SidecarDocument(target: FileRef(relativePath: "a.txt"), id: nil, comments: [Comment(timestamp: ts("2026-10-14 22:05"), text: text)])
            XCTAssertEqual(SidecarFormat.parseDocument(SidecarFormat.render(doc)), doc, text.debugDescription)
        }
    }

    // 5: combining marks after the structural spaces.

    func testTextStartingWithCombiningMarksRoundTrips() {
        for text in ["\u{FE0F} variation selector first", "\u{301}x", "x\n\u{301}y", "\u{1F3FD}skin tone"] {
            for anchor in [nil, FileAnchor(kind: .page, value: "1"), FileAnchor(kind: .cell, value: "A\u{301}1")] {
                let doc = SidecarDocument(target: FileRef(relativePath: "a.txt"), id: nil,
                                          comments: [Comment(timestamp: ts("2026-10-14 22:05"), anchor: anchor, text: text)])
                let back = SidecarFormat.parseDocument(SidecarFormat.render(doc))
                XCTAssertEqual(back, doc, "\(text.debugDescription) with \(String(describing: anchor))")
                XCTAssertEqual(back.comments.first?.text, text)
            }
        }
    }

    // 6: hidden targets.

    func testNotesForHiddenFilesAreListed() throws {
        let dot = try tv.file(".zshrc")
        let nested = try tv.file(".config/x.txt")
        try store.append(Comment(text: "a"), to: dot)
        try store.append(Comment(text: "b"), to: nested)
        XCTAssertEqual(try store.sidecarRefs(), [nested, dot])
        XCTAssertEqual(Set(try store.all().keys), [dot, nested])
    }

    // 7: case-only rename.

    func testCaseOnlyRenameMovesTheNote() throws {
        let upper = try tv.file("Report.txt")
        try store.append(Comment(timestamp: ts("2026-10-14 22:05"), text: "x"), to: upper)
        try tv.rename("Report.txt", to: "report.txt")
        let lower = FileRef(relativePath: "report.txt")
        guard tv.vault.existsExactly(lower), !tv.vault.existsExactly(upper) else {
            throw XCTSkip("volume is case-sensitive or did not preserve the new case")
        }
        XCTAssertEqual(try store.reconcile(), [SidecarStore.Move(from: upper, to: lower)])
        try store.append(Comment(timestamp: ts("2026-10-14 22:06"), text: "y"), to: lower)
        XCTAssertEqual(try store.comments(for: lower).map(\.text), ["x", "y"], "no duplication from merging a note with itself")
        XCTAssertEqual(try store.sidecarRefs(), [lower])
        XCTAssertEqual(try store.all()[lower]?.count, 2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: tv.vault.notesDir.path).contains("report.txt.md"))
    }

    // 8: DST gap.

    func testTimestampInDaylightSavingGapIsStillAComment() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        // Find a gap in the current zone, if it has one in the last 60 years.
        var gap: String? = nil
        var probe = Date().addingTimeInterval(-60 * 365 * 86400)
        let end = Date().addingTimeInterval(365 * 86400)
        while probe < end, gap == nil {
            if let next = TimeZone.current.nextDaylightSavingTimeTransition(after: probe) {
                let before = TimeZone.current.daylightSavingTimeOffset(for: next.addingTimeInterval(-1))
                let after = TimeZone.current.daylightSavingTimeOffset(for: next)
                if after > before {   // spring forward: the wall-clock hour after `next` does not exist
                    let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: next.addingTimeInterval(-1))
                    gap = String(format: "%04d-%02d-%02d %02d:30", c.year!, c.month!, c.day!, c.hour! + 1)
                }
                probe = next.addingTimeInterval(86400)
            } else { break }
        }
        guard let gap else { throw XCTSkip("no daylight-saving gap in \(TimeZone.current.identifier)") }
        let doc = SidecarFormat.parseDocument("- [\(gap)] written elsewhere\n")
        XCTAssertEqual(doc.comments.count, 1, "gap time \(gap) must still parse as a comment")
        XCTAssertEqual(doc.comments.first?.text, "written elsewhere")
    }

    func testTimestampValidationStillRejectsNonsense() {
        for bad in ["2026-02-30 10:00", "2026-13-01 10:00", "2026-00-10 10:00", "2026-01-32 10:00", "2026-01-01 24:00", "2026-01-01 10:60", "2026-01-01T10:00", "abcd-01-01 10:00"] {
            XCTAssertNil(SidecarFormat.timestamp(from: bad), bad)
        }
        XCTAssertNotNil(SidecarFormat.timestamp(from: "2024-02-29 10:00"))
        XCTAssertNil(SidecarFormat.timestamp(from: "2023-02-29 10:00"))
        XCTAssertEqual(SidecarFormat.string(fromTimestamp: ts("0999-01-01 00:00")), "0999-01-01 00:00")
    }

    // 10: anchor values with line breaks.

    func testAnchorValueWithNewlineIsFlattened() {
        XCTAssertNil(FileAnchor(parsing: "slide 1\n2"))
        let doc = SidecarDocument(target: FileRef(relativePath: "a.txt"), id: nil,
                                  comments: [Comment(timestamp: ts("2026-10-14 22:05"), anchor: FileAnchor(kind: .slide, value: "1\n2"), text: "t")])
        XCTAssertEqual(doc.comments[0].anchor, FileAnchor(kind: .slide, value: "1 2"))
        XCTAssertEqual(SidecarFormat.parseDocument(SidecarFormat.render(doc)), doc)
    }

    // 12: merge never glues, never duplicates.

    func testMergeKeepsRawLinesSeparateAndSkipsDuplicates() {
        var a = SidecarFormat.parseDocument("---\ntarget: a.txt\n---\n- [2026-10-14 22:05] one\n")
        let b = SidecarFormat.parseDocument("---\ntarget: b.txt\n---\n  indented prose\n- [2026-10-14 22:06] two\n- [2026-10-14 22:05] one\n")
        a.merge(b)
        XCTAssertEqual(a.comments.map(\.text), ["one", "two"])
        let back = SidecarFormat.parseDocument(SidecarFormat.render(a))
        XCTAssertEqual(back, a)
        XCTAssertEqual(back.comments.map(\.text), ["one", "two"])
        XCTAssertTrue(back.items.contains(.raw("  indented prose")))
    }

    func testReconcilingTheSameOrphanTwiceDoesNotDuplicate() throws {
        let a = try tv.file("a.txt")
        try store.append(Comment(timestamp: ts("2026-10-14 22:05"), text: "x"), to: a)
        let orphanURL = store.sidecarURL(for: a)
        let backup = try Data(contentsOf: orphanURL)
        try tv.rename("a.txt", to: "b.txt")
        let b = FileRef(relativePath: "b.txt")
        try store.reconcile()
        try backup.write(to: orphanURL)   // as if we crashed before removing the old note
        try store.reconcile()
        XCTAssertEqual(try store.comments(for: b).map(\.text), ["x"])
        XCTAssertFalse(store.hasSidecar(for: a))
    }

    // 13: no escaping notesDir.

    func testRefsThatEscapeNotesDirAreRefused() {
        for bad in ["../escape.txt", "a/../../escape.txt", "/abs.txt", "", "a/", "./x.txt", "a//b.txt"] {
            XCTAssertThrowsError(try store.append(Comment(text: "x"), to: FileRef(relativePath: bad)), bad)
            XCTAssertThrowsError(try store.comments(for: FileRef(relativePath: bad)), bad)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tv.vault.stateDir.appendingPathComponent("escape.txt.md").path))
    }

    // 14: long names.

    func testNamesNearNameMaxStillWrite() throws {
        let name = String(repeating: "n", count: 248) + ".txt"
        let ref = try tv.file(name)
        try store.append(Comment(text: "x"), to: ref)
        XCTAssertEqual(try store.comments(for: ref).count, 1)
    }

    // 17: hand-added frontmatter survives deleting the last comment.

    func testDeletingLastCommentKeepsNoteWithExtraFrontmatter() throws {
        let a = try tv.file("a.txt")
        try FileManager.default.createDirectory(at: tv.vault.notesDir, withIntermediateDirectories: true)
        try "---\ntarget: a.txt\ntags: [keep]\n---\n- [2026-10-14 22:05] x\n".write(to: store.sidecarURL(for: a), atomically: true, encoding: .utf8)
        try store.delete(try store.comments(for: a)[0].id, from: a)
        XCTAssertTrue(store.hasSidecar(for: a))
        XCTAssertEqual(try store.document(for: a)?.frontmatterValue(for: "tags"), "[keep]")
    }

    // XATTR_CREATE: a losing racer adopts the winner's id.

    func testIdAssignmentIsFirstWriterWins() throws {
        let url = tv.vault.url(for: try tv.file("a.txt"))
        let winner = UUID()
        try FileIdentity.assign(winner, to: url)
        XCTAssertEqual(try FileIdentity.id(for: url), winner)
        let ids = (0..<20).map { _ in try? FileIdentity.id(for: url) }
        XCTAssertEqual(Set(ids.compactMap { $0 }), [winner])
    }

    func testCarriersListsEveryCopy() throws {
        let a = try tv.file("a.txt")
        let b = try tv.file("deep/b.txt")
        let id = try FileIdentity.id(for: tv.vault.url(for: a))
        try FileIdentity.assign(id, to: tv.vault.url(for: b))
        XCTAssertEqual(FileIdentity.carriers(in: tv.vault)[id], [a, b])
        XCTAssertEqual(FileIdentity.ids(in: tv.vault)[id], a)
    }
}
