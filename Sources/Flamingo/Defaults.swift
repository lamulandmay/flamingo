import Foundation
import FlamingoCore

/// Every UserDefaults key the shell touches, in one place. Plan 01 owns.
enum Defaults {
    private static let d = UserDefaults.standard

    static var lastVault: String? {
        get { d.string(forKey: "lastVault") }
        set { d.set(newValue, forKey: "lastVault") }
    }

    static var recentVaults: [String] {
        get { d.stringArray(forKey: "recentVaults") ?? [] }
        set { d.set(Array(newValue.prefix(10)), forKey: "recentVaults") }
    }

    static func noteRecent(_ url: URL) {
        var r = recentVaults.filter { $0 != url.path }
        r.insert(url.path, at: 0)
        recentVaults = r
        lastVault = url.path
    }

    static func forgetRecent(_ path: String) {
        recentVaults = recentVaults.filter { $0 != path }
    }

    /// Recent vaults with display titles: the folder name, or `parent/name` when two
    /// recents share a name (copies of the same vault in different places).
    static func recentVaultTitles() -> [(path: String, title: String)] {
        let urls = recentVaults.map { URL(fileURLWithPath: $0) }
        var counts: [String: Int] = [:]
        for u in urls { counts[u.lastPathComponent, default: 0] += 1 }
        return urls.map { u in
            let name = u.lastPathComponent
            let title = counts[name, default: 0] > 1 ? u.deletingLastPathComponent().lastPathComponent + "/" + name : name
            return (u.path, title)
        }
    }

    static var railVisible: Bool {
        get { d.object(forKey: "railVisible") as? Bool ?? true }
        set { d.set(newValue, forKey: "railVisible") }
    }

    static var sidebarWidth: CGFloat {
        get { let w = d.double(forKey: "sidebarWidth"); return w == 0 ? 240 : CGFloat(w) }
        set { d.set(Double(newValue), forKey: "sidebarWidth") }
    }

    // MARK: Per-vault memory

    private static func key(_ name: String, _ vault: Vault) -> String {
        "vault.\(name).\(vault.root.path)"
    }

    static func lastSelected(in vault: Vault) -> FileRef? {
        d.string(forKey: key("selected", vault)).map(FileRef.init(relativePath:))
    }
    static func setLastSelected(_ ref: FileRef?, in vault: Vault) {
        d.set(ref?.relativePath, forKey: key("selected", vault))
    }

    static func expandedFolders(in vault: Vault) -> Set<String>? {
        (d.stringArray(forKey: key("expanded", vault))).map(Set.init)
    }
    static func setExpandedFolders(_ paths: Set<String>, in vault: Vault) {
        d.set(Array(paths).sorted(), forKey: key("expanded", vault))
    }
}
