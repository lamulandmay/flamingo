import XCTest
import AppKit
import FlamingoCore
@testable import FlamingoTrail

final class TrailStoreTests: TrailStoreTestCase {

    // MARK: Writing

    func testRecordIsReadableBeforeFlush() throws {
        let store = makeStore()
        let e = ev(.opened, 0, file: "decks/q3.pptx")
        store.record(e)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path), "buffered, not yet on disk")
        XCTAssertEqual(try store.events().map(\.id), [e.id])
    }

    func testFlushWritesOneLinePerEvent() throws {
        let store = makeStore()
        let events = [
            ev(.opened, 0, file: "decks/q3.pptx", anchor: FileAnchor(kind: .slide, value: "7")),
            ev(.commented, 5, file: "decks/q3.pptx", text: "Pricing contradicts [[q3-model.xlsx]]",
               anchor: FileAnchor(kind: .slide, value: "7")),
            ev(.searched, 9, text: "churn"),
            ev(.linked, 12, file: "notes/a.md", text: "q3-model.xlsx"),
        ]
        events.forEach(store.record)
        store.flush()

        let text = try fileText(store)
        XCTAssertTrue(text.hasSuffix("\n"))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, events.count + 1, "one line per event plus the empty remainder after the last newline")
        XCTAssertEqual(lines.last, "")
        XCTAssertTrue(lines[0].contains(#""file":"decks/q3.pptx""#))
        XCTAssertTrue(lines[0].contains(#""anchor":"slide 7""#))
        XCTAssertTrue(lines[0].contains(#""at":"2026-10-14T20:05:12.000Z""#))
        XCTAssertFalse(text.contains(#"\/"#), "slashes are not escaped")

        // A fresh store reads back exactly what was written.
        XCTAssertEqual(try TrailStore(vault: vault).events(), events)
        XCTAssertEqual(try store.events(), events)
    }

    func testFlushIsIdempotent() throws {
        let store = makeStore()
        store.record(ev(.opened, 0, file: "a.md"))
        store.flush()
        store.flush()
        XCTAssertEqual(try fileLines(store).filter { !$0.isEmpty }.count, 1)
    }

    func testScheduledFlushHappensOnItsOwn() throws {
        let store = TrailStore(vault: vault)
        store.flushDelay = 0.05
        store.record(ev(.opened, 0, file: "a.md"))
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: store.fileURL.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(try fileLines(store).filter { !$0.isEmpty }.count, 1)
    }

    func testDeinitFlushesPendingEvents() throws {
        let e = ev(.opened, 0, file: "a.md")
        weak var weakStore: TrailStore?
        do {
            let store = makeStore()
            weakStore = store
            store.record(e)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        }
        XCTAssertNil(weakStore, "nothing (notifications, scheduled flushes) keeps the store alive")
        XCTAssertEqual(try TrailStore(vault: vault).events().map(\.id), [e.id])
    }

    func testWillTerminateFlushes() throws {
        let store = makeStore()
        let e = ev(.searched, 0, text: "churn")
        store.record(e)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertTrue(try fileText(store).contains(e.id.uuidString))
    }

    func testRecordPostsChangeNotification() {
        let store = makeStore()
        let posted = expectation(forNotification: TrailStore.didChangeNotification, object: store)
        store.record(ev(.opened, 0, file: "a.md"))
        wait(for: [posted], timeout: 2)
    }

    // MARK: Torn lines

    func testTornLastLineIsSkippedAndNextRecordStartsFreshLine() throws {
        let store = makeStore()
        let first = ev(.opened, 0, file: "a.md")
        store.record(first)
        store.flush()
        try appendRaw(#"{"at":"2026-10-14T20:0"#, to: store.fileURL)   // the app died mid-write

        XCTAssertEqual(try store.events().map(\.id), [first.id])
        XCTAssertEqual(try TrailStore(vault: vault).events().map(\.id), [first.id])

        let second = ev(.opened, 30, file: "b.md")
        store.record(second)
        store.flush()
        let lines = try fileLines(store)
        XCTAssertEqual(lines.count, 4)                                 // first, torn, second, ""
        XCTAssertEqual(lines[1], #"{"at":"2026-10-14T20:0"#)
        XCTAssertTrue(lines[2].hasPrefix("{") && lines[2].contains(second.id.uuidString))

        XCTAssertEqual(try store.events().map(\.id), [first.id, second.id])
        XCTAssertEqual(try TrailStore(vault: vault).events().map(\.id), [first.id, second.id])
    }

    func testCompleteLastLineWithoutNewlineIsReadOnce() throws {
        // Hand-written file whose last line lacks a newline: usable now, and not duplicated
        // once something is appended after it.
        try writeTrailFile(#"{"at":"2026-10-14T20:05:12Z","kind":"opened","file":"a.md"}"#)
        let store = makeStore()
        let before = try store.events()
        XCTAssertEqual(before.map(\.file), [ref("a.md")])

        let next = ev(.opened, 60, file: "b.md")
        store.record(next)
        store.flush()
        let after = try store.events()
        XCTAssertEqual(after.map(\.file), [ref("a.md"), ref("b.md")])
        XCTAssertEqual(after[0].id, before[0].id)
        XCTAssertEqual(try TrailStore(vault: vault).events().map(\.id), after.map(\.id))
    }

    func testBlankAndGarbageLinesAreSkipped() throws {
        try writeTrailFile("""
        {"at":"2026-10-14T20:05:12Z","kind":"opened","file":"a.md"}

           \t
        not json at all
        {"at":"2026-10-14T20:05:22Z","kind":"teleported","file":"a.md"}
        {"at":"2026-10-14T20:05:32Z","kind":"searched","text":"churn"}

        """)
        let events = try makeStore().events()
        XCTAssertEqual(events.map(\.kind), [.opened, .searched])
    }

    // MARK: Incremental reads

    func testIncrementalReadsSeeEverythingOnce() throws {
        let store = makeStore()
        let a = ev(.opened, 0, file: "a.md")
        store.record(a)
        store.flush()
        XCTAssertEqual(try store.events().map(\.id), [a.id])

        let b = ev(.opened, 10, file: "b.md"), c = ev(.searched, 20, text: "churn")
        store.record(b)
        XCTAssertEqual(try store.events().map(\.id), [a.id, b.id], "pending b merged with cached a")
        store.record(c)
        store.flush()
        XCTAssertEqual(try store.events().map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(try store.events().map(\.id), [a.id, b.id, c.id], "reading again adds nothing")
        XCTAssertEqual(try TrailStore(vault: vault).events().map(\.id), [a.id, b.id, c.id])
    }

    func testSecondStoreAppendsAreSeenIncrementally() throws {
        // Two windows on the same vault.
        let one = makeStore(), two = makeStore()
        let a = ev(.opened, 0, file: "a.md"), b = ev(.opened, 10, file: "b.md")
        one.record(a); one.flush()
        XCTAssertEqual(try one.events().map(\.id), [a.id])
        two.record(b); two.flush()
        XCTAssertEqual(try one.events().map(\.id), [a.id, b.id])
        XCTAssertEqual(try two.events().map(\.id), [a.id, b.id])
    }

    func testReadsAcrossChunkBoundaries() throws {
        // Well over the 256 KiB read chunk, with long lines that straddle chunk edges.
        let store = makeStore()
        let long = String(repeating: "pricing contradicts the model ", count: 40)
        var expected: [UUID] = []
        for i in 0..<1500 {
            let e = i % 3 == 0
                ? ev(.commented, Double(i) * 11, file: "f\(i % 40).md", text: "\(i) \(long)")
                : ev(.opened, Double(i) * 11, file: "f\(i % 40).md")
            store.record(e)
            expected.append(e.id)
        }
        store.flush()
        let size = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.size] as! Int
        XCTAssertGreaterThan(size, 3 << 18)
        XCTAssertEqual(try TrailStore(vault: vault).events().map(\.id), expected)
        XCTAssertEqual(try store.events().map(\.id), expected)
    }

    func testTruncationResetsCache() throws {
        let store = makeStore()
        let events = opens(["a.md", "b.md", "c.md"])
        events.forEach(store.record)
        store.flush()
        XCTAssertEqual(try store.events().count, 3)

        // Rewrite in place (same inode), shorter.
        let firstLine = try fileLines(store)[0] + "\n"
        let h = try FileHandle(forWritingTo: store.fileURL)
        try h.truncate(atOffset: 0)
        try h.write(contentsOf: Data(firstLine.utf8))
        try h.close()

        XCTAssertEqual(try store.events().map(\.id), [events[0].id])
    }

    func testDeletionResetsCache() throws {
        let store = makeStore()
        opens(["a.md", "b.md"]).forEach(store.record)
        store.flush()
        XCTAssertEqual(try store.events().count, 2)
        try FileManager.default.removeItem(at: store.fileURL)
        XCTAssertEqual(try store.events(), [])
        let c = ev(.opened, 100, file: "c.md")
        store.record(c)
        store.flush()
        XCTAssertEqual(try store.events().map(\.id), [c.id])
    }

    func testReplacementResetsCache() throws {
        let store = makeStore()
        opens(["a.md", "b.md"]).forEach(store.record)
        store.flush()
        XCTAssertEqual(try store.events().count, 2)

        // Replaced wholesale (a sync tool, an editor's atomic save): new inode, longer file.
        let replacement = """
        {"at":"2026-10-14T21:00:00Z","kind":"opened","file":"x.md"}
        {"at":"2026-10-14T21:00:10Z","kind":"opened","file":"y.md"}
        {"at":"2026-10-14T21:00:20Z","kind":"opened","file":"z.md"}
        {"at":"2026-10-14T21:00:30Z","kind":"searched","text":"a much longer line than before, to grow the file"}

        """
        try Data(replacement.utf8).write(to: store.fileURL, options: .atomic)
        let after = try store.events()
        XCTAssertEqual(after.compactMap(\.file), [ref("x.md"), ref("y.md"), ref("z.md")])
        XCTAssertEqual(after.count, 4)
    }

    func testEventsSinceFilters() throws {
        let store = makeStore()
        let events = opens(["a.md", "b.md", "c.md"])
        events.forEach(store.record)
        XCTAssertEqual(try store.events(since: trailBase.addingTimeInterval(10)).map(\.id), [events[1].id, events[2].id])
        store.flush()
        XCTAssertEqual(try store.events(since: trailBase.addingTimeInterval(10)).map(\.id), [events[1].id, events[2].id])
        XCTAssertEqual(try store.events(since: trailBase.addingTimeInterval(25)).map(\.id), [events[2].id])
        XCTAssertEqual(try store.events(since: trailBase.addingTimeInterval(1000)), [])
        XCTAssertEqual(try store.events(since: nil).count, 3)
    }

    func testEventsAreSortedByTime() throws {
        let store = makeStore()
        let late = ev(.opened, 100, file: "late.md"), early = ev(.opened, 0, file: "early.md")
        store.record(late); store.flush()
        store.record(early)
        XCTAssertEqual(try store.events().map(\.id), [early.id, late.id])
    }

    func testHandWrittenDuplicateIdsAreMadeUnique() throws {
        let line = #"{"at":"2026-10-14T20:05:12Z","kind":"opened","file":"a.md"}"#
        try writeTrailFile(line + "\n" + line + "\n")
        let events = try makeStore().events()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events.map(\.id)).count, 2)
        XCTAssertEqual(try makeStore().events().map(\.id), events.map(\.id), "stable across reloads")
    }

    // MARK: Duplicates

    func testSameCommentRecordedTwiceIsKeptOnce() throws {
        let store = makeStore()
        let comment = Comment(timestamp: trailBase, anchor: FileAnchor(kind: .slide, value: "7"), text: "Pricing is off")
        store.recordComment(comment, on: ref("decks/q3.pptx"))
        store.recordComment(comment, on: ref("decks/q3.pptx"))
        let events = try store.events()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].id, comment.id)
        XCTAssertEqual(events[0].at, trailBase)
        XCTAssertEqual(events[0].anchor, comment.anchor)
        XCTAssertEqual(events[0].text, "Pricing is off")
    }

    func testRepeatedOpenWithinTwoSecondsIsDropped() throws {
        let store = makeStore()
        let slide7 = FileAnchor(kind: .slide, value: "7")
        store.record(ev(.opened, 0, file: "q3.pptx", anchor: slide7))
        store.record(ev(.opened, 1.5, file: "q3.pptx", anchor: slide7))       // duplicate
        store.record(ev(.opened, 1.6, file: "q3.pptx", anchor: FileAnchor(kind: .slide, value: "8")))
        store.record(ev(.opened, 1.7, file: "other.pptx", anchor: FileAnchor(kind: .slide, value: "8")))
        store.record(ev(.opened, 10, file: "other.pptx", anchor: FileAnchor(kind: .slide, value: "8")))
        XCTAssertEqual(try store.events().map(\.at), [0, 1.6, 1.7, 10].map { trailBase.addingTimeInterval($0) })
    }

    func testRecordOpenedHelperDeduplicates() throws {
        let store = makeStore()
        store.recordOpened(ref("a.md"))
        store.recordOpened(ref("a.md"))
        store.recordOpened(ref("a.md"), anchor: FileAnchor(kind: .line, value: "40"))
        XCTAssertEqual(try store.events().count, 2)
    }

    func testIsDuplicateRules() {
        let a = ev(.searched, 0, text: "churn")
        XCTAssertTrue(TrailStore.isDuplicate(ev(.searched, 1.9, text: "churn"), of: a))
        XCTAssertFalse(TrailStore.isDuplicate(ev(.searched, 2.1, text: "churn"), of: a))
        XCTAssertFalse(TrailStore.isDuplicate(ev(.searched, 1, text: "churn rate"), of: a))

        let c = ev(.commented, 0, file: "a.md", text: "hm")
        XCTAssertTrue(TrailStore.isDuplicate(ev(.commented, 9, file: "a.md", text: "hm"), of: c))
        XCTAssertFalse(TrailStore.isDuplicate(ev(.commented, 11, file: "a.md", text: "hm"), of: c))
        XCTAssertFalse(TrailStore.isDuplicate(ev(.commented, 1, file: "b.md", text: "hm"), of: c))

        let l = ev(.linked, 0, file: "a.md", text: "b.md")
        XCTAssertTrue(TrailStore.isDuplicate(ev(.linked, 1, file: "a.md", text: "b.md"), of: l))
        XCTAssertFalse(TrailStore.isDuplicate(ev(.linked, 1, file: "a.md", text: "c.md"), of: l))

        // Same id is always a duplicate, whatever else changed.
        XCTAssertTrue(TrailStore.isDuplicate(ev(.commented, 3600, file: "a.md", text: "edited", id: c.id), of: c))
        XCTAssertFalse(TrailStore.isDuplicate(ev(.opened, 0, file: "a.md"), of: ev(.searched, 0, text: "a.md")))
    }

    // MARK: Sanitization

    func testUnsafePathsAreNotRecorded() throws {
        for bad in ["/Users/me/secret.txt", "~/secret.txt", "../outside.md", "notes/../../outside.md",
                    ".flamingo/trail.jsonl", ".flamingo", ""] {
            XCTAssertNil(TrailStore.sanitized(ev(.opened, 0, file: bad)), bad)
            XCTAssertNil(TrailStore.sanitized(ev(.commented, 0, file: bad, text: "x")), bad)
        }
        let store = makeStore()
        store.record(ev(.opened, 0, file: "/etc/passwd"))
        store.record(ev(.opened, 10, file: "../x.md"))
        store.record(ev(.linked, 20, file: ".flamingo/notes/a.md", text: "b.md"))
        store.flush()
        XCTAssertEqual(try store.events(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))

        // Dots inside names are fine.
        XCTAssertNotNil(TrailStore.sanitized(ev(.opened, 0, file: "notes/..hidden..md")))
        XCTAssertNotNil(TrailStore.sanitized(ev(.opened, 0, file: "notes/.flamingo-ideas.md")))
    }

    func testOpenedEventsDropText() throws {
        let store = makeStore()
        store.record(ev(.opened, 0, file: "a.md", text: "the whole file contents"))
        let events = try store.events()
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events[0].text)
    }

    func testEventsWithoutContentAreNotRecorded() {
        XCTAssertNil(TrailStore.sanitized(ev(.searched, 0, text: "")))
        XCTAssertNil(TrailStore.sanitized(ev(.searched, 0, text: "  \n\t ")))
        XCTAssertNil(TrailStore.sanitized(ev(.searched, 0)))
        XCTAssertNil(TrailStore.sanitized(ev(.commented, 0, file: "a.md", text: "   ")))
        XCTAssertNil(TrailStore.sanitized(ev(.commented, 0, file: "a.md")))
        XCTAssertNil(TrailStore.sanitized(ev(.commented, 0, text: "orphan comment")))
        XCTAssertNil(TrailStore.sanitized(ev(.linked, 0, file: "a.md")))
        XCTAssertNil(TrailStore.sanitized(ev(.opened, 0)))
    }

    func testTextIsTrimmedAndCapped() {
        XCTAssertEqual(TrailStore.sanitized(ev(.searched, 0, text: "  churn \n"))?.text, "churn")
        XCTAssertEqual(TrailStore.sanitized(ev(.linked, 0, file: "a.md", text: " b.md "))?.text, "b.md")
        XCTAssertEqual(TrailStore.sanitized(ev(.commented, 0, file: "a.md", text: "  indented\n"))?.text, "  indented\n")
        let huge = String(repeating: "x", count: 10_000)
        XCTAssertEqual(TrailStore.sanitized(ev(.commented, 0, file: "a.md", text: huge))?.text?.count, 4000)
    }

    func testEmptySearchIsNotRecorded() throws {
        let store = makeStore()
        store.recordSearch("")
        store.recordSearch("   ")
        store.recordSearch(" churn ")
        XCTAssertEqual(try store.events().map(\.text), ["churn"])
    }

    // MARK: Privacy

    func testDisabledTrailRecordsNothing() throws {
        TrailStore.isEnabled = false
        XCTAssertEqual(UserDefaults.standard.object(forKey: "trailEnabled") as? Bool, false)
        let store = makeStore()
        store.recordOpened(ref("a.md"))
        store.recordSearch("churn")
        store.recordLink(from: ref("a.md"), to: "b.md")
        store.recordComment(Comment(text: "hm"), on: ref("a.md"))
        store.record(ev(.opened, 0, file: "b.md"))
        store.flush()
        XCTAssertEqual(try store.events(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))

        TrailStore.isEnabled = true
        store.recordOpened(ref("a.md"))
        XCTAssertEqual(try store.events().count, 1)
    }

    func testEnabledByDefault() {
        UserDefaults.standard.removeObject(forKey: TrailStore.enabledDefaultsKey)
        XCTAssertTrue(TrailStore.isEnabled)
    }

    // MARK: Sessions and edges through the store

    func testSessionsFromStore() throws {
        let store = makeStore()
        (opens(["a.md", "b.md"]) + opens(["c.md"], from: 3600)).forEach(store.record)
        let sessions = try store.sessions()
        XCTAssertEqual(sessions.map { paths($0.files) }, [["a.md", "b.md"], ["c.md"]])
    }

    func testEdgesDropFilesThatNoLongerExist() throws {
        try touch("a.md")
        try touch("notes/b.md")
        let store = makeStore()
        let base = Date().addingTimeInterval(-600)
        opens(["a.md", "notes/b.md", "gone.md"], base: base).forEach(store.record)
        let edges = try store.edges()
        XCTAssertEqual(edges.map { [$0.source, $0.target] }, [["a.md", "notes/b.md"]])
        XCTAssertEqual(edges.first?.kind, .trail)
        XCTAssertEqual(edges.first?.weight ?? 0, 1, accuracy: 0.001)
    }

    // MARK: Names

    func testNamedSessionCarriesTitle() throws {
        let store = makeStore()
        opens(["a.md", "b.md"]).forEach(store.record)
        let session = try XCTUnwrap(try store.sessions().first)
        XCTAssertNil(session.title)

        try store.setTitle("  Q3 pricing / model  ", for: session)
        XCTAssertEqual(try store.sessions().first?.title, "Q3 pricing / model")
        XCTAssertEqual(store.title(for: session), "Q3 pricing / model")

        // The name sticks as the session grows, and survives a new store.
        store.record(ev(.opened, 100, file: "c.md"))
        store.flush()
        let reloaded = try TrailStore(vault: vault).sessions()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded[0].id, session.id)
        XCTAssertEqual(reloaded[0].title, "Q3 pricing / model")
    }

    func testBlankTitleRemovesName() throws {
        let store = makeStore()
        opens(["a.md"]).forEach(store.record)
        let session = try XCTUnwrap(try store.sessions().first)
        try store.setTitle("Chain", for: session)
        XCTAssertEqual(store.names().count, 1)
        try store.setTitle("   \n", for: session)
        XCTAssertNil(try store.sessions().first?.title)
        XCTAssertEqual(store.names(), [:])
        try store.setTitle("Again", for: session)
        try store.setTitle(nil, for: session)
        XCTAssertEqual(store.names(), [:])
    }

    func testNamesFileIsPrettySortedJSON() throws {
        let store = makeStore()
        (opens(["a.md"]) + opens(["b.md"], from: 3600) + opens(["c.md"], from: 7200)).forEach(store.record)
        let sessions = try store.sessions()
        XCTAssertEqual(sessions.count, 3)
        for (i, s) in sessions.enumerated() { try store.setTitle("chain \(i) a/b", for: s) }

        let text = String(decoding: try Data(contentsOf: store.namesURL), as: UTF8.self)
        XCTAssertTrue(text.contains("\n  \""), "pretty printed")
        XCTAssertFalse(text.contains(#"\/"#))
        let keys = sessions.map(\.id.uuidString).sorted()
        let positions = keys.map { text.range(of: $0)!.lowerBound }
        XCTAssertEqual(positions, positions.sorted(), "keys are sorted")
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(text.utf8)).count, 3)
    }

    func testHandWrittenTrailKeepsNamesAcrossReloads() throws {
        // No ids in the file: session ids are derived from content, so names still stick.
        try writeTrailFile("""
        {"at":"2026-10-14T20:05:12Z","kind":"opened","file":"a.md"}
        {"at":"2026-10-14T20:05:30Z","kind":"opened","file":"b.md"}

        """)
        let session = try XCTUnwrap(try makeStore().sessions().first)
        try makeStore().setTitle("Hand made", for: session)
        XCTAssertEqual(try makeStore().sessions().first?.title, "Hand made")
    }

    func testCorruptNamesFileIsIgnored() throws {
        let store = makeStore()
        opens(["a.md"]).forEach(store.record)
        try FileManager.default.createDirectory(at: vault.stateDir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.namesURL)
        XCTAssertEqual(store.names(), [:])
        XCTAssertNil(try store.sessions().first?.title)
        let session = try XCTUnwrap(try store.sessions().first)
        try store.setTitle("Recovered", for: session)
        XCTAssertEqual(try store.sessions().first?.title, "Recovered")
    }
}
