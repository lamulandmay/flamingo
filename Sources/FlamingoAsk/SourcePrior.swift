import Foundation

/// How likely a file is to be the user's own material rather than something a tool wrote or
/// installed. On a vault of `~`, keyword and meaning search rank agent transcripts, package
/// headers, build manifests and editor extensions above the user's documents: they are many,
/// long and use every word. A multiplier on a passage's fused rank, never a filter, so a
/// question that only those files answer still finds them.
enum SourcePrior {
    /// 1 for an ordinary file, above 1 for documents, down to 0.03 for hidden, vendored or
    /// generated files. Multiplies across reasons.
    static func weight(_ path: String) -> Double {
        let parts = path.split(separator: "/")
        var w = 1.0
        for (i, part) in parts.dropLast().enumerated() {
            let p = part.lowercased()
            if p.hasPrefix(".") { w *= 0.08; continue }
            if vendored.contains(p) { w *= 0.15; continue }
            if generated.contains(p) { w *= 0.3; continue }
            // `~/Library` is application state, not the user's files.
            if i == 0, p == "library" { w *= 0.15 }
        }
        let name = parts.last.map(String.init) ?? path
        if name.hasPrefix(".") { w *= 0.1 }
        let ext = (name as NSString).pathExtension.lowercased()
        if name.lowercased().hasSuffix(".min.js") { w *= 0.1 }
        else if let e = extensions[ext] { w *= e }
        else if ext.isEmpty, opaqueNames.contains(name.uppercased()) { w *= 0.2 }
        return min(1.5, w)
    }

    /// 1 for prose or code, down to 0.25 for text that is mostly hashes, numbers and
    /// punctuation (manifests, lockfiles, minified data), judged on a sample.
    static func quality(_ text: String) -> Double {
        let sample = text.prefix(1500)
        guard sample.count > 40 else { return 1 }
        var letters = 0, hexRun = 0, hexRuns = 0
        for ch in sample.unicodeScalars {
            if CharacterSet.letters.contains(ch) || ch == " " { letters += 1 }
            if ch.properties.isASCIIHexDigit { hexRun += 1 } else {
                if hexRun >= 16 { hexRuns += 1 }
                hexRun = 0
            }
        }
        if hexRun >= 16 { hexRuns += 1 }
        let share = Double(letters) / Double(sample.count)
        var q = 1.0
        if share < 0.55 { q *= max(0.3, share / 0.55) }
        if hexRuns >= 3 { q *= 0.35 }
        return q
    }

    /// Same text in two places (a file and its copy in a transcript, one header in three
    /// conda environments): the first by rank stands for all.
    static func duplicateKey(_ text: String) -> String {
        let words = QueryPlan.words(String(text.prefix(600)))
        return words.prefix(60).joined(separator: " ")
    }

    private static let vendored: Set<String> = [
        "node_modules", "site-packages", "dist-packages", "vendor", "pods", "carthage", "deriveddata",
        "conda", "miniconda3", "anaconda3", "miniforge3", "pkgs", "envs", "venv", "env", "__pycache__",
        "bower_components", "third_party", "thirdparty", "external", "sdks", "application support",
        "containers", "group containers", "caches", "logs",
    ]
    private static let generated: Set<String> = [
        "build", "dist", "out", "target", "coverage", "tmp", "temp", "cache", "artifacts", "snapshots",
    ]
    private static let extensions: [String: Double] = [
        // The user's own documents.
        "md": 1.3, "markdown": 1.3, "txt": 1.2, "rtf": 1.2, "docx": 1.3, "doc": 1.2, "pages": 1.3,
        "pptx": 1.3, "key": 1.3, "xlsx": 1.2, "numbers": 1.2, "csv": 1.0, "pdf": 1.2, "org": 1.2,
        // Written by tools.
        "jsonl": 0.15, "log": 0.2, "lock": 0.1, "map": 0.1, "sum": 0.1, "json": 0.4, "xml": 0.5,
        "plist": 0.4, "yaml": 0.8, "yml": 0.8, "toml": 0.8, "strings": 0.4, "html": 0.7, "htm": 0.7,
        "svg": 0.2, "css": 0.6, "h": 0.6, "hpp": 0.6, "d.ts": 0.3,
    ]
    private static let opaqueNames: Set<String> = ["RECORD", "METADATA", "WHEEL", "INSTALLER", "LICENSE", "COPYING", "NOTICE"]
}
