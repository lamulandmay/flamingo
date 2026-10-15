import XCTest
import FlamingoCore
@testable import FlamingoIndex

final class TitleTests: XCTestCase {
    var root: URL!
    var store: IndexStore!
    let asked = Counter()

    final class Counter: @unchecked Sendable { var paths: [String] = [] }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("titles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("tools/fc.py", "# Forecast monthly unit sales from waitlist conversion\ndef forecast(waitlist, conv=0.08):\n    return waitlist * conv\n")
        try write("notes/plan.md", "Launch plan notes, long enough to be worth a title if we asked.")
        try write("tiny.py", "x = 1")
        store = try IndexStore(vault: Vault(root: root))
        let asked = asked
        store.embedding.titler.fake = { path, _ in
            asked.paths.append(path)
            return ("waitlist sales forecast.", ["Python", "forecast", "forecast", "sales!"])
        }
        try store.reindex()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testTitlesCodeAndSkipsSelfTitledAndTinyFiles() throws {
        XCTAssertEqual(store.titlePending(), 1)
        XCTAssertEqual(asked.paths, ["tools/fc.py"], "markdown names itself; tiny.py has too little text to ask about")
        XCTAssertEqual(try store.tags(of: FileRef(relativePath: "tools/fc.py")), ["python", "forecast", "sales"])
        XCTAssertEqual(store.titlePending(), 0, "each file is asked once")
        XCTAssertEqual(asked.paths.count, 1)
    }

    func testTitleAndTagsAreSearchable() throws {
        store.titlePending()
        XCTAssertEqual(try store.search("python", limit: 5).first?.file.relativePath, "tools/fc.py")
        XCTAssertEqual(try store.search("Waitlist sales forecast", limit: 5).first?.file.relativePath, "tools/fc.py")
    }

    func testOllamaDownMarksNothing() throws {
        store.embedding.titler.fake = { _, _ in nil }
        XCTAssertEqual(store.titlePending(), 0)
        store.embedding.titler.fake = { _, _ in ("Forecast", ["a", "b", "c"]) }
        XCTAssertEqual(store.titlePending(), 1, "tried again next time")
    }

    func testEditingTheFileAsksAgain() throws {
        store.titlePending()
        try write("tools/fc.py", "# Forecast churn by cohort from the retention table, then plot it\nprint(1)\n")
        try store.update([FileRef(relativePath: "tools/fc.py")])
        XCTAssertEqual(store.titlePending(), 1)
        XCTAssertEqual(asked.paths, ["tools/fc.py", "tools/fc.py"])
    }

    func testRenameKeepsTheTitle() throws {
        // A file someone commented on carries an identity, so a rename keeps its row.
        _ = try FileIdentity.id(for: root.appendingPathComponent("tools/fc.py"))
        try store.update([FileRef(relativePath: "tools/fc.py")])
        store.titlePending()
        try FileManager.default.moveItem(at: root.appendingPathComponent("tools/fc.py"), to: root.appendingPathComponent("tools/forecast.py"))
        try store.update([FileRef(relativePath: "tools/fc.py"), FileRef(relativePath: "tools/forecast.py")])
        XCTAssertEqual(try store.tags(of: FileRef(relativePath: "tools/forecast.py")), ["python", "forecast", "sales"])
        XCTAssertEqual(store.titlePending(), 0)
    }

    func testCleanRejectsTheFileName() {
        XCTAssertThrowsError(try Titler.clean("fc", [], path: "tools/fc.py"))
        XCTAssertEqual(try Titler.clean("  \"arc render\" ", [], path: "a.png").title, "Arc render")
    }
}
