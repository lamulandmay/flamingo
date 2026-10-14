import Foundation
import XCTest

/// Fixture files live in `Tests/FlamingoExtractTests/Fixtures/` and are found through `#filePath`,
/// so they need no resource declaration. Big benchmark files are built at test time instead.
enum Fixtures {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    /// A fresh empty directory under the system temp dir, removed when the test case finishes.
    static func tempDir(_ test: XCTestCase) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("flamingo-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    /// Writes `members` (archive path → contents) into a zip at `url` using `/usr/bin/zip`.
    static func zip(_ members: [String: Data], to url: URL) throws {
        let staging = url.deletingLastPathComponent().appendingPathComponent(".staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        for (path, data) in members {
            let f = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: f)
        }
        try? FileManager.default.removeItem(at: url)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = ["-X", "-q", "-r", url.path, "."]
        p.currentDirectoryURL = staging
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    static func zip(_ members: [String: String], to url: URL) throws {
        try zip(members.mapValues { Data($0.utf8) }, to: url)
    }

    /// Wall-clock seconds for `body`.
    static func time(_ body: () throws -> Void) rethrows -> TimeInterval {
        let t = Date()
        try body()
        return Date().timeIntervalSince(t)
    }
}
