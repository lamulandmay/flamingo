import XCTest
import AppKit
@testable import FlamingoCapture
import FlamingoCore

final class ContextFormatTests: XCTestCase {
    func testTimecode() {
        XCTAssertEqual(AnchorFormat.timecode(0), "0:00")
        XCTAssertEqual(AnchorFormat.timecode(83.9), "1:23")
        XCTAssertEqual(AnchorFormat.timecode(599), "9:59")
        XCTAssertEqual(AnchorFormat.timecode(3600), "1:00:00")
        XCTAssertEqual(AnchorFormat.timecode(3723), "1:02:03")
        XCTAssertNil(AnchorFormat.timecode(-1))
        XCTAssertNil(AnchorFormat.timecode(.nan))
    }

    func testCellReference() {
        XCTAssertEqual(AnchorFormat.cellReference("Sheet1!$B$12"), "Sheet1!B12")
        XCTAssertEqual(AnchorFormat.cellReference("Q3!$B$12:$C$14"), "Q3!B12:C14")
        XCTAssertEqual(AnchorFormat.cellReference("$B$12"), "B12")
        XCTAssertEqual(AnchorFormat.cellReference("Cost$!$A$1"), "Cost$!A1")
        XCTAssertEqual(AnchorFormat.cellReference("Sheet 1!B12:C14"), "Sheet 1!B12:C14")
    }

    func testAnchorNormalization() {
        XCTAssertEqual(AnchorFormat.anchor(kind: "slide", value: "7"), FileAnchor(kind: .slide, value: "7"))
        XCTAssertEqual(AnchorFormat.anchor(kind: "page", value: "4.0"), FileAnchor(kind: .page, value: "4"))
        XCTAssertEqual(AnchorFormat.anchor(kind: "time", value: "83.4"), FileAnchor(kind: .time, value: "1:23"))
        XCTAssertEqual(AnchorFormat.anchor(kind: "cell", value: "Q3!$B$12"), FileAnchor(kind: .cell, value: "Q3!B12"))
        XCTAssertEqual(AnchorFormat.anchor(kind: "sheet", value: "Model"), FileAnchor(kind: .sheet, value: "Model"))
        XCTAssertEqual(AnchorFormat.anchor(kind: "line", value: "40"), FileAnchor(kind: .line, value: "40"))
        XCTAssertNil(AnchorFormat.anchor(kind: "slide", value: "0"))
        XCTAssertNil(AnchorFormat.anchor(kind: "slide", value: ""))
        XCTAssertNil(AnchorFormat.anchor(kind: "", value: "3"))
        XCTAssertNil(AnchorFormat.anchor(kind: "chapter", value: "3"))
        XCTAssertNil(AnchorFormat.anchor(kind: nil, value: nil))
    }

    func testNumber() {
        XCTAssertEqual(AnchorFormat.number(7), "7")
        XCTAssertEqual(AnchorFormat.number(83.5), "83.5")
        XCTAssertNil(AnchorFormat.number(.infinity))
    }

    func testPaths() {
        XCTAssertEqual(AnchorFormat.url(fromPath: "/Users/me/q3.key/", bootVolume: "Macintosh HD")?.path, "/Users/me/q3.key")
        XCTAssertEqual(AnchorFormat.url(fromPath: "file:///Users/me/a%20b.pdf", bootVolume: "Macintosh HD")?.path, "/Users/me/a b.pdf")
        XCTAssertEqual(AnchorFormat.url(fromPath: "Macintosh HD:Users:me:q3.pptx", bootVolume: "Macintosh HD")?.path,
                       "/Users/me/q3.pptx")
        XCTAssertEqual(AnchorFormat.url(fromPath: "Backup:decks:q3.pptx", bootVolume: "Macintosh HD")?.path,
                       "/Volumes/Backup/decks/q3.pptx")
        XCTAssertEqual(AnchorFormat.posixPath(fromHFS: "Macintosh HD:Users:me:a/b.txt", bootVolume: "Macintosh HD"),
                       "/Users/me/a:b.txt")
        XCTAssertEqual(AnchorFormat.posixPath(fromHFS: "Macintosh HD:Users:me:", bootVolume: "Macintosh HD"), "/Users/me")
        XCTAssertNil(AnchorFormat.url(fromPath: "Presentation1", bootVolume: "Macintosh HD"))
        XCTAssertNil(AnchorFormat.url(fromPath: "https://d.docs.live.net/abc/q3.pptx", bootVolume: "Macintosh HD"))
        XCTAssertNil(AnchorFormat.url(fromPath: "", bootVolume: "Macintosh HD"))
        XCTAssertNil(AnchorFormat.url(fromPath: nil, bootVolume: "Macintosh HD"))
    }

    func testPageFromTitle() {
        XCTAssertEqual(AnchorFormat.page(fromTitle: "report.pdf – Page 4 of 12"), FileAnchor(kind: .page, value: "4"))
        XCTAssertEqual(AnchorFormat.page(fromTitle: "report.pdf (page 10 of 200)"), FileAnchor(kind: .page, value: "10"))
        XCTAssertNil(AnchorFormat.page(fromTitle: "Homepage 4 of 12"))
        XCTAssertNil(AnchorFormat.page(fromTitle: "report.pdf"))
        XCTAssertNil(AnchorFormat.page(fromTitle: nil))
    }

    func testAXDocumentURL() {
        XCTAssertEqual(AXFrontmost.documentURL(from: "file:///Users/me/a%20b.key/")?.path, "/Users/me/a b.key")
        XCTAssertEqual(AXFrontmost.documentURL(from: "/Users/me/x.txt")?.path, "/Users/me/x.txt")
        XCTAssertNil(AXFrontmost.documentURL(from: "https://example.com/x.pdf"))
        XCTAssertNil(AXFrontmost.documentURL(from: ""))
    }

    func testAppKitFrame() {
        let f = AXFrontmost.appKitFrame(axOrigin: CGPoint(x: 100, y: 50), size: CGSize(width: 800, height: 600),
                                        primaryHeight: 1000)
        XCTAssertEqual(f, CGRect(x: 100, y: 350, width: 800, height: 600))
        // A window on a display above the primary one has a negative AX y.
        let above = AXFrontmost.appKitFrame(axOrigin: CGPoint(x: 0, y: -900), size: CGSize(width: 400, height: 300),
                                            primaryHeight: 1000)
        XCTAssertEqual(above, CGRect(x: 0, y: 1600, width: 400, height: 300))
    }

    func testEveryProbeReturnsATriple() {
        for (bid, probe) in AnchorScripts.probes {
            XCTAssertTrue(probe.source.contains("with timeout of 2 seconds"), bid)
            XCTAssertTrue(probe.source.contains("tell application id \"\(bid)\""), bid)
            XCTAssertTrue(probe.source.contains("return {p"), bid)
        }
    }

    func testScalarDescriptors() {
        XCTAssertEqual(AnchorScripts.scalar(NSAppleEventDescriptor(string: " B12 ")), "B12")
        XCTAssertNil(AnchorScripts.scalar(NSAppleEventDescriptor(string: "")))
        XCTAssertEqual(AnchorScripts.scalar(NSAppleEventDescriptor(int32: 7)), "7")
        XCTAssertEqual(AnchorScripts.scalar(NSAppleEventDescriptor(double: 83.5)), "83.5")
        XCTAssertEqual(AnchorScripts.scalar(NSAppleEventDescriptor(double: 12)), "12")
        XCTAssertNil(AnchorScripts.scalar(NSAppleEventDescriptor(typeCode: 0x6D73_6E67))) // 'msng' missing value
        XCTAssertNil(AnchorScripts.scalar(NSAppleEventDescriptor.null()))

        // `page 3 of document "x"` — an index-form object specifier.
        let page = NSAppleEventDescriptor.record().coerce(toDescriptorType: typeObjectSpecifier)!
        page.setDescriptor(NSAppleEventDescriptor(typeCode: 0x6350_6167), forKeyword: AEKeyword(keyAEDesiredClass)) // 'cPag'
        page.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formAbsolutePosition)), forKeyword: AEKeyword(keyAEKeyForm))
        page.setDescriptor(NSAppleEventDescriptor(int32: 3), forKeyword: AEKeyword(keyAEKeyData))
        page.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
        XCTAssertEqual(AnchorScripts.scalar(page), "3")

        let byID = NSAppleEventDescriptor.record().coerce(toDescriptorType: typeObjectSpecifier)!
        byID.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formUniqueID)), forKeyword: AEKeyword(keyAEKeyForm))
        byID.setDescriptor(NSAppleEventDescriptor(string: "ABC"), forKeyword: AEKeyword(keyAEKeyData))
        XCTAssertNil(AnchorScripts.scalar(byID))
    }
}

final class ContextVaultTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        // NSTemporaryDirectory lives under /var, a symlink to /private/var.
        tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ctx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("outer/inner/decks"),
                                                withIntermediateDirectories: true)
        for p in ["outer/notes.md", "outer/inner/decks/q3.key", "outer/inner/model.xlsx", "outer/a.ts", "outer/data.ts"] {
            FileManager.default.createFile(atPath: tmp.appendingPathComponent(p).path, contents: Data())
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testLocateDeepestVaultWins() {
        let outer = Vault(root: tmp.appendingPathComponent("outer"))
        let inner = Vault(root: tmp.appendingPathComponent("outer/inner"))
        let url = tmp.appendingPathComponent("outer/inner/decks/q3.key")
        let hit = FrontmostContext.locate(url, in: [outer, inner])
        XCTAssertEqual(hit?.0, inner)
        XCTAssertEqual(hit?.1, FileRef(relativePath: "decks/q3.key"))
        let hit2 = FrontmostContext.locate(url, in: [inner, outer])
        XCTAssertEqual(hit2?.0, inner)
        XCTAssertEqual(FrontmostContext.locate(tmp.appendingPathComponent("outer/notes.md"), in: [outer, inner])?.1,
                       FileRef(relativePath: "notes.md"))
    }

    func testLocateAcrossPrivateSymlink() {
        let vault = Vault(root: tmp.appendingPathComponent("outer"))
        let resolved = tmp.resolvingSymlinksInPath().path
        let privatePath = resolved.hasPrefix("/private") ? resolved : "/private" + resolved
        let viaPrivate = URL(fileURLWithPath: privatePath + "/outer/inner/model.xlsx")
        XCTAssertEqual(FrontmostContext.locate(viaPrivate, in: [vault])?.1, FileRef(relativePath: "inner/model.xlsx"))

        let privateVault = Vault(root: URL(fileURLWithPath: privatePath + "/outer"))
        XCTAssertEqual(FrontmostContext.locate(tmp.appendingPathComponent("outer/notes.md"), in: [privateVault])?.1,
                       FileRef(relativePath: "notes.md"))
    }

    func testLocatePackageWithTrailingSlashAndMisses() {
        let vault = Vault(root: tmp.appendingPathComponent("outer"))
        let pkg = URL(string: tmp.appendingPathComponent("outer/inner/decks/q3.key").absoluteString + "/")!
        XCTAssertEqual(FrontmostContext.locate(pkg, in: [vault])?.1, FileRef(relativePath: "inner/decks/q3.key"))
        XCTAssertNil(FrontmostContext.locate(URL(fileURLWithPath: "/Applications/Keynote.app"), in: [vault]))
        XCTAssertNil(FrontmostContext.locate(vault.root, in: [vault]))
        XCTAssertNil(FrontmostContext.locate(vault.notesDir.appendingPathComponent("x.md"), in: [vault]))
        // A sibling whose name shares the vault's prefix isn't inside it.
        XCTAssertNil(FrontmostContext.locate(URL(fileURLWithPath: tmp.path + "/outerwear/x.md"), in: [vault]))
    }

    func testSamePath() {
        let a = tmp.appendingPathComponent("outer/notes.md")
        let resolved = a.resolvingSymlinksInPath().path
        let b = URL(fileURLWithPath: resolved.hasPrefix("/private") ? resolved : "/private" + resolved)
        XCTAssertTrue(FrontmostContext.samePath(a, b))
        XCTAssertFalse(FrontmostContext.samePath(a, tmp.appendingPathComponent("outer/a.ts")))
    }

    func testTitleContainsWholeTokensOnly() {
        XCTAssertTrue(FrontmostContext.titleContains("a.ts — outer", name: "a.ts"))
        XCTAssertTrue(FrontmostContext.titleContains("● a.ts — outer", name: "a.ts"))
        XCTAssertTrue(FrontmostContext.titleContains("data.ts", name: "data.ts"))
        XCTAssertFalse(FrontmostContext.titleContains("data.ts — outer", name: "a.ts"))
        XCTAssertFalse(FrontmostContext.titleContains("a.tsx — outer", name: "a.ts"))
        XCTAssertFalse(FrontmostContext.titleContains("anything", name: ""))
    }

    func testTitleMatchNeedsExactlyOneFile() {
        let vault = Vault(root: tmp.appendingPathComponent("outer"))
        XCTAssertEqual(FrontmostContext.titleMatch("data.ts — outer", in: [vault])?.1, FileRef(relativePath: "data.ts"))
        XCTAssertEqual(FrontmostContext.titleMatch("● model.xlsx", in: [vault])?.1, FileRef(relativePath: "inner/model.xlsx"))
        XCTAssertNil(FrontmostContext.titleMatch("a.ts and data.ts", in: [vault]))
        XCTAssertNil(FrontmostContext.titleMatch("Untitled", in: [vault]))
    }
}

@MainActor
final class GlobalHotkeyTests: XCTestCase {
    func testCaptureDefaultIsControlOptionSpace() {
        let hk = GlobalHotkey.capture {}
        XCTAssertEqual(hk.keyCode, 49)
        XCTAssertEqual(hk.modifiers, UInt32(0x1000 | 0x0800))
        XCTAssertFalse(hk.isRegistered)
    }

    func testRegisterAndUnregister() {
        // ⌃⌥⇧F13 is unlikely to be taken by anything.
        let hk = GlobalHotkey(keyCode: 105, modifiers: UInt32(0x1000 | 0x0800 | 0x0200)) {}
        if hk.register() {
            XCTAssertTrue(hk.isRegistered)
            let twin = GlobalHotkey(keyCode: 105, modifiers: UInt32(0x1000 | 0x0800 | 0x0200)) {}
            XCTAssertFalse(twin.register(), "same combination twice should be refused")
            hk.unregister()
            XCTAssertFalse(hk.isRegistered)
            XCTAssertTrue(twin.register())
            twin.unregister()
        }
    }

    func testSystemShortcutLookupDoesNotCrash() {
        _ = GlobalHotkey.conflictsWithSystemShortcut(keyCode: GlobalHotkey.captureKeyCode,
                                                     modifiers: GlobalHotkey.captureModifiers)
        XCTAssertFalse(GlobalHotkey.conflictsWithSystemShortcut(keyCode: 105, modifiers: UInt32(0x1000 | 0x0800 | 0x0200)))
    }
}
