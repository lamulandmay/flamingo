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

/// Lists user files in a vault, hidden ones included, skipping `.flamingo`, what the vault's
/// ignore rules exclude, symlinks, and the insides of packages (which are returned as single
/// files). Built to walk a whole disk: `scan` streams, `children(of:)` reads one folder.
public enum VaultScanner {
    /// Names skipped at any depth whatever the ignore file says. Folders are not descended into.
    /// Everything else that used to be hard-coded (`.git`, `node_modules`, ...) is in
    /// `IgnoreRules.defaultText`, which the user can edit.
    public static let ignoredNames: Set<String> = [".flamingo", ".DS_Store"]

    /// Names skipped only directly under the vault root. Empty since the vault became the
    /// whole Mac: `~/Library` is indexed, minus its caches (see `IgnoreRules.defaultText`).
    public static let rootOnlyIgnoredNames: Set<String> = []

    /// Size limits for what gets indexed.
    public struct Limits: Sendable, Equatable {
        /// Files larger than this are indexed by name, extension and size only; their
        /// contents are never extracted.
        public var maxExtractableBytes: Int64
        public init(maxExtractableBytes: Int64) { self.maxExtractableBytes = maxExtractableBytes }

        /// Whether a file of `bytes` may have its contents extracted.
        public func allowsExtraction(ofSize bytes: Int64) -> Bool { bytes <= maxExtractableBytes }
    }

    /// 50 MB: above it a file is metadata only.
    public static let limits = Limits(maxExtractableBytes: 50 * 1024 * 1024)

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

    /// The vault's rules: `<root>/.flamingo/ignore` (or `IgnoreRules.defaultText` while that
    /// file doesn't exist), followed by `<root>/.flamingoignore` if there is one.
    public static func ignoreRules(in vault: Vault) -> IgnoreRules {
        let own = (try? String(contentsOf: vault.ignoreURL, encoding: .utf8)) ?? IgnoreRules.defaultText
        let legacy = (try? String(contentsOf: vault.root.appendingPathComponent(IgnoreRules.fileName), encoding: .utf8)) ?? ""
        return IgnoreRules(text: legacy.isEmpty ? own : own + "\n" + legacy)
    }

    /// Writes `IgnoreRules.defaultText` to `<root>/.flamingo/ignore` unless the file exists.
    /// Returns `true` if it wrote. The shell calls this when a vault opens.
    @discardableResult
    public static func writeDefaultIgnoreFile(in vault: Vault) -> Bool {
        guard !FileManager.default.fileExists(atPath: vault.ignoreURL.path) else { return false }
        return (try? AtomicFile.write(Data(IgnoreRules.defaultText.utf8), to: vault.ignoreURL)) != nil
    }

    /// Whether the scanner would list `relativePath` (a file) or descend into it (a folder),
    /// judged one path at a time: for watchers and incremental updates. `""` (the root) is
    /// admitted. Doesn't touch the disk.
    public static func admits(_ relativePath: String, isDirectory: Bool, ignore: IgnoreRules) -> Bool {
        let path = IgnoreRules.normalize(relativePath)
        guard !path.isEmpty else { return true }
        if path.split(separator: "/").contains(where: { ignoredNames.contains(String($0)) }) { return false }
        return !ignore.isIgnored(path, isDirectory: isDirectory)
    }

    /// Every user file in the vault, honoring the vault's ignore rules, sorted in Finder order
    /// (`localizedStandardCompare` on the relative path, so `file2` precedes `file10`).
    public static func files(in vault: Vault) -> [FileRef] {
        files(in: vault, ignore: ignoreRules(in: vault))
    }

    /// Every user file under `folder` (a vault-relative folder path; `""` is the whole vault),
    /// judged by the vault's rules, sorted in Finder order.
    public static func files(in vault: Vault, under folder: String) -> [FileRef] {
        var out: [FileRef] = []
        scan(in: vault, ignore: ignoreRules(in: vault), under: folder) { out.append($0); return true }
        return out.sorted()
    }

    /// Every user file in the vault, honoring `ignore`, sorted in Finder order. Collects
    /// `scan(in:ignore:under:_:)`, so the same rules apply.
    public static func files(in vault: Vault, ignore: IgnoreRules) -> [FileRef] {
        var out: [FileRef] = []
        scan(in: vault, ignore: ignore) { out.append($0); return true }
        return out.sorted()
    }

    /// Walks the vault and hands each user file to `visit` as it is found, in directory order
    /// (not sorted). Return `false` from `visit` to stop. Nothing is accumulated, so this is
    /// what to use on a whole disk.
    ///
    /// Packages are visited as single files and never descended into. Symlinks are neither
    /// followed nor visited. Directories named in `ignoredNames` are skipped with their
    /// contents, as are directories and files matched by `ignore`. Permission errors skip the
    /// offending entry and continue. `under` restricts the walk to one folder.
    public static func scan(in vault: Vault, ignore: IgnoreRules, under folder: String = "",
                            _ visit: (FileRef) -> Bool) {
        let folder = IgnoreRules.normalize(folder)
        guard admits(folder, isDirectory: true, ignore: ignore) else { return }
        let start = folder.isEmpty ? vault.root : vault.root.appendingPathComponent(folder, isDirectory: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: start, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }
        ) else { return }
        let rootPath = vault.root.path.hasSuffix("/") ? vault.root.path : vault.root.path + "/"

        // `skipDescendants()` is sticky: called after a non-directory item it skips the *next*
        // directory the enumerator reaches. Only ever call it when the current item is a directory.
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            // The enumerator reports symlinks with lstat semantics and never descends into them.
            if values?.isSymbolicLink == true { continue }
            let isDirectory = values?.isDirectory == true

            let path = url.path
            let rel: String
            if path.hasPrefix(rootPath) { rel = String(path.dropFirst(rootPath.count)) }
            else if let r = vault.relativePath(of: url) { rel = r }
            else { if isDirectory { enumerator.skipDescendants() }; continue }

            if rel.isEmpty || ignoredNames.contains(url.lastPathComponent) {
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
            if !visit(FileRef(relativePath: rel)) { return }
        }
    }

    /// `scan` as an `AsyncStream`, run on a background thread at `qos`. Ending the consuming
    /// task (or breaking out of the loop) stops the walk.
    public static func stream(in vault: Vault, ignore: IgnoreRules? = nil, under folder: String = "",
                              qos: DispatchQoS.QoSClass = .utility) -> AsyncStream<FileRef> {
        AsyncStream(bufferingPolicy: .bufferingOldest(4096)) { continuation in
            let stopped = StopFlag()
            continuation.onTermination = { _ in stopped.set() }
            DispatchQueue.global(qos: qos).async {
                let rules = ignore ?? ignoreRules(in: vault)
                scan(in: vault, ignore: rules, under: folder) { ref in
                    // A full buffer drops the file; wait for the consumer instead.
                    while case .dropped = continuation.yield(ref) {
                        if stopped.isSet { return false }
                        usleep(2_000)
                    }
                    return !stopped.isSet
                }
                continuation.finish()
            }
        }
    }

    /// The direct contents of `folder` (vault-relative; `""` is the root), for a lazy tree:
    /// folders first, then files, each sorted by `localizedStandardCompare`. Folder nodes have
    /// no children loaded and a `fileCount` of 0. Same rules as `scan`; packages are files.
    /// Unreadable or missing folders have no children.
    public static func children(of folder: String, in vault: Vault, ignore: IgnoreRules) -> [TreeNode] {
        let folder = IgnoreRules.normalize(folder)
        let dir = folder.isEmpty ? vault.root : vault.root.appendingPathComponent(folder, isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [])
        else { return [] }
        var folders: [TreeNode] = []
        var files: [TreeNode] = []
        for url in urls {
            let name = url.lastPathComponent
            guard !ignoredNames.contains(name) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            let rel = folder.isEmpty ? name : folder + "/" + name
            let package = isPackage(url, values: values)
            if values?.isDirectory == true && !package {
                guard !ignore.verdict(for: rel, isDirectory: true) else { continue }
                var node = TreeNode(id: rel, name: name, ref: nil, isFolder: true)
                node.fileCount = 0
                folders.append(node)
            } else if values?.isRegularFile == true || package {
                guard !ignore.verdict(for: rel, isDirectory: false) else { continue }
                files.append(TreeNode(id: rel, name: name, ref: FileRef(relativePath: rel), isFolder: false))
            }
        }
        let byName: (TreeNode, TreeNode) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return folders.sorted(by: byName) + files.sorted(by: byName)
    }

    /// `children(of:in:ignore:)` with the vault's own rules.
    public static func children(of folder: String, in vault: Vault) -> [TreeNode] {
        children(of: folder, in: vault, ignore: ignoreRules(in: vault))
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

    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

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
