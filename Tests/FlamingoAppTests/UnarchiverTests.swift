import XCTest
@testable import Flamingo

final class UnarchiverTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    /// The vendored 7-Zip, as the app bundle carries it.
    private static let sevenZip = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Vendor/7-Zip/7zz")
    private var tools: Unarchiver.Tools { Unarchiver.Tools(sevenZip: Self.sevenZip) }
    private let broken = URL(fileURLWithPath: "/usr/bin/false")

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("unarchiver-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try XCTSkipUnless(fm.isExecutableFile(atPath: Self.sevenZip.path), "Vendor/7-Zip/7zz missing")
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    // MARK: Which files, which names

    func testExpandsArchivesButNotDocumentsOrDiskImages() {
        for name in ["a.zip", "a.RAR", "a.7z", "a.tar.gz", "a.tgz", "a.tar.zst", "a.gz", "a.xz", "a.cab", "a.7z.001", "a.part2.rar"] {
            XCTAssertTrue(Unarchiver.expands(URL(fileURLWithPath: "/x/" + name)), name)
        }
        for name in ["a.docx", "a.epub", "a.jar", "a.dmg", "a.iso", "a.pkg", "a.app", "a.001", "a.txt", "zip"] {
            XCTAssertFalse(Unarchiver.expands(URL(fileURLWithPath: "/x/" + name)), name)
        }
    }

    func testBaseNameDropsEveryArchiveExtension() {
        let names = ["Photos.tar.gz": "Photos", "Photos.part1.rar": "Photos", "Photos.7z.001": "Photos",
                     "Photos.zip": "Photos", "v1.2.zip": "v1.2", "Report 2026.tgz": "Report 2026"]
        for (file, base) in names {
            XCTAssertEqual(Unarchiver.baseName(of: URL(fileURLWithPath: "/x/" + file)), base, file)
        }
    }

    func testLaterVolumesStartFromTheFirst() throws {
        for name in ["Set.part01.rar", "Set.part02.rar", "Set.7z.001", "Set.7z.002"] { try Data().write(to: root.appendingPathComponent(name)) }
        XCTAssertEqual(Unarchiver.firstVolume(of: root.appendingPathComponent("Set.part02.rar")).lastPathComponent, "Set.part01.rar")
        XCTAssertEqual(Unarchiver.firstVolume(of: root.appendingPathComponent("Set.7z.002")).lastPathComponent, "Set.7z.001")
        // No first volume on disk: the one asked for.
        XCTAssertEqual(Unarchiver.firstVolume(of: root.appendingPathComponent("Other.part3.rar")).lastPathComponent, "Other.part3.rar")
    }

    // MARK: Expanding

    func testZipHoldingOneFolderBecomesThatFolderAndKeepsTheArchive() throws {
        let zip = try makeZip(named: "Project.zip", folder: "Project", files: ["a.txt": "alpha", "sub/b.txt": "beta"])
        let out = try Unarchiver.expand(zip, tools: tools)
        XCTAssertEqual(out.lastPathComponent, "Project")
        XCTAssertEqual(out.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("sub/b.txt"), encoding: .utf8), "beta")
        XCTAssertTrue(fm.fileExists(atPath: zip.path))
        // Nothing left behind but the archive and what came out of it.
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: root.path)), ["Project.zip", "Project"])
    }

    func testSeveralItemsGoInAFolderNamedForTheArchive() throws {
        let src = try makeTree(["a.txt": "alpha", "b.txt": "beta"])
        let tarball = root.appendingPathComponent("Bundle.tar.gz")
        try run("/usr/bin/bsdtar", "-czf", tarball.path, "-C", src.path, "a.txt", "b.txt")
        let out = try Unarchiver.expand(tarball, tools: tools)
        XCTAssertEqual(out.lastPathComponent, "Bundle")
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: out.path)), ["a.txt", "b.txt"])
    }

    func testATakenNameGetsANumberInsteadOfOverwriting() throws {
        let zip = try makeZip(named: "Project.zip", folder: "Project", files: ["a.txt": "alpha"])
        let first = try Unarchiver.expand(zip, tools: tools)
        try "edited".write(to: first.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let second = try Unarchiver.expand(zip, tools: tools)
        XCTAssertEqual(second.lastPathComponent, "Project 2")
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("a.txt"), encoding: .utf8), "edited")
        // A file keeps its extension: "notes 2.txt".
        XCTAssertEqual(Unarchiver.freeName("Project.zip", in: root, isFolder: false).lastPathComponent, "Project 2.zip")
    }

    func testRarAndRar5() throws {
        let rar = root.appendingPathComponent("Old.rar")
        try XCTUnwrap(Data(base64Encoded: Self.rar4)).write(to: rar)
        let old = try Unarchiver.expand(rar, tools: tools)
        XCTAssertEqual(old.lastPathComponent, "Old")
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("testdir/test.txt"), encoding: .utf8), "test text document\r\n")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: old.appendingPathComponent("testlink").path), "test.txt")

        let rar5 = root.appendingPathComponent("New.rar")
        try XCTUnwrap(Data(base64Encoded: Self.rar5)).write(to: rar5)
        let bin = try Unarchiver.expand(rar5, tools: tools)
        XCTAssertEqual(bin.lastPathComponent, "test.bin")
        XCTAssertEqual(try Data(contentsOf: bin).count, 1200)
    }

    func testEncryptedArchivesAskForTheirPassword() throws {
        let src = try makeTree(["secret.txt": "hidden"])
        for (name, extra) in [("Locked.7z", ["-mhe=on"]), ("Locked.zip", ["-tzip"])] {
            let archive = root.appendingPathComponent(name)
            try run(Self.sevenZip.path, ["a", "-bso0", "-bsp0", "-pOpenSesame"] + extra + [archive.path, src.appendingPathComponent("secret.txt").path])
            XCTAssertThrowsError(try Unarchiver.expand(archive, tools: tools)) { XCTAssertEqual($0 as? Unarchiver.Failure, .needsPassword, name) }
            XCTAssertThrowsError(try Unarchiver.expand(archive, password: "wrong", tools: tools)) { XCTAssertEqual($0 as? Unarchiver.Failure, .needsPassword, name) }
            let out = try Unarchiver.expand(archive, password: "OpenSesame", tools: tools)
            XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "hidden", name)
            try fm.removeItem(at: out)
        }
        // Failed tries leave nothing beside the archives.
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: root.path)), ["src", "Locked.7z", "Locked.zip"])
    }

    func testCompressedTarballFallsBackTo7ZipThroughBothLayers() throws {
        let src = try makeTree(["a.txt": "alpha", "b.txt": "beta"])
        let tarball = root.appendingPathComponent("Logs.tar.xz")
        try run("/usr/bin/bsdtar", "-cJf", tarball.path, "-C", src.path, "a.txt", "b.txt")
        var noTar = tools
        noTar.bsdtar = broken
        let out = try Unarchiver.expand(tarball, tools: noTar)
        XCTAssertEqual(out.lastPathComponent, "Logs")
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: out.path)), ["a.txt", "b.txt"])
    }

    func testFinderLeftoversAreDropped() throws {
        // The AppleDouble folder a Mac zip carries, as 7-Zip sees it when ditto can't help.
        let src = try makeTree(["a.txt": "alpha", "__MACOSX/._a.txt": "fork", ".DS_Store": "view"])
        let zip = root.appendingPathComponent("Note.zip")
        try run(Self.sevenZip.path, "a", "-bso0", "-bsp0", "-tzip", zip.path,
                src.appendingPathComponent("a.txt").path, src.appendingPathComponent("__MACOSX").path, src.appendingPathComponent(".DS_Store").path)
        var noDitto = tools
        noDitto.ditto = broken
        let out = try Unarchiver.expand(zip, tools: noDitto)
        XCTAssertEqual(out.lastPathComponent, "a.txt")
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("__MACOSX").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(".DS_Store").path))
    }

    func testQuarantineCarriesOverToEverythingInside() throws {
        let zip = try makeZip(named: "Download.zip", folder: "Download", files: ["tool.sh": "echo hi", "lib/x.txt": "x"])
        let flag = "0083;6710a3c4;Safari;"
        XCTAssertEqual(setxattr(zip.path, "com.apple.quarantine", flag, flag.utf8.count, 0, 0), 0)
        let out = try Unarchiver.expand(zip, tools: tools)
        for path in ["", "tool.sh", "lib", "lib/x.txt"] {
            XCTAssertEqual(quarantine(of: out.appendingPathComponent(path)), flag, path)
        }
        // An archive that wasn't downloaded marks nothing.
        removexattr(zip.path, "com.apple.quarantine", 0)
        let clean = try Unarchiver.expand(zip, tools: tools)
        XCTAssertNil(quarantine(of: clean.appendingPathComponent("tool.sh")))
    }

    func testGarbageIsUnreadableAndLeavesNothing() throws {
        let fake = root.appendingPathComponent("Fake.rar")
        try Data("not an archive at all".utf8).write(to: fake)
        XCTAssertThrowsError(try Unarchiver.expand(fake, tools: tools)) { error in
            guard case .unreadable = error as? Unarchiver.Failure else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path), ["Fake.rar"])
    }

    // MARK: Helpers

    private func makeTree(_ files: [String: String], in name: String = "src") throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        for (path, text) in files {
            let url = dir.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return dir
    }

    /// A zip as Finder's Compress makes it: the folder itself at the top.
    private func makeZip(named name: String, folder: String, files: [String: String]) throws -> URL {
        let parent = try makeTree(files.reduce(into: [:]) { $0[folder + "/" + $1.key] = $1.value }, in: "staging-\(UUID().uuidString)")
        let zip = root.appendingPathComponent(name)
        try run("/usr/bin/ditto", "-c", "-k", "--keepParent", parent.appendingPathComponent(folder).path, zip.path)
        try fm.removeItem(at: parent)
        return zip
    }

    private func run(_ tool: String, _ arguments: String...) throws { try run(tool, arguments) }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments)")
    }

    private func quarantine(of url: URL) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let n = getxattr(url.path, "com.apple.quarantine", &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        return n > 0 ? String(decoding: buffer.prefix(n).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
    }

    // From libarchive's test suite (test_read_format_rar.rar, test_read_format_rar5_compressed.rar).
    private static let rar4 = "UmFyIRoHAM+QcwAADQAAAAAAAACEUnQgkDIAFAAAABQAAAADQqLIvrd22j4UMAgApIEAAHRlc3QudHh0gAi3dto+t3baPnRlc3QgdGV4dCBkb2N1bWVudA0KnS90IJAyAAgAAAAIAAAAA3tEybbRTNg+FDAIAP+hAAB0ZXN0bGlua8AI0UzYPlBf2j50ZXN0LnR4dM3gdCCQOgAUAAAAFAAAAANCosi+Y3faPhQwEACkgQAAdGVzdGRpclx0ZXN0LnR4dMDMY3faPmN32j50ZXN0IHRleHQgZG9jdW1lbnQNCqHIdOCQMQAAAAAAAAAAAAMAAAAAY3faPhQwBwDtQQAAdGVzdGRpcsDMY3faPmR32j7m53TgkDYAAAAAAAAAAAADAAAAAJ2r1T4UMAwA7UEAAHRlc3RlbXB0eWRpcoDMnavVPsVd2j7EPXsAQAcA"
    private static let rar5 = "UmFyIRoHAQDz4YLrCwEFBwAGAQGAgIAAicZf2iYCAwvpAgSwCaSDAs1wynyABQEIdGVzdC5iaW4KAxOLV6xb+BitHsr0ZQEnZWBUH1V2Xb+UknHJz2WWWQxw2WWTGMWSE4ZCSSThkJCSSSQk45JJIQhJJCEJJJCSSEISEs21b3t9Mw6AfR0Drj+eup/3Qf732vfdea86X+gAQAEAyCCfn49vX08vHv7uzr6uno5+Xk4+Lh4N/d3NrZ19bV1NPS0M/NzMrJyMfGxcTDwb+9vLu5uLe2tbSzsrGvrq2rqqmnpaSjoqGgn52cm5mXlpSTSyUjIR6FAfjoyKiYc6cNmoaEgoB+fHt6eHZ0c3Jxb21raWdlY2FfXVtZV1VTITf1/I/QJT6JTn+ESXRYowZ5YXajgppimUF+ZC0XadRjLDOMCoR/+glMZpCl9lUKxWVguLAZFoNy4HdeEGwA8xBIyCeZhWNAumoZbYN5uHg4Bgcg+uYROgpnYYDwNt6Hu9h1fQjfxYQI0YMecKHk0Jg2L44OY6HCIEqeGFFjtjQ/nxUIBsIQ0IhNIxnJAvJQAdd1ZRAwUEAA=="
}
