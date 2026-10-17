import XCTest
@testable import FlamingoCore

final class DocumentSafetyTests: XCTestCase {
    func testAliasesAndExclusiveRealOfficeCreation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for alias in ["powerpoint", "ppt", ".pptx"] { XCTAssertEqual(DocumentFactory.resolve(alias)?.ext, "pptx") }
        for type in ["pptx", "docx", "xlsx"] {
            let url = try DocumentFactory.create(type: type, name: "6767", in: folder)
            let before = try Data(contentsOf: url)
            XCTAssertEqual(Array(before.prefix(2)), [0x50, 0x4b])
            XCTAssertGreaterThan(before.count, 1000)
            XCTAssertThrowsError(try DocumentFactory.create(type: type, name: "6767", in: folder))
            XCTAssertEqual(try Data(contentsOf: url), before)
        }
        XCTAssertThrowsError(try DocumentFactory.create(type: "md", name: "../escape", in: folder))
        XCTAssertThrowsError(try DocumentFactory.create(type: "pdf", name: "invalid", in: folder))
    }

    func testStaleDraftCannotOverwriteExternalSave() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("initial".utf8).write(to: file)
        let original = try SafeTextFile.read(file)
        try Data("external revision".utf8).write(to: file, options: .atomic)
        XCTAssertThrowsError(try SafeTextFile.save("my draft", to: file, replacing: original.data))
        XCTAssertEqual(try String(contentsOf: file), "external revision")
        let current = try SafeTextFile.read(file)
        _ = try SafeTextFile.save("已安全保存\n", to: file, replacing: current.data)
        XCTAssertEqual(try String(contentsOf: file), "已安全保存\n")
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("document-safety-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testAtomicSaveRetainsIdentityXattrsPermissionsACLAndCreationDate() throws {
        let folder = try temporaryFolder(), file = folder.appendingPathComponent("notes.md")
        try Data("before".utf8).write(to: file)
        let id = try FileIdentity.id(for: file)
        let metadata = Array("retained attribute".utf8)
        XCTAssertEqual(setxattr(file.path, "com.flamingo.safety-test", metadata, metadata.count, 0, 0), 0)
        XCTAssertEqual(chmod(file.path, mode_t(0o640)), 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "user:\(NSUserName()) allow readattr,readextattr,readsecurity", file.path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        let beforeACL = try aclText(file)
        XCTAssertFalse(beforeACL.isEmpty)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: file.path)
        let creation = try file.resourceValues(forKeys: [.creationDateKey]).creationDate
        let original = try SafeTextFile.read(file)
        let returned = try SafeTextFile.save("after with more text", to: file, replacing: original.data)
        XCTAssertEqual(try Data(contentsOf: file), returned)
        XCTAssertEqual(try FileIdentity.existingID(for: file), id)
        var bytes = [UInt8](repeating: 0, count: 100)
        let count = getxattr(file.path, "com.flamingo.safety-test", &bytes, bytes.count, 0, 0)
        XCTAssertEqual(Array(bytes.prefix(max(0, count))), metadata)
        var info = stat(); XCTAssertEqual(lstat(file.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o640)
        XCTAssertEqual(try aclText(file), beforeACL)
        XCTAssertEqual(try file.resourceValues(forKeys: [.creationDateKey]).creationDate, creation)
        XCTAssertGreaterThan(info.st_mtimespec.tv_sec, 1000)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["notes.md"])
    }

    private func aclText(_ url: URL) throws -> String {
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else { throw DocumentFileIO.error(path: url.path) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var count = 0
        guard let text = acl_to_text(acl, &count) else { throw DocumentFileIO.error(path: url.path) }
        defer { acl_free(text) }
        return String(cString: text)
    }

    func testReadOnlyFileCannotBeOverwrittenViaWritableParent() throws {
        let file = try temporaryFolder().appendingPathComponent("read-only.txt")
        try Data("original".utf8).write(to: file)
        XCTAssertEqual(chmod(file.path, mode_t(0o444)), 0)
        let baseline = try SafeTextFile.read(file)
        XCTAssertThrowsError(try SafeTextFile.save("replacement", to: file, replacing: baseline.data))
        XCTAssertEqual(try Data(contentsOf: file), baseline.data)
    }

    func testSymlinkAndPipeAreNeverReadOrReplaced() throws {
        let folder = try temporaryFolder(), target = folder.appendingPathComponent("target.txt")
        let link = folder.appendingPathComponent("link.txt"), pipe = folder.appendingPathComponent("pipe.txt")
        let original = Data("real target".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(mkfifo(pipe.path, mode_t(0o600)), 0)
        for file in [link, pipe, folder] {
            XCTAssertThrowsError(try SafeTextFile.read(file))
            XCTAssertThrowsError(try SafeTextFile.save("replacement", to: file, replacing: original))
        }
        XCTAssertEqual(try Data(contentsOf: target), original)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertThrowsError(try DocumentFactory.create(type: "txt", name: "link", in: folder))
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testReadAndSaveBudgetsAndUnsupportedBytes() throws {
        let folder = try temporaryFolder(), file = folder.appendingPathComponent("large.txt")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(SafeTextFile.byteLimit + 1)); try handle.close()
        XCTAssertThrowsError(try SafeTextFile.read(file))
        try Data([0xff, 0xfe, 0x00]).write(to: file)
        XCTAssertThrowsError(try SafeTextFile.read(file))
        try Data("valid".utf8).write(to: file)
        XCTAssertThrowsError(try SafeTextFile.save("bad\0text", to: file, replacing: Data("valid".utf8)))
        XCTAssertEqual(try String(contentsOf: file), "valid")
    }

    func testNamesCannotEscapeOrCreateHiddenControlAndOfficeLockFiles() throws {
        let md = try XCTUnwrap(DocumentFactory.resolve("md"))
        for name in [".", "..", "../escape", "/absolute", ".flamingo", "~$private", "folder\\file", "with:colon", "a\u{7}b", "a\0b", String(repeating: "x", count: 256)] {
            XCTAssertThrowsError(try DocumentFactory.filename(name, format: md), name)
        }
        for ext in ["../md", "md/escape", ".md", "", "md\0"] {
            XCTAssertThrowsError(try DocumentFactory.filename("notes", format: .init(ext, "Unsafe")))
        }
        XCTAssertEqual(try DocumentFactory.filename("~draft.MD", format: md), "~draft.md")
    }

    func testConcurrentCreatorsPublishExactlyOneCompleteDocument() throws {
        let folder = try temporaryFolder(), results = Outcomes()
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            let result = Result { try DocumentFactory.create(type: "docx", name: "same", in: folder) }
            results.record(success: (try? result.get()) != nil)
        }
        XCTAssertEqual(results.successCount, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["same.docx"])
        let template = try XCTUnwrap(DocumentFactory.templateURL(for: "docx"))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("same.docx")), try Data(contentsOf: template))
    }

    func testCompetingSavesFromSameBaselineDoNotLoseTheFirstCommit() throws {
        let file = try temporaryFolder().appendingPathComponent("competing.txt"), results = Outcomes()
        let baseline = Data("original".utf8); try baseline.write(to: file)
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            let result = Result { try SafeTextFile.save("revision \(i)", to: file, replacing: baseline) }
            results.record(success: (try? result.get()) != nil)
        }
        XCTAssertEqual(results.successCount, 1)
        XCTAssertTrue(["revision 0", "revision 1"].contains(try String(contentsOf: file)))
    }

    func testMissingResourceBundleIsRecoverable() {
        XCTAssertNil(DocumentFactory.templateURL(for: "pptx", roots: []))
        XCTAssertNil(DocumentFactory.templateURL(for: "pptx", roots: [URL(fileURLWithPath: "/nonexistent/flamingo-resources")]))
    }

    private final class Outcomes: @unchecked Sendable {
        private let lock = NSLock()
        private var successes = 0
        var successCount: Int { lock.lock(); defer { lock.unlock() }; return successes }
        func record(success: Bool) { lock.lock(); if success { successes += 1 }; lock.unlock() }
    }

}
