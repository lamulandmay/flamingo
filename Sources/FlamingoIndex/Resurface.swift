import Foundation
import FlamingoCore

extension IndexStore {
    /// When each indexed file was first touched as far as the index knows: its oldest thought,
    /// else its modification date. The shell adds Trail's first opens on top.
    public func firstSeenDates() throws -> [String: Date] {
        try read(snapshot: true) { db in
            var dates: [String: Date] = [:]
            for (path, mtime) in try db.query("SELECT path, mtime FROM files", row: { ($0.string(0), $0.double(1)) }) {
                dates[path] = Date(timeIntervalSince1970: mtime)
            }
            for (path, ts) in try db.query("SELECT path, min(ts) FROM comments GROUP BY path", row: { ($0.string(0), $0.double(1)) }) {
                let t = Date(timeIntervalSince1970: ts)
                if dates[path].map({ t < $0 }) ?? true { dates[path] = t }
            }
            return dates
        }
    }

    /// A thought left a while ago, chosen at random, preferring ones older than `age`.
    /// Inbox thoughts (no file) are skipped.
    public func resurfaceableThought(olderThan age: TimeInterval = 3 * 86_400, now: Date = Date()) throws -> (FileRef, Comment)? {
        try read(snapshot: true) { db in
            let sql = """
                SELECT path, id, ts, anchor_kind, anchor_value, text, provenance FROM comments
                WHERE path NOT LIKE '\\_inbox/%' ESCAPE '\\' AND ts < ? ORDER BY random() LIMIT 1
                """
            let pick = { (cutoff: Double) in
                try db.query(sql, cutoff) { (FileRef(relativePath: $0.string(0)), Self.comment($0, 1, provenanceColumn: 6)) }.first
            }
            return try pick(now.timeIntervalSince1970 - age) ?? pick(now.timeIntervalSince1970 + 1)
        }
    }
}
