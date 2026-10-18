import Foundation
import FlamingoCore

/// Which folder is the project when an agent works in `cwd`, or nil when no folder should be
/// offered. The project is the repo: the nearest `.git` above `cwd`, and for a worktree (a
/// `.git` file pointing into `<main>/.git/worktrees/`) the main repo it belongs to. A folder
/// with no repo above it is its own project.
///
/// Never offered: anything outside the vault, the vault root, home, Desktop, Documents,
/// Downloads, system and Library folders, temporary folders, hidden folders, Codex's chat
/// folders, and workspaces (folders holding two or more repos, like `~/claude`).
public struct ProjectResolver: Sendable {
    public var vaultRoot: String
    public var home: String
    /// Folders where nothing is a project: the system's, Library, temporary folders, Codex's chats.
    public var excluded: [String]

    public init(vaultRoot: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.vaultRoot = Self.canonical(vaultRoot.path)
        let home = Self.canonical(home.path)
        self.home = home
        excluded = ["/System", "/Library", "/Applications", "/private", "/usr", "/bin", "/sbin", "/opt", "/var", "/tmp",
                    home + "/Library", home + "/.Trash", home + "/Documents/Codex"]
    }

    public func project(for cwd: String) -> URL? {
        let start = Self.canonical(cwd)
        guard inside(start, vaultRoot) else { return nil }
        let root = repoRoot(above: start) ?? start
        guard root != vaultRoot, inside(root, vaultRoot), !isExcluded(root), !isWorkspace(root) else { return nil }
        return URL(fileURLWithPath: root, isDirectory: true)
    }

    func repoRoot(above path: String) -> String? {
        var current = path
        while true {
            let git = current + "/.git"
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: git, isDirectory: &isDir) {
                if isDir.boolValue { return current }
                return mainRepo(forGitFile: git) ?? current
            }
            if current == vaultRoot || current == "/" { return nil }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    /// `gitdir: <main>/.git/worktrees/<name>` names the main repo. A submodule's gitdir points
    /// into `.git/modules/`; it stays its own project.
    func mainRepo(forGitFile git: String) -> String? {
        guard let text = try? String(contentsOfFile: git, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        var dir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !dir.hasPrefix("/") { dir = ((git as NSString).deletingLastPathComponent as NSString).appendingPathComponent(dir) }
        guard let range = Self.canonical(dir).range(of: "/.git/worktrees/") else { return nil }
        return String(Self.canonical(dir)[..<range.lowerBound])
    }

    func isExcluded(_ path: String) -> Bool {
        let blocked = ["/", home, home + "/Desktop", home + "/Documents", home + "/Downloads"]
        if blocked.contains(path) { return true }
        if excluded.contains(where: { inside(path, $0) }) { return true }
        let relative = path.hasPrefix(vaultRoot + "/") ? String(path.dropFirst(vaultRoot.count + 1)) : path
        return relative.split(separator: "/").contains { $0.hasPrefix(".") }
    }

    func isWorkspace(_ path: String) -> Bool {
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
        var repos = 0
        for child in children where !child.hasPrefix(".") {
            if FileManager.default.fileExists(atPath: path + "/" + child + "/.git") { repos += 1 }
            if repos >= 2 { return true }
        }
        return false
    }

    func inside(_ path: String, _ folder: String) -> Bool {
        folder == "/" ? path.hasPrefix("/") : (path == folder || path.hasPrefix(folder + "/"))
    }

    /// `realpath`, so `/tmp` and `/private/tmp` (and any symlinked folder) compare equal.
    public static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
