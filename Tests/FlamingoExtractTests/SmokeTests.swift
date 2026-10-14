import XCTest
import FlamingoCore
@testable import FlamingoExtract

/// Runs `Extract.extract` over a real folder the way the indexer does, eight at a time:
/// `FLAMINGO_SMOKE_DIR=~/Downloads scripts/test.sh --filter SmokeTests`. Skipped otherwise.
final class SmokeTests: XCTestCase {
    func testRealFolderNeverThrowsForExistingFiles() throws {
        guard let dir = ProcessInfo.processInfo.environment["FLAMINGO_SMOKE_DIR"] else {
            throw XCTSkip("set FLAMINGO_SMOKE_DIR to a folder to smoke-test")
        }
        let vault = Vault(root: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath))
        let files = VaultScanner.files(in: vault)
        struct Row { var path: String; var seconds: Double; var chars: Int; var sections: Int; var error: String? }
        let rows = Locked<[Row]>([])
        let start = Date()
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            let url = vault.url(for: files[i])
            let t = Date()
            var row = Row(path: files[i].relativePath, seconds: 0, chars: 0, sections: 0)
            do {
                let e = try Extract.extract(url)
                row.chars = e.text.count
                row.sections = e.sections.count
            } catch {
                row.error = "\(error)"
            }
            row.seconds = Date().timeIntervalSince(t)
            rows.withLock { $0.append(row) }
        }
        let all = rows.withLock { $0 }
        let total = Date().timeIntervalSince(start)
        var byExt: [String: (n: Int, withText: Int, seconds: Double)] = [:]
        for r in all {
            let ext = (r.path as NSString).pathExtension.lowercased()
            var v = byExt[ext] ?? (0, 0, 0)
            v.n += 1; v.withText += r.chars > 0 ? 1 : 0; v.seconds += r.seconds
            byExt[ext] = v
        }
        print("smoke: \(all.count) files in \(String(format: "%.1f", total)) s")
        for (ext, v) in byExt.sorted(by: { $0.value.seconds > $1.value.seconds }) {
            let name = (ext.isEmpty ? "(none)" : ext).padding(toLength: 10, withPad: " ", startingAt: 0)
            print("  \(name)" + String(format: " %5d files  %5d with text  %7.2f s", v.n, v.withText, v.seconds))
        }
        print("slowest:")
        for r in all.sorted(by: { $0.seconds > $1.seconds }).prefix(10) {
            print(String(format: "  %6.2f s  %@", r.seconds, r.path as NSString))
        }
        let failures = all.filter { $0.error != nil && FileManager.default.fileExists(atPath: vault.url(for: FileRef(relativePath: $0.path)).path) }
        for f in failures { print("THREW  \(f.path): \(f.error!)") }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) existing files threw")
    }
}
