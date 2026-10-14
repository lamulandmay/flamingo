import Foundation

/// Read-only access to a zip (OOXML, glTF bundles, etc.) through `/usr/bin/unzip`.
/// Opening lists the members once; `read` pulls any number of members with a single
/// `unzip` run, so a 200-slide deck costs two process launches, not four hundred.
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
        for line in String(decoding: out.stdout, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("---------") { if inRows { break }; inRows = true; continue }
            guard inRows, let m = line.wholeMatch(of: #/\s*(\d+)\s+\S+\s+\S+\s{3}(.+)/#) else { continue }
            let name = String(m.2)
            guard !name.hasSuffix("/") else { continue }
            names.append(name)
            sizes[name] = Int(m.1) ?? 0
        }
        self.names = names
        self.sizes = sizes
    }

    func contains(_ name: String) -> Bool { sizes[name] != nil }

    /// One member's bytes, or nil if absent, oversized, or unreadable.
    func read(_ name: String) -> Data? { read([name])[name] }

    /// Many members at once, keyed by name. Absent or oversized members are left out.
    func read(_ wanted: [String]) -> [String: Data] {
        let picked = Array(Set(wanted.filter(isSafe)))
        guard !picked.isEmpty else { return [:] }
        if picked.count == 1 {
            let name = picked[0]
            guard let out = Subprocess.run(Self.unzip, ["-p", url.path, Self.literal(name)], timeout: 20),
                  out.succeeded else { return [:] }
            return [name: out.stdout]
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("flamingo-unzip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil,
              let out = Subprocess.run(Self.unzip, ["-qq", "-o", url.path] + picked.map(Self.literal) + ["-d", tmp.path], timeout: 60),
              out.status == 0 || out.status == 1 // 1 = warnings, members still extracted
        else { return [:] }
        var result: [String: Data] = [:]
        for name in picked {
            if let d = try? Data(contentsOf: tmp.appendingPathComponent(name)) { result[name] = d }
        }
        return result
    }

    /// Members whose names match, in archive order.
    func names(where predicate: (String) -> Bool) -> [String] { names.filter(predicate) }

    private func isSafe(_ name: String) -> Bool {
        guard let size = sizes[name], size <= Self.maxMemberSize else { return false }
        return !name.hasPrefix("/") && !name.split(separator: "/").contains("..")
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
