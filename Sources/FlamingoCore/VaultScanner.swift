import Foundation

/// Lists user files in a vault, skipping `.flamingo`, hidden files, and bundles' internals.
public enum VaultScanner {
    public static let ignoredNames: Set<String> = [".flamingo", ".git", "node_modules", ".DS_Store"]

    public static func files(in vault: Vault) -> [FileRef] {
        // TODO(plan 02): treat .app/.key/.numbers/.pages packages as single files; sort by path.
        var out: [FileRef] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isPackageKey, .isDirectoryKey]
        guard let e = FileManager.default.enumerator(at: vault.root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in e {
            if ignoredNames.contains(url.lastPathComponent) { e.skipDescendants(); continue }
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isPackage == true { e.skipDescendants() }
            guard v?.isRegularFile == true || v?.isPackage == true else { continue }
            if let rel = vault.relativePath(of: url) { out.append(FileRef(relativePath: rel)) }
        }
        return out.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }
}
