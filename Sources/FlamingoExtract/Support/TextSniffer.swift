import Foundation

/// Guesses whether an extension-less or unknown file is plain text, from its first few KB.
enum TextSniffer {
    static func looksLikeText(_ url: URL, sample: Int = 4096) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: sample), !d.isEmpty else { return false }
        if d.starts(with: [0xEF, 0xBB, 0xBF]) || d.starts(with: [0xFF, 0xFE]) || d.starts(with: [0xFE, 0xFF]) { return true }
        if d.contains(0) { return false }
        // Valid UTF-8, allowing a multi-byte sequence cut off at the end of the sample.
        for cut in 0...min(3, d.count - 1) where String(data: d.dropLast(cut), encoding: .utf8) != nil {
            let control = d.filter { $0 < 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D && $0 != 0x0C && $0 != 0x1B }
            return control.count * 100 < d.count
        }
        return false
    }
}
