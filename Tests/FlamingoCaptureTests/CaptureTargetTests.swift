import XCTest
@testable import FlamingoCapture
import FlamingoCore

final class CaptureTargetTests: XCTestCase {
    private func vault() throws -> Vault {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flamingo-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return Vault(root: dir)
    }

    func testBrowserWithNoVaultFileCapturesToAWebNote() throws {
        let v = try vault()
        let url = URL(string: "https://www.example.com/pricing/plans?x=1")!
        var ctx = FrontmostContext(appBundleID: "com.apple.Safari", windowTitle: "Plans and pricing")
        ctx.sourceURL = url
        let target = try XCTUnwrap(CaptureController.Target.forFrontmost(ctx, vaults: [v]))
        XCTAssertTrue(target.file.isWeb)
        XCTAssertEqual(target.file, WebThought.ref(for: url.absoluteString, title: "Plans and pricing"))
        XCTAssertEqual(target.frontmatter["url"], url.absoluteString)
        XCTAssertEqual(target.frontmatter["title"], "Plans and pricing")
        XCTAssertEqual(target.label, "Plans and pricing")
        XCTAssertEqual(target.provenance?.sourceURL, url.absoluteString)

        // The note is written with that front matter.
        try SidecarStore(vault: v).append(Comment(text: "Compare with ours").stamped(), to: target.file, frontmatter: target.frontmatter)
        let doc = try XCTUnwrap(try SidecarStore(vault: v).document(for: target.file))
        XCTAssertEqual(doc.frontmatterValue(for: "url"), url.absoluteString)
        XCTAssertEqual(doc.comments.count, 1)
        XCTAssertNotNil(doc.comments.first?.uid)
    }

    func testAVaultFileWinsOverItsSourceURL() throws {
        let v = try vault()
        var ctx = FrontmostContext(appBundleID: "com.apple.Preview", documentURL: v.root.appendingPathComponent("a.pdf"),
                                   anchor: FileAnchor(kind: .page, value: "3"), vault: v, file: FileRef(relativePath: "a.pdf"))
        ctx.sourceURL = URL(string: "https://example.com/a.pdf")
        let target = try XCTUnwrap(CaptureController.Target.forFrontmost(ctx, vaults: [v]))
        XCTAssertEqual(target.file, FileRef(relativePath: "a.pdf"))
        XCTAssertEqual(target.anchor, FileAnchor(kind: .page, value: "3"))
        XCTAssertTrue(target.frontmatter.isEmpty)
    }

    func testOtherDocumentsAndNoContextGoToTheInbox() throws {
        let v = try vault()
        let day = Date(timeIntervalSince1970: 1_760_000_000)
        var ctx = FrontmostContext(appBundleID: "com.apple.TextEdit", documentURL: URL(fileURLWithPath: "/tmp/outside.txt"))
        ctx.sourceURL = ctx.documentURL
        let a = try XCTUnwrap(CaptureController.Target.forFrontmost(ctx, vaults: [v], date: day))
        XCTAssertTrue(a.file.isInbox)
        XCTAssertTrue(a.frontmatter.isEmpty)
        XCTAssertTrue(try XCTUnwrap(CaptureController.Target.forFrontmost(nil, vaults: [v], date: day)).file.isInbox)
        XCTAssertNil(CaptureController.Target.forFrontmost(ctx, vaults: []))
    }

    func testSelectionBecomesQuoteLines() throws {
        let v = try vault()
        var ctx = FrontmostContext(appBundleID: "com.apple.Safari", windowTitle: "Page")
        ctx.sourceURL = URL(string: "https://example.com/a")
        ctx.selectedText = "  Margins fell\r\nto 31%.\n\n\n\nSee table 2  \n"
        let target = try XCTUnwrap(CaptureController.Target.forFrontmost(ctx, vaults: [v]))
        XCTAssertEqual(target.quote, "> Margins fell\n> to 31%.\n>\n> See table 2")
        XCTAssertEqual(ThoughtQuote.compose(quote: target.quote, text: "Check this"), "> Margins fell\n> to 31%.\n>\n> See table 2\n\nCheck this")
        ctx.selectedText = "   \n "
        XCTAssertNil(CaptureController.Target.forFrontmost(ctx, vaults: [v])?.quote)
    }

    func testSelectionIsCutAtTwoThousandCharacters() {
        let lines = ThoughtQuote.lines(from: String(repeating: "x", count: 5_000))
        XCTAssertEqual(lines?.count, 2 + 2_000)
        XCTAssertNil(ThoughtQuote.lines(from: nil))
    }

    func testQuotedThoughtSurvivesTheNoteAndIsNotWhatWasSaid() throws {
        let v = try vault()
        let text = ThoughtQuote.compose(quote: "> one\n>\n> two", text: "Why 31%?")
        try SidecarStore(vault: v).append(Comment(text: text).stamped(), to: FileRef(relativePath: "a.pdf"))
        let back = try XCTUnwrap(try SidecarStore(vault: v).comments(for: FileRef(relativePath: "a.pdf")).first)
        XCTAssertEqual(back.text, text)
        XCTAssertEqual(ThoughtRules.prose(of: back.text), "Why 31%?")
    }

    func testFolderTargetIsTheFolderNote() throws {
        let v = try vault()
        let note = try XCTUnwrap(ThoughtNote.folder(FileRef(relativePath: "decks/")))
        XCTAssertEqual(note.file.relativePath, "decks")
        XCTAssertEqual(note.frontmatter, ["subject": "folder"])
        XCTAssertEqual(note.name, "decks")
        XCTAssertTrue(note.isFolder)
        XCTAssertNil(ThoughtNote.folder(FileRef(relativePath: "")))
        XCTAssertNil(ThoughtNote.folder(FileRef(relativePath: ".flamingo/notes")))

        let target = CaptureController.Target(vault: v, note: note)
        XCTAssertTrue(target.isFolder)
        XCTAssertEqual(target.label, "decks")
        try SidecarStore(vault: v).append(Comment(text: "Retire the old decks").stamped(), to: target.file, frontmatter: target.frontmatter)
        XCTAssertTrue(FileManager.default.fileExists(atPath: v.notesDir.appendingPathComponent("decks.md").path))
        let doc = try XCTUnwrap(try SidecarStore(vault: v).document(for: target.file))
        XCTAssertTrue(doc.isFolderNote)
    }

    func testWebNoteNeedsAnHTTPURL() {
        XCTAssertNil(ThoughtNote.web(url: "file:///tmp/a.html", title: "a"))
        XCTAssertNil(ThoughtNote.web(url: "not a url", title: nil))
        XCTAssertEqual(ThoughtNote.web(url: "https://example.com/x", title: nil)?.name, "example.com")
    }

    func testAnsweringEchoedThoughtSetsParent() {
        let c = Comment(text: "Same worry again").replying(toUID: "tabc123xyz")
        XCTAssertEqual(c.meta?.parent, "tabc123xyz")
        XCTAssertNotNil(c.uid)
    }
}
