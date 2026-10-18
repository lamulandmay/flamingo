import Foundation

/// One harness session, as its log on this Mac tells it.
public struct AgentLogSession: Equatable, Sendable {
    public var harness: AgentHarness
    public var id: String
    public var cwd: String
    public var title: String?
    public var lastActive: Date
    public var log: URL
}

/// Where harnesses keep their session logs, and how to read where each one worked. The
/// formats are the harnesses' own and change between releases: a line that doesn't parse is
/// skipped, and a log that never names a folder is left out.
///
/// - Claude Code: `~/.claude/projects/<slug>/<session>.jsonl`. Every turn carries `cwd` and
///   `sessionId`; `{"type":"ai-title","aiTitle":…}` names the session. A slug turns both `/`
///   and `.` into `-`, so it can't be turned back into a path: only `cwd` is trusted.
/// - Codex: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, filed by start date, opening with
///   `{"type":"session_meta","payload":{"id":…,"cwd":…}}`.
public struct AgentLogs: Sendable {
    public var claudeProjects: URL
    public var codexSessions: URL
    /// A Codex session keeps writing to the day folder it started in; look this many days back.
    public var codexDays = 7

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        claudeProjects = home.appendingPathComponent(".claude/projects", isDirectory: true)
        codexSessions = home.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// Sessions whose log was written at or after `since`.
    public func recent(since: Date, now: Date = Date()) -> [AgentLogSession] {
        claude(since: since) + codex(since: since, now: now)
    }

    func claude(since: Date) -> [AgentLogSession] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: claudeProjects, includingPropertiesForKeys: nil) else { return [] }
        var out: [AgentLogSession] = []
        for folder in projects {
            for log in Self.logs(in: folder, since: since) {
                guard let tail = Self.claudeTail(log.url) else { continue }
                out.append(AgentLogSession(harness: .claudeCode, id: log.url.deletingPathExtension().lastPathComponent,
                                           cwd: tail.cwd, title: tail.title, lastActive: log.modified, log: log.url))
            }
        }
        return out
    }

    func codex(since: Date, now: Date) -> [AgentLogSession] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var out: [AgentLogSession] = []
        for back in 0...codexDays {
            guard let day = calendar.date(byAdding: .day, value: -back, to: now) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = codexSessions.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!), isDirectory: true)
            for log in Self.logs(in: folder, since: since) {
                guard let meta = Self.codexMeta(log.url) else { continue }
                out.append(AgentLogSession(harness: .codex, id: meta.id, cwd: meta.cwd, title: nil,
                                           lastActive: log.modified, log: log.url))
            }
        }
        return out
    }

    static func logs(in folder: URL, since: Date) -> [(url: URL, modified: Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return [] }
        return urls.compactMap { url in
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= since else { return nil }
            return (url, modified)
        }
    }

    /// The newest `cwd` and title near the end of a Claude Code log. Single lines can run to
    /// megabytes, so the window grows until a `cwd` turns up.
    static func claudeTail(_ url: URL) -> (cwd: String, title: String?)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let cwdKey = Data("\"cwd\"".utf8), titleKey = Data("\"ai-title\"".utf8)
        var window: UInt64 = 64 * 1024
        while true {
            let start = size > window ? size - window : 0
            guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
            var cwd: String?, title: String?
            for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
                let wantsCwd = cwd == nil && line.range(of: cwdKey) != nil
                let wantsTitle = title == nil && line.range(of: titleKey) != nil
                guard wantsCwd || wantsTitle,
                      let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if wantsCwd, let value = object["cwd"] as? String, !value.isEmpty { cwd = value }
                if wantsTitle, object["type"] as? String == "ai-title", let value = object["aiTitle"] as? String { title = value }
                if cwd != nil, title != nil { break }
            }
            if let cwd { return (cwd, title) }
            if start == 0 || window >= 16 * 1024 * 1024 { return nil }
            window *= 4
        }
    }

    /// A Codex log's first line. It carries the base instructions, so it can be long.
    static func codexMeta(_ url: URL) -> (id: String, cwd: String)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var line = Data()
        while line.count < 8 * 1024 * 1024 {
            guard let chunk = try? handle.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
            if let end = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                line.append(chunk[chunk.startIndex..<end])
                break
            }
            line.append(chunk)
        }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let cwd = payload["cwd"] as? String, !cwd.isEmpty else { return nil }
        let id = (payload["id"] as? String) ?? url.deletingPathExtension().lastPathComponent
        return (id, cwd)
    }
}
