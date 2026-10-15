import Foundation
import IOKit.ps
import FlamingoCore

/// A title and three tags for a file whose extractor found no title, from a small model under
/// Ollama. Synchronous; runs on the index's background queue only.
public struct Titler: Sendable {
    public var url = URL(string: "http://127.0.0.1:11434/api/chat")!
    public var model = UserDefaults.standard.string(forKey: "FlamingoTitleModel") ?? "gemma3:4b"
    var session: URLSession = .shared
    /// Tests swap in a fake; nil asks Ollama.
    var fake: (@Sendable (String, String) -> (String, [String])?)?

    static let maxChars = 1500

    public init() {}

    struct Failed: Error {}

    /// Nil when Ollama isn't there. Throws `Failed` when it answered but not usefully, so the
    /// file is marked and not asked about again.
    func describe(path: String, text: String) throws -> (title: String, tags: [String])? {
        let text = String(text.prefix(Self.maxChars))
        if let fake {
            guard let r = fake(path, text) else { return nil }
            return try Self.clean(r.0, r.1, path: path)
        }
        let prompt = """
        Name this file. Give a short descriptive title (3 to 8 words, no file extension, not the \
        file name) and exactly three lowercase one-word tags.

        File: \(path)

        \(text)
        """
        let body: [String: Any] = [
            "model": model, "stream": false, "keep_alive": "5m",
            "options": ["temperature": 0.2, "num_ctx": 2048],
            "format": [
                "type": "object",
                "properties": ["title": ["type": "string"],
                               "tags": ["type": "array", "items": ["type": "string"], "minItems": 3, "maxItems": 3]],
                "required": ["title", "tags"],
            ],
            "messages": [["role": "user", "content": prompt]],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (Data?, Int?)
        let task = session.dataTask(with: request) { data, response, _ in
            result = (data, (response as? HTTPURLResponse)?.statusCode)
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + 125) == .timedOut { task.cancel(); return nil }
        // Down, or the model isn't pulled: try again another time rather than mark the file.
        guard result.1 == 200, let data = result.0 else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = (json["message"] as? [String: Any])?["content"] as? String,
              let inner = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
              let title = inner["title"] as? String else { throw Failed() }
        return try Self.clean(title, inner["tags"] as? [String] ?? [], path: path)
    }

    /// Sentence-ish title, at most 80 characters; tags lowercased, one word, deduped, three at most.
    static func clean(_ title: String, _ tags: [String], path: String) throws -> (title: String, tags: [String]) {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'.")))
        if t.count > 80 { t = String(t.prefix(80)).trimmingCharacters(in: .whitespaces) }
        let name = (path as NSString).lastPathComponent
        guard !t.isEmpty, t != name, t != (name as NSString).deletingPathExtension else { throw Failed() }
        if let first = t.first, first.isLowercase { t = first.uppercased() + t.dropFirst() }
        var seen = Set<String>()
        let clean = tags.map { $0.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" } }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return (t, Array(clean.prefix(3)))
    }
}

extension IndexStore {
    public nonisolated(unsafe) static var autoTitle = NSClassFromString("XCTestCase") == nil

    /// Formats whose names usually say enough on their own.
    static let selfTitled: Set<String> = ["md", "markdown", "txt", "text"]
    static let titleBatteryFloor = 30

    /// Files with no title from their extractor, that haven't been asked about yet.
    func untitled(limit: Int) throws -> [(path: String, text: String)] {
        let exts = Self.json(Array(Self.selfTitled))
        let paths = try read { db in
            try db.query("""
                SELECT path FROM files WHERE title IS NULL AND titled_by IS NULL
                AND ext NOT IN (SELECT value FROM json_each(?1)) ORDER BY indexed_at DESC LIMIT ?2
                """, exts, limit) { $0.string(0) }
        }
        return try paths.map { path in
            let text = try read { db in
                try db.query("SELECT substr(text, 1, ?2) FROM sections WHERE path = ?1 ORDER BY ord", path, Titler.maxChars) { $0.string(0) }
            }.filter { !$0.isEmpty }.joined(separator: "\n")
            return (path, text)
        }
    }

    /// Titles and tags untitled files one at a time. Files with almost no text are marked and
    /// skipped. Stops when Ollama isn't there or the Mac is on battery below 30%.
    @discardableResult
    public func titlePending() -> Int {
        let titler = embedding.lock.withLock { embedding.titler }
        var count = 0
        while !Self.onLowBattery(), let next = (try? untitled(limit: 1))?.first {
            let result: (title: String, tags: [String])?
            if next.text.trimmingCharacters(in: .whitespacesAndNewlines).count < 40 {
                result = nil
            } else {
                do {
                    guard let r = try titler.describe(path: next.path, text: next.text) else { break }
                    result = r
                } catch {
                    result = nil
                }
            }
            writeLock.lock()
            try? writer.transaction {
                guard let result else {
                    try writer.run("UPDATE files SET titled_by = ? WHERE path = ? AND title IS NULL", titler.model, next.path)
                    return
                }
                let tags = result.tags.joined(separator: " ")
                try writer.run("UPDATE files SET title = ?, tags = ?, titled_by = ? WHERE path = ? AND title IS NULL",
                               result.title, tags, titler.model, next.path)
                try writer.run("UPDATE sections SET title = ? WHERE path = ? AND ord = 0",
                               Self.fileTitle(result.title, FileRef(relativePath: next.path), tags: tags), next.path)
            }
            writeLock.unlock()
            if result != nil { count += 1 }
        }
        return count
    }

    /// The tags a small model gave this file, if any.
    public func tags(of ref: FileRef) throws -> [String] {
        try read { db in
            try db.query("SELECT tags FROM files WHERE path = ?", ref.relativePath) { $0.optionalString(0) }
        }.first??.split(separator: " ").map(String.init) ?? []
    }

    /// On battery power with less than 30% left.
    static func onLowBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let now = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            if now * 100 / max < titleBatteryFloor { return true }
        }
        return false
    }
}
