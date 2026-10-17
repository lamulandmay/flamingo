import XCTest
@testable import Flamingo
import FlamingoCore

final class NavigationTests: XCTestCase {
    @MainActor
    func testScopedQueryWithSpacesAndUnicode() {
        let result = SidebarSearchModel.split("path:\"Kestrel Works/研究/\" 定价策略")
        XCTAssertEqual(result.folder, "Kestrel Works/研究")
        XCTAssertEqual(result.text, "定价策略")
    }

    @MainActor
    func testHistoryRestorationKeepsCurrentPlaceAfterEarlierFileDisappears() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = Vault(root: root)
        for name in ["b.txt", "c.txt"] { try Data().write(to: root.appendingPathComponent(name)) }
        var history = History()
        for name in ["a.txt", "b.txt", "c.txt"] { history.push(.init(file: .init(relativePath: name), anchor: nil)) }
        _ = history.goBack()
        let restored = SavedHistory(history).restored(in: vault)
        XCTAssertEqual(restored.current?.file?.relativePath, "b.txt")
        XCTAssertTrue(restored.canGoForward)
    }

    @MainActor
    func testRecoveryDraftSurvivesConflictingSaveAndReopening() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = FileRef(relativePath: "working.md")
        let url = root.appendingPathComponent(file.relativePath)
        try Data("original".utf8).write(to: url)
        let vault = Vault(root: root)
        let editor = TextBuffer(file: file, vault: vault)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: editor.draftURL) }
        await editor.load()
        editor.changed("my recoverable thought")
        try Data("newer external save".utf8).write(to: url, options: .atomic)
        await editor.save()
        XCTAssertTrue(editor.dirty)
        XCTAssertNotNil(editor.error)
        XCTAssertEqual(try String(contentsOf: url), "newer external save")
        let reopened = TextBuffer(file: file, vault: vault)
        await reopened.load()
        XCTAssertEqual(reopened.text, "my recoverable thought")
        XCTAssertTrue(reopened.recovered)
        XCTAssertTrue(reopened.dirty)
        XCTAssertNotNil(reopened.error)
    }
}
