import Foundation
import FlamingoCore

/// Inspect the real directory, including hidden children, rather than the filtered sidebar.
/// Keep the inspected identity so a confirmation never authorizes a replacement item.
enum FileTrash {
    /// The OS-selected Trash URL is essential: Finder may disambiguate duplicate names.
    final class Receipt {
        let target: Target
        var trashURL: URL
        private var device: UInt64
        private var inode: UInt64
        private var restoredTarget: Target?

        init(target: Target, trashURL: URL) throws {
            self.target = target; self.trashURL = trashURL
            let attributes = try FileManager.default.attributesOfItem(atPath: trashURL.path)
            device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
            inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        }

        func restore() throws {
            let fm = FileManager.default
            let parent = target.url.deletingLastPathComponent()
            let resolved = parent.resolvingSymlinksInPath()
            let root = Vault(root: target.vault.root.resolvingSymlinksInPath())
            guard (resolved.path == root.root.path || root.contains(resolved)), !root.isState(resolved),
                  fm.fileExists(atPath: parent.path) else { throw Failure.protectedPath }
            // attributesOfItem also detects dangling symlinks, unlike fileExists.
            guard (try? fm.attributesOfItem(atPath: target.url.path)) == nil else { throw CocoaError(.fileWriteFileExists) }
            let attributes = try fm.attributesOfItem(atPath: trashURL.path)
            guard (attributes[.systemNumber] as? NSNumber)?.uint64Value == device,
                  (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == inode else { throw Failure.changed }
            try fm.moveItem(at: trashURL, to: target.url)
            restoredTarget = try? FileTrash.inspect(target.path, in: target.vault)
        }

        func inspectRestored() throws -> Target {
            let current = try FileTrash.inspect(target.path, in: target.vault)
            guard let restoredTarget, current.device == restoredTarget.device,
                  current.inode == restoredTarget.inode else { throw Failure.changed }
            return current
        }
    }

    static func trashURL(for url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return result as URL
    }
    struct Target {
        let vault: Vault
        let path: String
        let url: URL
        let isEmptyFolder: Bool
        let device: UInt64
        let inode: UInt64
    }

    enum Failure: LocalizedError {
        case protectedPath, changed, confirmationRequired
        var errorDescription: String? {
            switch self {
            case .protectedPath: "This location cannot be moved to Trash."
            case .changed: "This item changed while confirmation was open. Select it and try again."
            case .confirmationRequired: "This folder now contains items. Confirm before moving it to Trash."
            }
        }
    }

    static func inspect(_ path: String, in vault: Vault) throws -> Target {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              parts.first?.lowercased() != ".flamingo" else { throw Failure.protectedPath }
        let url = vault.root.appendingPathComponent(path)
        // Resolve ancestors, not the leaf: deleting a symlink trashes the link itself.
        let resolvedVault = Vault(root: vault.root.resolvingSymlinksInPath())
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        guard parent.path == resolvedVault.root.path || resolvedVault.contains(parent),
              !resolvedVault.isState(parent) else { throw Failure.protectedPath }
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: url.path)
        let folder = attributes[.type] as? FileAttributeType == .typeDirectory && !VaultScanner.isPackage(url)
        let empty = try folder && fm.contentsOfDirectory(atPath: url.path).isEmpty
        guard let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { throw Failure.changed }
        return Target(vault: vault, path: path, url: url, isEmptyFolder: empty,
                      device: device.uint64Value, inode: inode.uint64Value)
    }

    static func move(_ target: Target, confirmed: Bool,
                     trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        let current = try inspect(target.path, in: target.vault)
        guard current.device == target.device, current.inode == target.inode else { throw Failure.changed }
        guard confirmed || current.isEmptyFolder else { throw Failure.confirmationRequired }
        try trash(current.url)
    }
}
