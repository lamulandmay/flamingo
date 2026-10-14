import Foundation
import XCTest
@testable import FlamingoCore

/// A throwaway vault on disk. Removed in `tearDown` by the owning test.
struct TempVault {
    let vault: Vault

    init(_ name: String = #function) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlamingoCoreTests", isDirectory: true)
            .appendingPathComponent(name.replacingOccurrences(of: "()", with: "") + "-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        vault = Vault(root: base)
    }

    var root: URL { vault.root }

    @discardableResult
    func file(_ relativePath: String, _ contents: String = "x") throws -> FileRef {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return FileRef(relativePath: relativePath)
    }

    @discardableResult
    func folder(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func rename(_ from: String, to: String) throws {
        let dest = root.appendingPathComponent(to)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent(from), to: dest)
    }

    func remove(_ relativePath: String) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(relativePath))
    }

    func contents(ofSidecarFor relativePath: String) throws -> String {
        try String(contentsOf: vault.notesDir.appendingPathComponent(relativePath + ".md"), encoding: .utf8)
    }

    func destroy() {
        try? FileManager.default.removeItem(at: root)
    }
}

enum Fixtures {
    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)
    }

    static func all() throws -> [(name: String, text: String)] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try urls.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    static func text(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }
}

func ts(_ s: String) -> Date {
    guard let d = SidecarFormat.timestamp(from: s) else { fatalError("bad test timestamp \(s)") }
    return d
}
