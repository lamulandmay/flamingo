import Foundation

/// A node in the folder tree the shell's sidebar shows.
///
/// Folder nodes carry their children; file nodes carry a `FileRef`. `id` is the relative
/// path, so ids are stable across rescans and usable as SwiftUI selection values.
public struct TreeNode: Identifiable, Hashable, Sendable {
    /// Relative path of the folder or file. Never empty.
    public let id: String
    /// Last path component.
    public let name: String
    /// The file this node stands for; `nil` for folders.
    public let ref: FileRef?
    /// `true` for folder nodes.
    public let isFolder: Bool
    /// Folders first, then files; each group sorted by `localizedStandardCompare` on `name`.
    /// `fileCount` is recomputed whenever this is replaced.
    public var children: [TreeNode] {
        didSet { if isFolder { fileCount = TreeNode.totalFiles(in: children) } }
    }
    /// Recursive number of files under this node (1 for a file).
    public var fileCount: Int

    /// Creates a node and computes `fileCount` from `children` (or 1 for a file).
    public init(id: String, name: String, ref: FileRef?, isFolder: Bool, children: [TreeNode] = []) {
        self.id = id
        self.name = name
        self.ref = ref
        self.isFolder = isFolder
        self.children = children
        self.fileCount = isFolder ? TreeNode.totalFiles(in: children) : 1
    }

    private static func totalFiles(in nodes: [TreeNode]) -> Int {
        nodes.reduce(0) { $0 + $1.fileCount }
    }
}

/// Lists user files in a vault, skipping `.flamingo`, hidden files, well-known junk folders,
/// symlinks, and the insides of packages (which are returned as single files).
public enum VaultScanner {
    /// Names skipped at any depth. Folders are not descended into.
    public static let ignoredNames: Set<String> = [
        ".flamingo", ".git", "node_modules", ".DS_Store", "__pycache__", "DerivedData", ".build", ".Trash",
    ]

    /// Names skipped only when directly under the vault root, so `~` works as a vault without
    /// indexing `~/Library` while a project's nested `Library` folder is kept.
    public static let rootOnlyIgnoredNames: Set<String> = ["Library"]

    /// Lowercased extensions of directories that are treated as single files even when
    /// LaunchServices does not flag them as packages (for example on a machine without Keynote).
    public static let packageExtensions: Set<String> = [
        "key", "numbers", "pages", "app", "bundle", "framework", "xcodeproj", "xcworkspace", "playground",
        "photoslibrary", "rtfd", "sketch", "pxd", "band", "logicx", "fcpbundle", "scriv",
    ]

    /// `true` if the URL is flagged as a package by the system, or is a directory whose
    /// lowercased path extension is in `packageExtensions`.
    public static func isPackage(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isPackageKey, .isDirectoryKey])
        return isPackage(url, values: values)
    }

    /// Reads `<root>/.flamingoignore`. Returns `.empty` if the file is absent or unreadable.
    public static func ignoreRules(in vault: Vault) -> IgnoreRules {
        let url = vault.root.appendingPathComponent(IgnoreRules.fileName)
        return (try? IgnoreRules(contentsOf: url)) ?? .empty
    }

    /// Every user file in the vault, honoring `<root>/.flamingoignore`, sorted in Finder order
    /// (`localizedStandardCompare` on the relative path, so `file2` precedes `file10`).
    public static func files(in vault: Vault) -> [FileRef] {
        files(in: vault, ignore: ignoreRules(in: vault))
    }

    /// Every user file in the vault, honoring `ignore`, sorted in Finder order.
    ///
    /// Packages are returned as single files and never descended into. Symlinks are neither
    /// followed nor listed. Directories named in `ignoredNames` (any depth) and
    /// `rootOnlyIgnoredNames` (depth 1) are skipped with their contents, as are directories and
    /// files matched by `ignore`. Permission errors skip the offending entry and continue.
    public static func files(in vault: Vault, ignore: IgnoreRules) -> [FileRef] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: vault.root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return [] }

        // `skipDescendants()` is sticky: called after a non-directory item it skips the *next*
        // directory the enumerator reaches. Only ever call it when the current item is a directory.
        var out: [FileRef] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            // The enumerator reports symlinks with lstat semantics and never descends into them.
            if values?.isSymbolicLink == true { continue }
            let isDirectory = values?.isDirectory == true

            let name = url.lastPathComponent
            if ignoredNames.contains(name) || (enumerator.level == 1 && rootOnlyIgnoredNames.contains(name)) {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            guard let rel = vault.relativePath(of: url), !rel.isEmpty, rel != ".flamingo", !rel.hasPrefix(".flamingo/") else {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }

            let package = isPackage(url, values: values)
            if package { enumerator.skipDescendants() }
            if isDirectory && !package {
                if ignore.verdict(for: rel, isDirectory: true) { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true || package else { continue }
            if ignore.verdict(for: rel, isDirectory: false) { continue }
            out.append(FileRef(relativePath: rel))
        }
        return out.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    /// The folder tree of `files(in:)`. Top-level nodes are the root's direct children.
    public static func tree(in vault: Vault) -> [TreeNode] {
        tree(from: files(in: vault))
    }

    /// The folder tree of `files(in:ignore:)`.
    public static func tree(in vault: Vault, ignore: IgnoreRules) -> [TreeNode] {
        tree(from: files(in: vault, ignore: ignore))
    }

    /// Builds the folder tree from a flat list. Pure. Top-level nodes are the root's direct
    /// children; within every folder, subfolders come first, then files, each group sorted by
    /// `localizedStandardCompare` on name. Duplicate and empty paths are dropped.
    public static func tree(from refs: [FileRef]) -> [TreeNode] {
        let root = FolderBuilder(id: "", name: "")
        var seen: Set<String> = []
        for ref in refs {
            let components = ref.relativePath.split(separator: "/", omittingEmptySubsequences: true)
            guard !components.isEmpty, seen.insert(ref.relativePath).inserted else { continue }
            var folder = root
            var path = ""
            for component in components.dropLast() {
                let name = String(component)
                path = path.isEmpty ? name : path + "/" + name
                if let existing = folder.folders[name] {
                    folder = existing
                } else {
                    let created = FolderBuilder(id: path, name: name)
                    folder.folders[name] = created
                    folder = created
                }
            }
            folder.files.append(ref)
        }
        return root.children()
    }

    // MARK: - Private

    /// Packages are always directories; a plain file with a package extension is just a file.
    private static func isPackage(_ url: URL, values: URLResourceValues?) -> Bool {
        guard values?.isDirectory == true else { return false }
        return values?.isPackage == true || packageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Mutable scaffolding for `tree(from:)`; collapsed into immutable `TreeNode`s at the end.
    private final class FolderBuilder {
        let id: String
        let name: String
        var folders: [String: FolderBuilder] = [:]
        var files: [FileRef] = []

        init(id: String, name: String) {
            self.id = id
            self.name = name
        }

        func node() -> TreeNode {
            TreeNode(id: id, name: name, ref: nil, isFolder: true, children: children())
        }

        func children() -> [TreeNode] {
            let folderNodes = folders.values
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { $0.node() }
            let fileNodes = files
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { TreeNode(id: $0.relativePath, name: $0.name, ref: $0, isFolder: false) }
            return folderNodes + fileNodes
        }
    }
}
