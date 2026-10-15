import Foundation
import FlamingoCore

/// `VaultScanner`'s rules for a single path, for code that sees paths one at a time
/// (`IndexStore.update`, `VaultWatcher`) rather than walking the vault.
struct PathRules {
    let ignore: IgnoreRules

    init(vault: Vault) { ignore = VaultScanner.ignoreRules(in: vault) }
    init(ignore: IgnoreRules) { self.ignore = ignore }

    /// Whether the scanner would list this path (or descend into it, for a folder).
    func admits(_ relativePath: String, isDirectory: Bool) -> Bool {
        VaultScanner.admits(relativePath, isDirectory: isDirectory, ignore: ignore)
    }
}
