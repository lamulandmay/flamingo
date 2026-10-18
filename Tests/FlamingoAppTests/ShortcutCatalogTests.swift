import AppKit
import XCTest
@testable import Flamingo

@MainActor
final class ShortcutCatalogTests: XCTestCase {
    private let groups = ShortcutCatalog.groups()

    private var everyKey: Set<String> {
        Set(groups.filter { !$0.isPrimer }.flatMap(\.items).flatMap(\.keys))
    }

    /// A key added to the menu bar without a line in Help ▸ Keyboard Shortcuts fails here.
    func testEveryMenuShortcutIsListed() throws {
        let app = NSApplication.shared   // sets NSApp, which a test run otherwise leaves nil
        let saved = app.mainMenu
        defer { app.mainMenu = saved }
        MainMenu.install()
        var missing: [String] = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let keys = ShortcutCatalog.symbols(of: item), !everyKey.contains(keys) {
                    missing.append("\(keys) \(item.title)")
                }
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(try XCTUnwrap(app.mainMenu))
        XCTAssertEqual(missing, [])
    }

    func testMenuSymbolsUseApplesModifierOrder() {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "1")
        item.keyEquivalentModifierMask = [.command, .option, .control]
        XCTAssertEqual(ShortcutCatalog.symbols(of: item), "⌃⌥⌘1")
        let down = NSMenuItem(title: "", action: nil, keyEquivalent: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)))
        down.keyEquivalentModifierMask = [.option]
        XCTAssertEqual(ShortcutCatalog.symbols(of: down), "⌥↓")
        let thought = NSMenuItem(title: "", action: nil, keyEquivalent: "c")
        thought.keyEquivalentModifierMask = [.command, .shift]
        XCTAssertEqual(ShortcutCatalog.symbols(of: thought), "⇧⌘C")
        XCTAssertNil(ShortcutCatalog.symbols(of: NSMenuItem(title: "", action: nil, keyEquivalent: "")))
    }

    func testEmptyFilterShowsEverythingWithThePrimerFirst() {
        let shown = ShortcutCatalog.filter(groups, "  ")
        XCTAssertEqual(shown, groups)
        XCTAssertTrue(shown.first?.isPrimer == true)
    }

    func testFilterMatchesEveryWordAndDropsThePrimer() {
        let shown = ShortcutCatalog.filter(groups, "quick look")
        XCTAssertFalse(shown.isEmpty)
        XCTAssertFalse(shown.contains { $0.isPrimer })
        XCTAssertTrue(shown.flatMap(\.items).allSatisfy { $0.action.lowercased().contains("quick look") })
    }

    func testKeyWordsMatchTheirSymbols() {
        let shown = ShortcutCatalog.filter(groups, "shift cmd c").flatMap(\.items)
        XCTAssertTrue(shown.contains { $0.keys.contains("⇧⌘C") })
    }

    func testAGroupTitleKeepsItsRows() {
        let graph = ShortcutCatalog.filter(groups, "graph").first { $0.title == "Graph" }
        XCTAssertEqual(graph?.items.count, groups.first { $0.title == "Graph" }?.items.count)
    }

    func testNothingMatchesNonsense() {
        XCTAssertEqual(ShortcutCatalog.filter(groups, "zzzqqq"), [])
    }

    func testCaptureKeysFollowTheRegisteredShortcut() {
        let keys = ShortcutCatalog.groups(captureKeys: "⌃⌥⌘Space").flatMap(\.items).flatMap(\.keys)
        XCTAssertTrue(keys.contains("⌃⌥⌘Space"))
    }
}
