import Foundation
import FlamingoCore

/// Shell-side conveniences on `FileAnchor`. Plan 01 owns this file; the type is plan 02's.
extension FileAnchor {
    static func page(_ n: Int) -> FileAnchor { FileAnchor(kind: .page, value: String(n)) }
    static func slide(_ n: Int) -> FileAnchor { FileAnchor(kind: .slide, value: String(n)) }
    static func time(_ seconds: Double) -> FileAnchor { FileAnchor(kind: .time, value: FileAnchor.clock(seconds)) }

    /// `(page 12)` → 12. Also reads a slide or line number.
    var number: Int? {
        switch kind {
        case .page, .slide, .line: return Int(value.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// `(time 1:23)` → 83. Accepts `m:ss`, `h:mm:ss`, or bare seconds.
    var seconds: Double? {
        guard kind == .time else { return nil }
        let parts = value.split(separator: ":").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

/// Media file extensions the preview hands to `AVPlayerView`.
enum MediaKind {
    static let video: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg"]
    static let audio: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "caf"]
    static func isMedia(_ ext: String) -> Bool { video.contains(ext) || audio.contains(ext) }
}
