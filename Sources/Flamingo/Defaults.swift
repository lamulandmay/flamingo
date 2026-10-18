import Foundation
import FlamingoCore

/// Every UserDefaults key the shell touches, in one place. Plan 01 owns.
enum Defaults {
    /// `FLAMINGO_DEFAULTS_SUITE` points every setting here at another suite, so QA never touches
    /// the real ones.
    private static let d: UserDefaults = ProcessInfo.processInfo.environment["FLAMINGO_DEFAULTS_SUITE"]
        .flatMap { UserDefaults(suiteName: $0) } ?? .standard

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

    /// How long ⌘⌥ is held before the recent-files ring opens. A hidden preference.
    static var radialHoldDelay: TimeInterval {
        get { min(max(d.object(forKey: "radialHoldDelay") as? Double ?? 0.30, 0.15), 1) }
        set { d.set(newValue, forKey: "radialHoldDelay") }
    }

    /// Where the lines between tiles sit, per layout. Shared by every vault.
    static var tileFractions: [TileLayout: TileFractions] {
        get {
            guard let data = d.data(forKey: "tileFractions"),
                  let raw = try? JSONDecoder().decode([String: TileFractions].self, from: data) else { return [:] }
            return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in TileLayout(rawValue: key).map { ($0, value) } })
        }
        set {
            let raw = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) })
            if let data = try? JSONEncoder().encode(raw) { d.set(data, forKey: "tileFractions") }
        }
    }

    /// Panels a tiled layout folded away to make room, and how wide each was, so they come back
    /// even after a relaunch. Not the user's own choice, so it is kept apart from the panel keys.
    static var tileAutoHidden: [TilePanel: CGFloat] {
        get {
            let raw = d.dictionary(forKey: "tileAutoHidden") as? [String: Double] ?? [:]
            return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in TilePanel(rawValue: key).map { ($0, CGFloat(value)) } })
        }
        set { d.set(Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, Double($0.value)) }), forKey: "tileAutoHidden") }
    }

    static var railVisible: Bool {
        get { d.object(forKey: "railVisible") as? Bool ?? true }
        set { d.set(newValue, forKey: "railVisible") }
    }

    static var sidebarWidth: CGFloat {
        get { let w = d.double(forKey: "sidebarWidth"); return w == 0 ? 240 : CGFloat(w) }
        set { d.set(Double(newValue), forKey: "sidebarWidth") }
    }

    static var inspectorWidth: CGFloat {
        get { let w = d.double(forKey: "inspectorWidth"); return w == 0 ? 320 : CGFloat(w) }
        set { d.set(Double(newValue), forKey: "inspectorWidth") }
    }

    /// The folder surface's view: Finder columns (the default) or icons.
    static var folderStyle: FolderStyle {
        get { d.string(forKey: "folderStyle").flatMap(FolderStyle.init(rawValue:)) ?? .columns }
        set { d.set(newValue.rawValue, forKey: "folderStyle") }
    }

    static var inspectorTab: InspectorTab {
        get { d.string(forKey: "inspectorTab").flatMap(InspectorTab.init(rawValue:)) ?? .thoughts }
        set { d.set(newValue.rawValue, forKey: "inspectorTab") }
    }

    static var sidebarTab: SidebarTab {
        get { d.string(forKey: "sidebarTab").flatMap(SidebarTab.init(rawValue:)) ?? .files }
        set { d.set(newValue.rawValue, forKey: "sidebarTab") }
    }

    static var sidebarCollapsed: Bool {
        get { d.bool(forKey: "sidebarCollapsed") }
        set { d.set(newValue, forKey: "sidebarCollapsed") }
    }

    static var fileSort: FileSort {
        get { d.string(forKey: "fileSort").flatMap(FileSort.init(rawValue:)) ?? .nameAscending }
        set { d.set(newValue.rawValue, forKey: "fileSort") }
    }

    /// On unless turned off: the explorer has always followed the selection.
    static var autoReveal: Bool {
        get {
            // Until 2026-10-17 the explorer's crosshair toggled this, and clicking it to go to
            // the open file switched following off unseen. The crosshair goes to the file now;
            // following comes back on once, and only Settings changes it after that.
            if !d.bool(forKey: "autoRevealCrosshairReset") {
                d.set(true, forKey: "autoRevealCrosshairReset")
                d.removeObject(forKey: "autoReveal")
            }
            return d.object(forKey: "autoReveal") as? Bool ?? true
        }
        set { d.set(newValue, forKey: "autoReveal") }
    }

    // MARK: Morning inbox

    /// `yyyy-MM-dd` of the last briefing day the morning inbox opened (the day starts at 04:00).
    static var lastBriefingDay: String? {
        get { d.string(forKey: "lastBriefingDay") }
        set { d.set(newValue, forKey: "lastBriefingDay") }
    }

    /// The "Morning Inbox" toggle: open the inbox the first time each day.
    static var briefingAutoOpen: Bool {
        get { d.object(forKey: "briefingAutoOpen") as? Bool ?? true }
        set { d.set(newValue, forKey: "briefingAutoOpen") }
    }

    /// Memo paths (`vault|path`) and the briefing day each was first shown: new that day, seen after.
    static var briefingMemoDays: [String: String] {
        get { d.dictionary(forKey: "briefingMemoDays") as? [String: String] ?? [:] }
        set { d.set(newValue, forKey: "briefingMemoDays") }
    }

    /// The window's frame from before the briefing zoomed it, while the briefing is up, so a quit
    /// in the middle doesn't leave the window filling the screen.
    static var briefingSavedFrame: String? {
        get { d.string(forKey: "briefingSavedFrame") }
        set { d.set(newValue, forKey: "briefingSavedFrame") }
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

    static func showsAllUnpinnedFolders(in vault: Vault) -> Bool {
        d.bool(forKey: key("allUnpinnedFolders", vault))
    }
    static func setShowsAllUnpinnedFolders(_ show: Bool, in vault: Vault) {
        d.set(show, forKey: key("allUnpinnedFolders", vault))
    }

    static func foldedBookmarkGroups(in vault: Vault) -> Set<Int64> {
        Set((d.array(forKey: key("foldedBookmarks", vault)) as? [NSNumber] ?? []).map(\.int64Value))
    }
    static func setFoldedBookmarkGroups(_ ctimes: Set<Int64>, in vault: Vault) {
        d.set(ctimes.sorted().map { NSNumber(value: $0) }, forKey: key("foldedBookmarks", vault))
    }
}
