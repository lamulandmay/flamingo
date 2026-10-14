import Foundation

/// Read-only access to a zip (OOXML, glTF bundles, etc.) through `/usr/bin/unzip`.
/// Opening lists the members once; `read` pulls any number of members with a single
/// `unzip -p` run, so a 200-slide deck costs two process launches, not four hundred.
struct ZipArchive {
    static let unzip = "/usr/bin/unzip"
    /// Members larger than this, uncompressed, are skipped. Guards against zip bombs.
    static let maxMemberSize = 128 << 20

    let url: URL
    /// Member names in archive order, directories excluded.
    let names: [String]
    let sizes: [String: Int]

    init(_ url: URL) throws {
        guard let out = Subprocess.run(Self.unzip, ["-l", url.path], timeout: 20), out.succeeded else {
            throw ExtractError.malformed(url.path)
        }
        self.url = url
        var names: [String] = [], sizes: [String: Int] = [:]
        // "  Length      Date    Time    Name" / "---------  ---------- -----   ----" / rows / footer.
        var inRows = false
        for line in String(decoding: out.stdout, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("---------") { if inRows { break }; inRows = true; continue }
            guard inRows, let (size, name) = Self.row(line), !name.hasSuffix("/") else { continue }
            if sizes[name] == nil { names.append(name) }
            sizes[name] = size
        }
        self.names = names
        self.sizes = sizes
    }

    func contains(_ name: String) -> Bool { sizes[name] != nil }

    /// One member's bytes, or nil if absent, oversized, or unreadable.
    func read(_ name: String) -> Data? { read([name])[name] }

    /// Many members at once, keyed by name. Absent or oversized members are left out.
    func read(_ wanted: [String]) -> [String: Data] {
        let want = Set(wanted)
        let picked = names.filter { want.contains($0) && isSafe($0) }
        guard !picked.isEmpty else { return [:] }
        // unzip -p writes members back to back in archive order; the listing's sizes split them.
        let expected = picked.reduce(0) { $0 + sizes[$1]! }
        if let out = Subprocess.run(Self.unzip, ["-p", url.path] + picked.map(Self.literal), timeout: 60, maxOutput: expected + 1),
           out.status == 0, out.stdout.count == expected {
            var result: [String: Data] = [:]
            var offset = out.stdout.startIndex
            for name in picked {
                let end = offset + sizes[name]!
                result[name] = out.stdout.subdata(in: offset..<end)
                offset = end
            }
            return result
        }
        return extractToDisk(picked)
    }

    /// The first `maxBytes` of a member, however large it is uncompressed; `unzip` is stopped
    /// once that much has arrived. For parts too big to read whole, where a prefix still helps.
    func readPrefix(_ name: String, maxBytes: Int) -> Data? {
        guard sizes[name] != nil, !name.hasPrefix("/"), !name.split(separator: "/").contains(".."),
              let out = Subprocess.run(Self.unzip, ["-p", url.path, Self.literal(name)], timeout: 20,
                                       maxOutput: maxBytes, stopAtMaxOutput: true),
              !out.stdout.isEmpty else { return nil }
        return out.stdout
    }

    /// Members whose names match, in archive order.
    func names(where predicate: (String) -> Bool) -> [String] { names.filter(predicate) }

    /// Slow path for when the stream doesn't add up (a corrupt member, a size the listing got
    /// wrong): extract to a temp dir and keep whatever came out.
    private func extractToDisk(_ picked: [String]) -> [String: Data] {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("flamingo-unzip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil,
              Subprocess.run(Self.unzip, ["-qq", "-o", url.path] + picked.map(Self.literal) + ["-d", tmp.path], timeout: 60) != nil
        else { return [:] }
        var result: [String: Data] = [:]
        for name in picked {
            if let d = try? Data(contentsOf: tmp.appendingPathComponent(name)) { result[name] = d }
        }
        return result
    }

    private func isSafe(_ name: String) -> Bool {
        guard let size = sizes[name], size <= Self.maxMemberSize else { return false }
        return !name.hasPrefix("/") && !name.split(separator: "/").contains("..")
    }

    /// `"     1234  10-14-2026 22:28   dir/name.xml"` → (1234, "dir/name.xml"). By hand: Regex
    /// costs ~20 ms per thousand members.
    private static func row(_ line: Substring) -> (Int, String)? {
        var rest = line.drop(while: { $0 == " " })
        let digits = rest.prefix(while: \.isNumber)
        guard let size = Int(digits) else { return nil }
        rest = rest.dropFirst(digits.count)
        for _ in 0..<2 { // date, time
            rest = rest.drop(while: { $0 == " " })
            guard !rest.isEmpty else { return nil }
            rest = rest.drop(while: { $0 != " " })
        }
        guard rest.hasPrefix("   "), rest.count > 3 else { return nil }
        return (size, String(rest.dropFirst(3)))
    }

    /// unzip treats member arguments as wildcard patterns; escape the pattern characters.
    private static func literal(_ name: String) -> String {
        var s = ""
        for c in name {
            switch c {
            case "[": s += "[[]"
            case "*", "?": s += "[\(c)]"
            default: s.append(c)
            }
        }
        return s
    }
}

/// Resolves OOXML relationship targets (`_rels/*.rels`) relative to the part that owns them.
enum OOXMLPath {
    /// `ppt/slides/slide1.xml` + `../notesSlides/notesSlide1.xml` → `ppt/notesSlides/notesSlide1.xml`.
    static func resolve(_ target: String, from part: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var parts = part.split(separator: "/").map(String.init)
        if !parts.isEmpty { parts.removeLast() }
        for c in target.split(separator: "/") {
            if c == ".." { if !parts.isEmpty { parts.removeLast() } } else if c != "." { parts.append(String(c)) }
        }
        return parts.joined(separator: "/")
    }

    /// The `.rels` part for a given part: `ppt/slides/slide1.xml` → `ppt/slides/_rels/slide1.xml.rels`.
    static func rels(for part: String) -> String {
        let dir = (part as NSString).deletingLastPathComponent
        let file = (part as NSString).lastPathComponent
        return dir.isEmpty ? "_rels/\(file).rels" : "\(dir)/_rels/\(file).rels"
    }

    struct Relationship { var id: String; var type: String; var target: String; var external: Bool }

    /// Parses a `.rels` part. `type` is the last path component of the relationship type URI,
    /// e.g. `slide`, `notesSlide`, `worksheet`, `sharedStrings`, `officeDocument`.
    static func relationships(_ data: Data?, owner part: String) -> [String: Relationship] {
        guard let data, let root = XML.parse(data) else { return [:] }
        var out: [String: Relationship] = [:]
        for r in root.children("Relationship") {
            guard let id = r.attr("Id"), let target = r.attr("Target") else { continue }
            let external = r.attr("TargetMode") == "External"
            let type = (r.attr("Type") ?? "").split(separator: "/").last.map(String.init) ?? ""
            out[id] = Relationship(id: id, type: type, target: external ? target : resolve(target, from: part), external: external)
        }
        return out
    }
}
