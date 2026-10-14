import XCTest
@testable import FlamingoCore

final class ReconcileTests: XCTestCase {
    var tv: TempVault!
    var store: SidecarStore!

    override func setUpWithError() throws {
        tv = try TempVault(name)
        store = SidecarStore(vault: tv.vault)
    }

    override func tearDown() { FileIdentity.invalidateCache(for: tv.vault); tv.destroy() }

    func testSidecarFollowsRenamedFile() throws {
        let old = try tv.file("decks/q3.pptx")
        try store.append(Comment(timestamp: ts("2026-10-14 22:05"), anchor: FileAnchor(kind: .slide, value: "7"), text: "Keep me"), to: old)
        let id = try XCTUnwrap(try store.document(for: old)?.id)

        try tv.rename("decks/q3.pptx", to: "archive/2026/q3-final.pptx")
        let new = FileRef(relativePath: "archive/2026/q3-final.pptx")
        XCTAssertEqual(try store.comments(for: new), [], "not yet")

        let moves = try store.reconcile()
        XCTAssertEqual(moves, [SidecarStore.Move(from: old, to: new)])
        XCTAssertFalse(store.hasSidecar(for: old))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tv.vault.notesDir.appendingPathComponent("decks").path), "empty folder pruned")
        XCTAssertEqual(try tv.contents(ofSidecarFor: new.relativePath),
                       "---\ntarget: archive/2026/q3-final.pptx\nid: \(id.uuidString)\n---\n- [2026-10-14 22:05] (slide 7) Keep me\n")
        XCTAssertEqual(try store.reconcile(), [], "second pass is a no-op")
    }

    func testOrphansWithoutAHomeStay() throws {
        let gone = try tv.file("gone.txt")
        try store.append(Comment(text: "x"), to: gone)
        try tv.remove("gone.txt")
        let noID = FileRef(relativePath: "never-existed.txt")
        try store.append(Comment(text: "y"), to: noID)
        XCTAssertEqual(try store.reconcile(), [])
        XCTAssertEqual(Set(try store.all().keys), [gone, noID])
    }

    func testExistingTargetsAreLeftAlone() throws {
        let a = try tv.file("a.txt")
        try store.append(Comment(text: "x"), to: a)
        let before = try tv.contents(ofSidecarFor: "a.txt")
        XCTAssertEqual(try store.reconcile(), [])
        XCTAssertEqual(try tv.contents(ofSidecarFor: "a.txt"), before)
    }

    func testRenameOntoFileThatAlreadyHasANoteMerges() throws {
        let a = try tv.file("a.txt")
        let b = try tv.file("b.txt")
        try store.append(Comment(timestamp: ts("2026-10-14 22:05"), text: "about a"), to: a)
        try store.append(Comment(timestamp: ts("2026-10-14 22:06"), text: "about b"), to: b)
        try tv.remove("b.txt")
        try tv.rename("a.txt", to: "b.txt")
        XCTAssertEqual(try store.reconcile(), [SidecarStore.Move(from: a, to: b)])
        XCTAssertEqual(try store.comments(for: b).map(\.text), ["about b", "about a"])
        XCTAssertFalse(store.hasSidecar(for: a))
    }

    func testSeveralRenamesHealInOnePass() throws {
        var refs: [FileRef] = []
        for i in 0..<5 {
            let r = try tv.file("f\(i).txt")
            try store.append(Comment(text: "n\(i)"), to: r)
            refs.append(r)
        }
        for i in 0..<5 { try tv.rename("f\(i).txt", to: "moved/g\(i).txt") }
        let moves = try store.reconcile()
        XCTAssertEqual(moves.count, 5)
        for i in 0..<5 {
            XCTAssertEqual(try store.comments(for: FileRef(relativePath: "moved/g\(i).txt")).map(\.text), ["n\(i)"])
        }
    }
}
