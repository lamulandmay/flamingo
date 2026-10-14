import Foundation
import FlamingoCore

/// Fallback for every format without a native parser: whatever the system's Spotlight importers
/// see. Runs `mdimport -t -d3` (a test import that stores nothing; `-d2` omits
/// `kMDItemTextContent`) and parses the attribute dictionary it prints. If that yields no text,
/// asks `mdls`, which knows only files Spotlight has already indexed and never returns their text.
///
/// The text is `kMDItemTextContent` followed by authors, kind, description, keywords, subject, and
/// headline as plain lines, so searching an author's name finds the file. Section-less. A file no
/// importer understands comes back empty.
///
/// Cost: ~20 ms per file while consecutive files use the same importer, ~0.75 s whenever the
/// importer changes (a `.doc` after an `.odt`). Concurrent calls hide most of that, and callers
/// with many files should order them by extension.
public struct SpotlightExtractor: Extractor {
    public static let extensions: Set<String> = []
    public init() {}

    public func extract(_ url: URL) throws -> Extracted {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ExtractError.unreadable(url.path) }
        var attributes = Self.imported(url)
        if Self.strings(attributes["kMDItemTextContent"]).isEmpty {
            attributes.merge(Self.indexed(url)) { imported, indexed in Self.strings(imported).isEmpty ? indexed : imported }
        }
        return Self.extracted(attributes, fileName: url.lastPathComponent)
    }

    /// The attributes a test import produces, or none if `mdimport` fails.
    static func imported(_ url: URL) -> [String: Any] {
        guard let out = Subprocess.run("/usr/bin/mdimport", ["-t", "-d3", url.path], timeout: 15),
              out.succeeded else { return [:] }
        return parseImport(out.stdout)
    }

    /// The attributes Spotlight's index holds for the file, or none if it isn't indexed.
    static func indexed(_ url: URL) -> [String: Any] {
        let names = ["kMDItemTextContent", "kMDItemTitle", "kMDItemAuthors", "kMDItemKind"]
        guard let out = Subprocess.run("/usr/bin/mdls", names.flatMap { ["-name", $0] } + ["-plist", "-", url.path], timeout: 15),
              out.succeeded,
              let plist = try? PropertyListSerialization.propertyList(from: out.stdout, format: nil) else { return [:] }
        return plist as? [String: Any] ?? [:]
    }

    /// Parses `mdimport -d3` output: a header ("Imported '…' of type … with plugIn …",
    /// "N attributes returned"), then the attributes as an old-style plist dictionary. If one value
    /// isn't valid old-style syntax (NSData prints as `{length = …}`), the dictionary is parsed
    /// entry by entry and the bad entries are dropped.
    static func parseImport(_ output: Data) -> [String: Any] {
        guard let start = output.range(of: Data("\n{\n".utf8))?.lowerBound else { return [:] }
        let body = output[(start + 1)...]
        if let dict = (try? PropertyListSerialization.propertyList(from: body, format: nil)) as? [String: Any] {
            return dict
        }
        // Top-level entries start on lines indented exactly four spaces; quoted strings escape
        // newlines, so an entry's continuation lines are its nested values and closing bracket.
        var entries: [[Substring]] = []
        for line in String(decoding: body, as: UTF8.self).split(separator: "\n").dropFirst() {
            if line.hasPrefix("    "), let c = line.dropFirst(4).first, !" )}".contains(c) {
                entries.append([line])
            } else if !entries.isEmpty, line != "}" {
                entries[entries.count - 1].append(line)
            }
        }
        var dict: [String: Any] = [:]
        for entry in entries {
            let text = "{\n" + entry.joined(separator: "\n") + "\n}"
            if let one = (try? PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil)) as? [String: Any] {
                dict.merge(one) { a, _ in a }
            }
        }
        return dict
    }

    static func extracted(_ a: [String: Any], fileName: String) -> Extracted {
        let body = strings(a["kMDItemTextContent"]).joined(separator: "\n")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = (fileName as NSString).deletingPathExtension
        let title = strings(a["kMDItemTitle"]).first { $0 != fileName && $0 != stem }

        let described = ["kMDItemAuthors", "kMDItemDescription", "kMDItemKeywords", "kMDItemSubject", "kMDItemHeadline"]
        // The kind alone ("Document", "MacBinary archive") is what a file with no importer gets.
        guard !body.isEmpty || title != nil || described.contains(where: { !strings(a[$0]).isEmpty }) else { return .empty }

        var lines = [body]
        for key in ["kMDItemAuthors", "kMDItemKind"] + described.dropFirst() {
            var values = strings(a[key])
            // Some importers report a bare type identifier ("com.apple.iwork.keynote.alt-document").
            if key == "kMDItemKind" { values = values.prefix(1).filter { $0.contains(" ") || !$0.contains(".") } }
            let line = values.joined(separator: ", ")
            if !line.isEmpty, !lines.contains(line) { lines.append(line) }
        }
        return Extracted(text: lines.filter { !$0.isEmpty }.joined(separator: "\n"), title: title)
    }

    /// A value's non-empty strings: arrays flattened, localized dictionaries (`{"" = …; en = …}`)
    /// resolved to the user's language, numbers and the `<null>` marker dropped.
    static func strings(_ value: Any?) -> [String] {
        switch value {
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty || t == "<null>" ? [] : [t]
        case let list as [Any]:
            return list.flatMap { strings($0) }
        case let localized as [String: Any]:
            let key = Bundle.preferredLocalizations(from: Array(localized.keys)).first ?? ""
            return strings(localized[key] ?? localized[""])
        default:
            return []
        }
    }
}
