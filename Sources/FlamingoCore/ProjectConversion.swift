import Foundation

/// Making an existing folder a project (plan 18, §4): everything `ProjectScaffolder` creates,
/// plus what only a conversion settles. Someone's `CLAUDE.md` or unmarked `AGENTS.md` goes
/// into the new `AGENTS.md` under Rules, Markdown at the root moves into `docs/` (or `plans/`
/// when it is a plan), badly named plans are renamed, and links to anything that moved are
/// rewritten. Nothing is overwritten and no words are thrown away. `apply` returns a
/// `ProjectJournal` that takes it all back while nothing has changed since.
public struct ProjectConversion: Equatable, Sendable {
    public enum Step: Equatable, Sendable, CustomStringConvertible {
        case gitInit
        case createFolder(String)
        /// Moves a file or folder; the destination never exists beforehand.
        case move(from: String, to: String)
        /// Writes `AGENTS.md` (new, or rebuilt around an unmarked one's text).
        case writeAgents(String)
        /// `CLAUDE.md` becomes `@AGENTS.md`; its text went into `AGENTS.md`.
        case resetClaude
        case createFile(String, String)
        case addGitignoreBlock
        /// Links in this Markdown file to moved items are rewritten.
        case rewriteLinks(String)

        public var description: String {
            switch self {
            case .gitInit: "git init"
            case .createFolder(let p): "+ \(p)/"
            case .move(let a, let b): "\(a) → \(b)"
            case .writeAgents: "+ \(ProjectStructure.agents)"
            case .resetClaude: "≈ \(ProjectStructure.claude) → \(ProjectStructure.agents)"
            case .createFile(let p, _): "+ \(p)"
            case .addGitignoreBlock: "~ \(ProjectStructure.gitignore)"
            case .rewriteLinks(let p): "~ \(p) (links)"
            }
        }
    }

    /// A plain mention of a moved file's old name ("read CONTRACT.md"): shown, never rewritten.
    public struct Mention: Equatable, Sendable {
        public var file: String
        public var line: Int
        public var name: String
    }

    public var root: URL
    public var marker: ProjectMarker
    public var steps: [Step]
    public var mentions: [Mention]
    /// What a conversion can't settle (a file where a structure folder belongs, a newer
    /// structure). `apply` refuses while any remain.
    public var blocked: [ProjectIssue]
    /// Old path → new path, for everything that moves.
    public var moves: [String: String] {
        Dictionary(steps.compactMap { if case .move(let a, let b) = $0 { (a, b) } else { nil } }, uniquingKeysWith: { a, _ in a })
    }
}

/// What `ProjectConverter.apply` did, in order, so it can be taken back.
public struct ProjectJournal: Sendable {
    public enum Entry: Sendable {
        case createdRepo
        case createdFolder(String)
        case createdFile(String, Data)
        case moved(from: String, to: String)
        /// The file's bytes before and after Flamingo changed it.
        case rewrote(String, before: Data, after: Data)
    }
    public let root: URL
    public private(set) var entries: [Entry] = []

    mutating func record(_ entry: Entry) { entries.append(entry) }

    /// Puts everything back, all or nothing: if anything Flamingo wrote or moved has changed
    /// since, nothing is touched and this throws.
    public func undo() throws {
        let fm = FileManager.default
        func url(_ path: String) -> URL { root.appendingPathComponent(path) }
        for entry in entries {
            switch entry {
            case .createdFile(let path, let data), .rewrote(let path, _, let data):
                guard (try? Data(contentsOf: url(path))) == data else { throw ProjectStructureError.changed(path) }
            case .moved(_, let to):
                guard fm.fileExists(atPath: url(to).path) else { throw ProjectStructureError.changed(to) }
            case .createdRepo, .createdFolder:
                break
            }
        }
        for entry in entries.reversed() {
            switch entry {
            case .createdFile(let path, _):
                try fm.removeItem(at: url(path))
            case .rewrote(let path, let before, _):
                try before.write(to: url(path), options: .atomic)
            case .moved(let from, let to):
                try fm.createDirectory(at: url(from).deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: url(to), to: url(from))
            case .createdFolder(let path):
                let inside = (try? fm.contentsOfDirectory(atPath: url(path).path)) ?? []
                if inside.allSatisfy({ $0 == ".DS_Store" }) { try? fm.removeItem(at: url(path)) }
            case .createdRepo:
                if !Self.hasCommits(root) { try? fm.removeItem(at: url(".git")) }
            }
        }
    }

    /// A repo Flamingo made is taken back only while it has no commits.
    public static func hasCommits(_ root: URL) -> Bool {
        let git = root.appendingPathComponent(".git")
        guard let head = try? String(contentsOf: git.appendingPathComponent("HEAD"), encoding: .utf8) else { return true }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ref: ") else { return true }
        let ref = String(trimmed.dropFirst(5))
        if FileManager.default.fileExists(atPath: git.appendingPathComponent(ref).path) { return true }
        let packed = (try? String(contentsOf: git.appendingPathComponent("packed-refs"), encoding: .utf8)) ?? ""
        return packed.contains(" " + ref)
    }
}

public enum ProjectConverter {
    /// Folders whose Markdown is never read for links: dependencies and build output.
    static let skippedFolders: Set<String> = ["node_modules", "build", "DerivedData", "Pods", "vendor", "Vendor", "dist", "target"]

    public static func plan(root: URL, name: String? = nil, project: UUID = UUID()) -> ProjectConversion {
        let fm = FileManager.default
        let report = ProjectChecker.check(root: root)
        let marker = report.marker ?? ProjectMarker(project: project)
        var blocked = report.issues.filter {
            switch $0 {
            case .newerStructure, .wrongKind: true
            default: false
            }
        }
        var steps: [ProjectConversion.Step] = []
        var taken = Set<String>()   // destinations claimed by this plan
        func exists(_ path: String) -> Bool { taken.contains(path) || ProjectChecker.kind(root, path) != nil }
        func free(_ path: String) -> String {
            guard exists(path) else { taken.insert(path); return path }
            let dir = (path as NSString).deletingLastPathComponent, file = (path as NSString).lastPathComponent
            let stem = (file as NSString).deletingPathExtension, ext = (file as NSString).pathExtension
            var n = 2
            while true {
                let candidate = (dir.isEmpty ? "" : dir + "/") + "\(stem) \(n)" + (ext.isEmpty ? "" : "." + ext)
                if !exists(candidate) { taken.insert(candidate); return candidate }
                n += 1
            }
        }

        if ProjectChecker.kind(root, ".git") == nil { steps.append(.gitInit) }
        for folder in ProjectStructure.folders where ProjectChecker.kind(root, folder) == nil {
            steps.append(.createFolder(folder))
            taken.insert(folder)
        }

        // Plans: badly named ones get NN-slug.md, numbered after the highest there is.
        var moves: [(String, String)] = []
        var number = highestPlanNumber(root)
        func nextPlan(_ name: String) -> String {
            var candidate: String
            repeat {
                number += 1
                candidate = ProjectStructure.plans + "/" + String(format: "%02d", number) + "-" + slug(name) + ".md"
            } while exists(candidate)
            taken.insert(candidate)
            return candidate
        }
        let planEntries = ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(ProjectStructure.plans).path)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted()
        if ProjectChecker.kind(root, ProjectStructure.plans) == true {
            for entry in planEntries where !ProjectStructure.isPlanName(entry) {
                let from = ProjectStructure.plans + "/" + entry
                if ProjectChecker.kind(root, from) == false, ProjectStructure.isMarkdown(entry) {
                    moves.append((from, nextPlan((entry as NSString).deletingPathExtension)))
                } else {
                    moves.append((from, free(ProjectStructure.docs + "/" + entry)))
                }
            }
        }

        // Loose Markdown at the root, and doc/ or documentation/ folders.
        let rootEntries = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        for entry in rootEntries where ProjectChecker.kind(root, entry) == false && ProjectStructure.isMarkdown(entry)
            && !ProjectStructure.rootMarkdown.contains(entry) {
            let stem = (entry as NSString).deletingPathExtension
            moves.append((entry, looksLikePlan(stem) ? nextPlan(stem) : free(ProjectStructure.docs + "/" + entry)))
        }
        for folder in ["doc", "documentation", "Docs", "Documentation"] where rootEntries.contains(folder) && ProjectChecker.kind(root, folder) == true {
            for child in ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path)) ?? []).sorted() where child != ".DS_Store" {
                moves.append((folder + "/" + child, free(ProjectStructure.docs + "/" + child)))
            }
        }
        steps += moves.map { .move(from: $0.0, to: $0.1) }

        // AGENTS.md: the skeleton, with any unmarked AGENTS.md's and CLAUDE.md's words under Rules.
        let projectName = name ?? root.lastPathComponent
        let existingAgents = report.marker == nil ? ProjectChecker.read(root, ProjectStructure.agents) : nil
        let claude = ProjectChecker.read(root, ProjectStructure.claude)
        let claudeWords = claude.map(claudeText) ?? ""
        if report.marker == nil {
            let carried = [existingAgents.map(demote) ?? "", demote(claudeWords)].filter { !$0.isEmpty }.joined(separator: "\n\n")
            steps.append(.writeAgents(agentsText(name: projectName, project: marker.project, rules: carried)))
        }
        if claude != nil, report.issues.contains(.claudeChanged) { steps.append(.resetClaude) }

        for issue in report.issues {
            switch issue {
            case .missingFile(let file) where file != ProjectStructure.agents:
                steps.append(.createFile(file, ProjectScaffolder.contents(of: file, marker: marker, name: projectName, description: "")))
            case .gitignoreBlockMissing:
                steps.append(ProjectChecker.kind(root, ProjectStructure.gitignore) == nil
                    ? .createFile(ProjectStructure.gitignore, ProjectStructure.gitignoreBlock) : .addGitignoreBlock)
            case .gitignoreBlockChanged:
                blocked.append(issue)
            default:
                break
            }
        }

        // Links and mentions, read from where each file will be.
        let moved = Dictionary(moves, uniquingKeysWith: { a, _ in a })
        var mentions: [ProjectConversion.Mention] = []
        if !moved.isEmpty {
            for file in markdownFiles(root) {
                let now = moved[file] ?? file
                guard let text = try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) else { continue }
                let rewritten = rewriteLinks(text, in: file, becoming: now, moves: moved)
                if rewritten != text { steps.append(.rewriteLinks(now)) }
                mentions += mentionsOf(moved, in: rewritten, file: now)
            }
        }
        return ProjectConversion(root: root, marker: marker, steps: steps, mentions: mentions, blocked: blocked)
    }

    @discardableResult
    public static func apply(_ conversion: ProjectConversion,
                             gitInit: ProjectScaffolder.GitInit = ProjectScaffolder.systemGitInit) throws -> ProjectJournal {
        let fm = FileManager.default
        let root = conversion.root
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { throw ProjectStructureError.notAFolder(root.path) }
        if case .newerStructure(let v)? = conversion.blocked.first(where: { if case .newerStructure = $0 { true } else { false } }) {
            throw ProjectStructureError.newerStructure(v)
        }
        guard conversion.blocked.isEmpty else { throw ProjectStructureError.needsConversion(conversion.blocked) }

        var journal = ProjectJournal(root: root)
        func url(_ path: String) -> URL { root.appendingPathComponent(path) }
        func rewrite(_ path: String, _ change: (String) -> String) throws {
            guard let before = try? Data(contentsOf: url(path)) else { return }
            let after = Data(change(String(decoding: before, as: UTF8.self)).utf8)
            guard after != before else { return }
            try AtomicFile.write(after, to: url(path))
            journal.record(.rewrote(path, before: before, after: after))
        }
        do {
            for step in conversion.steps {
                switch step {
                case .gitInit:
                    guard ProjectChecker.kind(root, ".git") == nil else { continue }
                    try gitInit(root)
                    journal.record(.createdRepo)
                case .createFolder(let folder):
                    guard ProjectChecker.kind(root, folder) == nil else { continue }
                    try fm.createDirectory(at: url(folder), withIntermediateDirectories: false)
                    journal.record(.createdFolder(folder))
                case .move(let from, let to):
                    guard !fm.fileExists(atPath: url(to).path) else { throw ProjectStructureError.changed(to) }
                    let parent = (to as NSString).deletingLastPathComponent
                    if !parent.isEmpty, ProjectChecker.kind(root, parent) == nil {
                        try fm.createDirectory(at: url(parent), withIntermediateDirectories: true)
                        journal.record(.createdFolder(parent))
                    }
                    try fm.moveItem(at: url(from), to: url(to))
                    journal.record(.moved(from: from, to: to))
                case .writeAgents(let text):
                    if let before = try? Data(contentsOf: url(ProjectStructure.agents)) {
                        try AtomicFile.write(Data(text.utf8), to: url(ProjectStructure.agents))
                        journal.record(.rewrote(ProjectStructure.agents, before: before, after: Data(text.utf8)))
                    } else {
                        try Data(text.utf8).write(to: url(ProjectStructure.agents), options: .withoutOverwriting)
                        journal.record(.createdFile(ProjectStructure.agents, Data(text.utf8)))
                    }
                case .resetClaude:
                    try rewrite(ProjectStructure.claude) { _ in ProjectStructure.claudeText }
                case .createFile(let path, let text):
                    do {
                        try Data(text.utf8).write(to: url(path), options: .withoutOverwriting)
                        journal.record(.createdFile(path, Data(text.utf8)))
                    } catch CocoaError.fileWriteFileExists {
                        continue
                    }
                case .addGitignoreBlock:
                    try rewrite(ProjectStructure.gitignore) { text in
                        guard ProjectChecker.gitignoreState(text) == .gitignoreBlockMissing else { return text }
                        let separator = text.isEmpty ? "" : text.hasSuffix("\n\n") ? "" : text.hasSuffix("\n") ? "\n" : "\n\n"
                        return text + separator + ProjectStructure.gitignoreBlock
                    }
                case .rewriteLinks(let path):
                    let old = conversion.moves.first { $0.value == path }?.key ?? path
                    try rewrite(path) { rewriteLinks($0, in: old, becoming: path, moves: conversion.moves) }
                }
            }
        } catch {
            // Half a structure is worse than none: put back what was done, then report.
            try? journal.undo()
            throw error
        }
        return journal
    }

    // MARK: AGENTS.md

    static func agentsText(name: String, project: UUID, rules: String) -> String {
        let skeleton = ProjectStructure.agentsText(name: name, project: project)
        guard !rules.isEmpty else { return skeleton }
        return skeleton.replacingOccurrences(of: "\n## Rules\n", with: "\n## Rules\n\n" + rules + "\n")
    }

    /// CLAUDE.md's own words: its `@AGENTS.md` import line dropped.
    static func claudeText(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces) != "@" + ProjectStructure.agents }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every heading two levels down (at most `######`), so nothing meets the fixed `##` ones.
    static func demote(_ text: String) -> String {
        var fenced = false
        return text.components(separatedBy: "\n").map { line in
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle(); return line }
            guard !fenced, line.hasPrefix("#") else { return line }
            let hashes = line.prefix { $0 == "#" }.count
            guard hashes <= 6, line.dropFirst(hashes).first == " " else { return line }
            return String(repeating: "#", count: min(hashes + 2, 6)) + line.dropFirst(hashes)
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Names

    static func looksLikePlan(_ stem: String) -> Bool {
        let s = stem.lowercased()
        return s == "plan" || s.hasPrefix("plan-") || s.hasPrefix("plan_") || s.hasSuffix("-plan") || s.hasSuffix("_plan")
            || s == "roadmap" || s == "todo"
    }

    /// `DESIGN-REVIEW` → `design-review`; a leading number is dropped (the plan gets a new one).
    static func slug(_ stem: String) -> String {
        var s = stem.lowercased().replacingOccurrences(of: #"^[0-9]+[-_ .]*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s.isEmpty ? "plan" : s
    }

    static func highestPlanNumber(_ root: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(ProjectStructure.plans).path)) ?? []
        return names.filter(ProjectStructure.isPlanName).compactMap { Int($0.prefix { $0.isNumber }) }.max() ?? 0
    }

    // MARK: Links

    /// Markdown files in the project, outside hidden, dependency and build folders.
    static func markdownFiles(_ root: URL) -> [String] {
        let base = root.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [String] = []
        for case let url as URL in walker {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if skippedFolders.contains(url.lastPathComponent) || url.lastPathComponent == ProjectStructure.scratch { walker.skipDescendants() }
                continue
            }
            guard ProjectStructure.isMarkdown(url.lastPathComponent) else { continue }
            out.append(String(url.standardizedFileURL.path.dropFirst(base.count + 1)))
            if out.count >= 5000 { break }
        }
        return out.sorted()
    }

    /// Rewrites `[text](target)` whose target, read from `file`'s folder, moved; and
    /// `[[name]]` for a file whose name changed. The file itself may be moving to `becoming`.
    static func rewriteLinks(_ text: String, in file: String, becoming: String, moves: [String: String]) -> String {
        guard !moves.isEmpty else { return text }
        let fromDir = (file as NSString).deletingLastPathComponent
        let toDir = (becoming as NSString).deletingLastPathComponent
        var out = text
        // [text](target "title"), skipping URLs and anchors.
        if let pattern = try? NSRegularExpression(pattern: #"\]\(([^)\s#]+)(#[^)\s]*)?((?:\s+"[^"]*")?)\)"#) {
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let targetRange = Range(match.range(at: 1), in: text) else { continue }
                let target = String(text[targetRange])
                guard !target.contains("://"), !target.hasPrefix("mailto:") else { continue }
                let decoded = target.removingPercentEncoding ?? target
                let resolved = normalize(target.hasPrefix("/") ? String(decoded.dropFirst()) : (fromDir as NSString).appendingPathComponent(decoded))
                let destination: String
                if let moved = moves[resolved] { destination = moved }
                else if moves.isEmpty == false, fromDir != toDir, !resolved.hasPrefix("..") { destination = resolved }
                else { continue }
                let relative = relativePath(from: toDir, to: destination)
                let encoded = target == decoded ? relative : (relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relative)
                guard let outRange = Range(match.range(at: 1), in: out) else { continue }
                if encoded != target { out.replaceSubrange(outRange, with: encoded) }
            }
        }
        // [[name]] / [[name.md]] / [[name|alias]] / [[name#heading]] for renamed files.
        let renamed = moves.compactMap { from, to -> (String, String)? in
            let a = ((from as NSString).lastPathComponent as NSString).deletingPathExtension
            let b = ((to as NSString).lastPathComponent as NSString).deletingPathExtension
            return a == b ? nil : (a, b)
        }
        for (old, new) in renamed {
            for suffix in ["]]", "|", "#", ".md]]", ".md|", ".md#"] {
                out = out.replacingOccurrences(of: "[[" + old + suffix, with: "[[" + new + suffix)
            }
        }
        return out
    }

    static func mentionsOf(_ moves: [String: String], in text: String, file: String) -> [ProjectConversion.Mention] {
        let names = Set(moves.keys.map { ($0 as NSString).lastPathComponent }).filter { $0.contains(".") }
        guard !names.isEmpty else { return [] }
        var out: [ProjectConversion.Mention] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            for name in names where line.contains(name) {
                // A link to it was rewritten already; a mention is what's left in prose.
                let stripped = line.replacingOccurrences(of: #"\]\([^)]*\)"#, with: "", options: .regularExpression)
                if stripped.contains(name) { out.append(.init(file: file, line: index + 1, name: name)) }
            }
        }
        return out
    }

    static func normalize(_ path: String) -> String {
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == "..", let last = parts.last, last != ".." { parts.removeLast(); continue }
            parts.append(String(part))
        }
        return parts.joined(separator: "/")
    }

    static func relativePath(from dir: String, to path: String) -> String {
        let a = dir.split(separator: "/").map(String.init), b = path.split(separator: "/").map(String.init)
        var common = 0
        while common < a.count, common < b.count - 1, a[common] == b[common] { common += 1 }
        let up = Array(repeating: "..", count: a.count - common)
        return (up + b[common...]).joined(separator: "/")
    }
}
