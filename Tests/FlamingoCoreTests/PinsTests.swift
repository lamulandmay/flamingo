import XCTest
@testable import FlamingoCore

final class PinsTests: XCTestCase {
    private var root: URL = URL(fileURLWithPath: "/dev/null")
    private var vault: Vault { Vault(root: root) }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("PinsTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func mkdir(_ rel: String) throws {
        try fm.createDirectory(at: root.appendingPathComponent(rel), withIntermediateDirectories: true)
    }

    func testFirstRunPinsDesktopDocumentsDownloadsThatExist() throws {
        try mkdir("Downloads")
        try mkdir("Desktop")
        try "x".write(to: root.appendingPathComponent("Documents"), atomically: true, encoding: .utf8)   // a file, not a folder
        XCTAssertNil(Pins.load(in: vault))
        XCTAssertEqual(Pins.loadOrCreate(in: vault).paths, ["Desktop", "Downloads"])
        XCTAssertEqual(Pins.load(in: vault)?.paths, ["Desktop", "Downloads"], "saved on first run")
    }

    func testFirstRunInAProjectFolderPinsTheRoot() {
        XCTAssertEqual(Pins.loadOrCreate(in: vault).paths, [""])
    }

    func testAnEmptyListStaysEmpty() throws {
        try mkdir("Desktop")
        try Pins().save(in: vault)
        XCTAssertEqual(Pins.loadOrCreate(in: vault).paths, [])
    }

    func testFileIsAPlainJSONArray() throws {
        try Pins(["Documents", "code/flamingo"]).save(in: vault)
        let text = try String(contentsOf: vault.pinsURL, encoding: .utf8)
        XCTAssertEqual(text, "[\n  \"Documents\",\n  \"code/flamingo\"\n]\n")
        try "[\"a\", \"/b/\", \"a\"]".write(to: vault.pinsURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(Pins.load(in: vault)?.paths, ["a", "b"])
        try "{\"nope\": 1}".write(to: vault.pinsURL, atomically: true, encoding: .utf8)
        XCTAssertNil(Pins.load(in: vault))
    }

    func testPinUnpinMoveAndUndo() {
        var pins = Pins(["a", "b", "c"])
        XCTAssertFalse(pins.pin("b/"))
        XCTAssertTrue(pins.pin("d", at: 1))
        XCTAssertEqual(pins.paths, ["a", "d", "b", "c"])
        let i = pins.unpin("d")
        XCTAssertEqual(i, 1)
        XCTAssertNil(pins.unpin("zzz"))
        pins.pin("d", at: i)
        XCTAssertEqual(pins.paths, ["a", "d", "b", "c"])
        pins.move(from: 0, to: 3)
        XCTAssertEqual(pins.paths, ["d", "b", "c", "a"])
        pins.move(from: 3, to: 0)
        XCTAssertEqual(pins.paths, ["a", "d", "b", "c"])
        pins.move(from: 9, to: 0)
        XCTAssertEqual(pins.paths, ["a", "d", "b", "c"])
        XCTAssertTrue(pins.contains("/a"))
        XCTAssertTrue(pins.pin("z", at: 99))
        XCTAssertEqual(pins.paths.last, "z")
    }

    func testRenameRetargetsPinsInsideTheFolder() {
        var pins = Pins(["work", "work/q3", "workshop", "other"])
        pins.rename("work", to: "jobs/work")
        XCTAssertEqual(pins.paths, ["jobs/work", "jobs/work/q3", "workshop", "other"])
    }
}
