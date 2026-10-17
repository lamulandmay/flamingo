import AppKit
import SwiftUI
import FlamingoCore
import FlamingoDesign

/// One place in Finder's sidebar under Favorites: Desktop, Documents, a folder you dragged
/// there, Downloads, Applications.
struct FinderFavorite: Identifiable, Equatable, Sendable {
    let url: URL
    let name: String
    var id: String { url.path }
}

/// Finder's own Favorites list, read from the file Finder keeps it in, in Finder's order.
/// Read-only: Flamingo never rewrites it. Re-read whenever the app comes to the front, so a
/// folder dragged into Finder's sidebar shows up here too. Plan 01 owns.
@MainActor
final class FinderFavoritesModel: ObservableObject {
    @Published private(set) var favorites: [FinderFavorite] = []
    private var observer: NSObjectProtocol?

    init() {
        reload()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func reload() {
        Task {
            let list = await Task.detached(priority: .utility) { FinderFavorites.load() }.value
            if list != favorites { favorites = list }
        }
    }
}

enum FinderFavorites {
    private static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.sharedfilelist", isDirectory: true)

    /// Finder's favorites that are folders on disk. AirDrop, Recents and network places are
    /// not folders and are left out; so are favorites whose folder is gone. Falls back to
    /// Finder's default list when the file can't be read.
    static func load() -> [FinderFavorite] {
        let file = ["sfl4", "sfl3", "sfl2"].lazy
            .map { directory.appendingPathComponent("com.apple.LSSharedFileList.FavoriteItems." + $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        let urls = file.flatMap(readList) ?? defaults
        var seen = Set<String>()
        return urls.compactMap { url in
            var isDir: ObjCBool = false
            guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
                  seen.insert(url.path).inserted else { return nil }
            let name = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? url.lastPathComponent
            return FinderFavorite(url: url, name: name)
        }
    }

    private static var defaults: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [URL(fileURLWithPath: "/Applications", isDirectory: true)]
            + ["Desktop", "Documents", "Downloads"].map { home.appendingPathComponent($0, isDirectory: true) }
    }

    /// The archive is an `NSKeyedArchiver` dictionary whose `items` each carry `Bookmark` data.
    private static func readList(_ file: URL) -> [URL]? {
        guard let data = try? Data(contentsOf: file),
              let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        guard let root = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSDictionary,
              let items = root["items"] as? [NSDictionary] else { return nil }
        return items.compactMap { item in
            guard let bookmark = item["Bookmark"] as? Data else { return nil }
            var stale = false
            return try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                            relativeTo: nil, bookmarkDataIsStale: &stale).standardizedFileURL
        }
    }

    /// Finder's own sidebar glyph for a place: the same SF Symbols, and its Applications
    /// glyph (which has no public symbol) from the system's template.
    static func image(for url: URL, size: CGFloat = Theme.Size.icon) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        if url.path == "/Applications" || url.path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
           let image = applicationsGlyph(size: size) {
            return image
        }
        let symbol = symbolName(for: url)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            ?? NSImage(systemSymbolName: "folder", accessibilityDescription: nil)!
        image.isTemplate = true
        return image
    }

    private static func symbolName(for url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if url.path == home { return "house" }
        guard url.deletingLastPathComponent().path == home else { return "folder" }
        switch url.lastPathComponent {
        case "Desktop": return "menubar.dock.rectangle"
        case "Documents": return "doc"
        case "Downloads": return "arrow.down.circle"
        case "Movies": return "film"
        case "Music": return "music.note"
        case "Pictures": return "photo"
        case "Public": return "person.2"
        case "Library": return "building.columns"
        default: return "folder"
        }
    }

    private static func applicationsGlyph(size: CGFloat) -> NSImage? {
        let path = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/SidebarApplicationsFolder.icns"
        guard let icns = NSImage(contentsOfFile: path) else { return nil }
        // The template is drawn on a 32pt grid with more ink than SF Symbols; nudge it down so
        // it sits at the same optical size as its neighbours.
        let side = (size * 1.15).rounded()
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            icns.draw(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - Sidebar section

/// Finder's Favorites at the top of the Files tab, with Finder's glyphs. A click shows the
/// place in the folder surface, columns or icons, whether or not it is inside the vault.
struct FavoritesList: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var favorites: FinderFavoritesModel
    @ObservedObject var browser: ColumnBrowserModel

    var body: some View {
        if !favorites.favorites.isEmpty {
            VStack(spacing: 0) {
                ForEach(favorites.favorites) { favorite in
                    FavoriteRow(favorite: favorite,
                                selected: state.mode == .files && state.selected == nil && browser.root == favorite.url)
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xs)
            Hairline()
        }
    }
}

private struct FavoriteRow: View {
    @EnvironmentObject var state: AppState
    let favorite: FinderFavorite
    let selected: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(nsImage: FinderFavorites.image(for: favorite.url))
                .renderingMode(.template)
                .foregroundStyle(selected ? Theme.Color.accent : Theme.Color.textSecondary)
                .frame(width: (Theme.Size.icon * 1.35).rounded())
                .accessibilityHidden(true)
            Text(favorite.name)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .flamingoRow(selected: selected)
        .contentShape(Rectangle())
        .onTapGesture { state.openFavorite(favorite.url) }
        .help(favorite.url.path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([favorite.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(favorite.url.path, forType: .string)
            }
        }
    }
}
