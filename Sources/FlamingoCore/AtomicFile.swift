import Foundation

/// Write-to-temp-then-rename, so a reader (Obsidian, the index watcher) never sees a
/// half-written sidecar. The temp file is hidden, has a short fixed-size name (so a target
/// name near NAME_MAX still works), and lives next to the target so the rename stays on
/// one volume.
enum AtomicFile {
    static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let suffix = String(UUID().uuidString.prefix(8))
        let tmp = dir.appendingPathComponent(".flamingo-\(suffix).tmp")
        do {
            try data.write(to: tmp, options: [])
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        if rename(tmp.path, url.path) != 0 {
            let code = errno
            try? fm.removeItem(at: tmp)
            throw SidecarError.writeFailed(path: url.path, errno: code)
        }
    }
}
