import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Flamingo

@MainActor
final class FileHandoffTests: XCTestCase {
    func testNativeDragHasReadableFileURLAndRetainsInternalPath() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Budget #1 中文.txt")
        let contents = Data("original content".utf8)
        try contents.write(to: url)
        let item = FileHandoff.pasteboardItem(url: url, relativePath: "Work/Budget #1 中文.txt")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.writeObjects([item]))
        XCTAssertEqual(board.string(forType: FileHandoff.relativePathType), "Work/Budget #1 中文.txt")
        let urls = try XCTUnwrap(board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])
        XCTAssertEqual(urls, [url.standardizedFileURL])
        XCTAssertEqual(try Data(contentsOf: url), contents)
    }

    func testSwiftUIDragLoadsTheOriginalFileURLAndPrivatePath() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("A report.pdf")
        try Data("source bytes".utf8).write(to: url)
        let provider = FileHandoff.itemProvider(url: url, relativePath: "A report.pdf")
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        XCTAssertEqual(provider.suggestedName, "A report.pdf")
        let received: URL = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, error in
                if let url = object as? URL { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
        XCTAssertEqual(received, url.standardizedFileURL)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: FileHandoff.relativePathType.rawValue) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
        XCTAssertEqual(String(data: data, encoding: .utf8), "A report.pdf")
        XCTAssertEqual(try Data(contentsOf: url), Data("source bytes".utf8))
    }

    func testCopySupportsMultipleRealFilesAndFoldersWithoutPathText() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.md")
        let folder = root.appendingPathComponent("Reference files", isDirectory: true)
        try Data("notes".utf8).write(to: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(FileHandoff.copy(urls: [file, folder, file], to: board))
        let urls = try XCTUnwrap(board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])
        XCTAssertEqual(urls, [file.standardizedFileURL, folder.standardizedFileURL])
        XCTAssertEqual(board.pasteboardItems?.count, 2)
        XCTAssertNil(board.string(forType: .string))
        XCTAssertTrue(try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }

    func testFolderProviderAdvertisesARealURL() async throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let provider = FileHandoff.itemProvider(url: folder, relativePath: "Folder")
        let received: URL = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, error in
                if let url = object as? URL { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
        XCTAssertEqual(received, folder.standardizedFileURL)
        XCTAssertTrue(try received.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }

    func testInvalidCopyLeavesTheExistingClipboardAlone() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("previous text", forType: .string)
        XCTAssertFalse(FileHandoff.copy(urls: [], to: board))
        XCTAssertFalse(FileHandoff.copy(urls: [URL(string: "https://example.com/a.pdf")!,
                                              URL(fileURLWithPath: "/missing/" + UUID().uuidString)], to: board))
        XCTAssertEqual(board.string(forType: .string), "previous text")
    }

    func testFileCopyResponderDoesNotInterceptTextEditing() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let outline = SidebarOutlineView.make(label: "Copy test")
        window.contentView?.addSubview(outline)
        var copies = 0
        outline.onCopy = { copies += 1; return true }
        XCTAssertTrue(window.makeFirstResponder(outline))
        outline.copy(nil)
        XCTAssertEqual(copies, 1)
        let text = NSTextView()
        window.contentView?.addSubview(text)
        XCTAssertTrue(window.makeFirstResponder(text))
        outline.copy(nil)
        XCTAssertEqual(copies, 1)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Flamingo-handoff-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
