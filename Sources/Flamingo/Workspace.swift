import Foundation
import FlamingoCore

struct WorkspaceSnapshot: Codable {
    var selected: FileRef?
    var folder: String?
    var mode: Int
    var anchors: [String: FileAnchor]
    var openFiles: [FileRef]
    var history: SavedHistory
    var split: SavedSplitWorkspace? = nil
}

struct SavedDocumentPane: Codable {
    var file: FileRef?
    var anchor: FileAnchor?
    var anchors: [String: FileAnchor]
    var readSource: Bool
}

/// The panes. `visible`, `activePane`, `primary` and `secondary` are what builds with two panes
/// wrote and still read: they hold slots 0 and 1 (and the active slot as `.primary` or
/// `.secondary`), so an older build shows what it can. `tiles` is authoritative when present;
/// a layout this build can't read is dropped, not fatal, and the legacy fields stand in.
struct SavedSplitWorkspace: Codable {
    var visible: Bool
    var activePane: DocumentPaneID
    var primary: SavedDocumentPane
    var secondary: SavedDocumentPane
    var tiles: SavedTiles? = nil
}

extension SavedSplitWorkspace {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        visible = try c.decode(Bool.self, forKey: .visible)
        activePane = try c.decode(DocumentPaneID.self, forKey: .activePane)
        primary = try c.decode(SavedDocumentPane.self, forKey: .primary)
        secondary = try c.decode(SavedDocumentPane.self, forKey: .secondary)
        tiles = try? c.decodeIfPresent(SavedTiles.self, forKey: .tiles)
    }
}

struct SavedTiles: Codable {
    var layout: TileLayout
    var order: [DocumentPaneID]
    var active: DocumentPaneID
    var panes: [SavedTilePane]
}

struct SavedTilePane: Codable {
    var id: DocumentPaneID
    var pane: SavedDocumentPane
}

struct SavedHistory: Codable {
    struct Place: Codable {
        var file: FileRef?
        var anchor: FileAnchor?
        var mode: Int
        var folder: String?
    }
    var places: [Place]
    var index: Int
    init(_ history: History) {
        places = history.entries.map { Place(file: $0.file, anchor: $0.anchor, mode: $0.mode.rawValue, folder: $0.folder) }
        index = history.index
    }
    func restored(in vault: Vault, preservingMissingFiles: Bool = false) -> History {
        var result = History()
        let survivors = places.enumerated().filter { preservingMissingFiles || ($0.element.file.map { vault.exists($0) } ?? true) }
        let entries = survivors.map {
            History.Entry(file: $0.element.file, anchor: $0.element.anchor, mode: AppState.Mode(rawValue: $0.element.mode) ?? .files, folder: $0.element.folder)
        }
        let pointer = survivors.lastIndex(where: { $0.offset <= index }) ?? (entries.isEmpty ? -1 : 0)
        result.restore(entries: entries, index: pointer)
        return result
    }
}

extension Defaults {
    static func workspace(in vault: Vault) -> WorkspaceSnapshot? {
        UserDefaults.standard.data(forKey: "workspace." + vault.root.path)
            .flatMap { try? JSONDecoder().decode(WorkspaceSnapshot.self, from: $0) }
    }
    static func setWorkspace(_ value: WorkspaceSnapshot, in vault: Vault) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: "workspace." + vault.root.path) }
    }
}
