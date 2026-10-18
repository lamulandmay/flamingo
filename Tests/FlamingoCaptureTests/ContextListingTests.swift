import XCTest
import FlamingoCore
@testable import FlamingoCapture

final class ContextListingTests: XCTestCase {
    func testOnlyListedFilesAttach() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("listing-\(UUID().uuidString)")
        let fm = FileManager.default
        for dir in ["decks", "deck.key", ".git", "node_modules/x", ".config", ".flamingo/notes", "build"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for f in ["decks/q3.pptx", ".hidden.md", ".config/app.toml", ".git/config", "node_modules/x/a.js",
                  ".flamingo/notes/q3.pptx.md", "build/out.txt"] {
            fm.createFile(atPath: root.appendingPathComponent(f).path, contents: Data("x".utf8))
        }
        defer { try? fm.removeItem(at: root) }
        func listed(_ rel: String) -> Bool { FrontmostContext.isListed(root.appendingPathComponent(rel), relativePath: rel) }

        XCTAssertTrue(listed("decks/q3.pptx"))
        XCTAssertFalse(listed("decks"), "a Finder folder window is not a file")
        XCTAssertTrue(listed(".hidden.md"), "the scanner lists hidden files, so thoughts can attach to them")
        XCTAssertTrue(listed(".config/app.toml"))
        XCTAssertFalse(listed(".flamingo/notes/q3.pptx.md"), "Flamingo's own notes are never a subject")
        XCTAssertFalse(listed(".git/config"))
        XCTAssertTrue(listed("build/out.txt"))
        XCTAssertFalse(FrontmostContext.isListed(root.appendingPathComponent("build/out.txt"), relativePath: "build/out.txt",
                                                 ignore: IgnoreRules(text: "build/")), "the vault's ignore rules apply")
        XCTAssertFalse(listed("node_modules/x/a.js"))
        XCTAssertFalse(listed("decks/missing.pptx"))
        // `.key` is only a package when Launch Services knows the type; either way it must not crash.
        _ = listed("deck.key")
    }

    func testTitleFallbackOnlyForEditors() {
        XCTAssertTrue(FrontmostContext.titleFallbackApps("com.microsoft.VSCode"))
        XCTAssertTrue(FrontmostContext.titleFallbackApps("com.jetbrains.intellij"))
        XCTAssertFalse(FrontmostContext.titleFallbackApps("com.apple.Safari"))
        XCTAssertFalse(FrontmostContext.titleFallbackApps("com.google.Chrome"))
    }
}
