import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers
import FlamingoCore
import FlamingoDesign

/// A folder, when no file is open: Finder's column view (`ColumnBrowser`) or its icon view,
/// ⌥⌘3 / ⌥⌘1. Either shows the place `AppState.browser` holds, which follows the sidebar's
/// folder and can also be a Finder favorite outside the vault. A list of search results
/// (SearchResultsView.swift) takes its place while history is on one.
struct FolderSurface: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if state.shownResults != nil {
            SearchResultsSurface(model: state.searchResults)
        } else {
            FolderSurfaceContent(browser: state.browser, agents: state.agentProjects)
        }
    }
}

private struct FolderSurfaceContent: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var browser: ColumnBrowserModel
    @ObservedObject var agents: AgentProjectsModel

    private var followKey: String { (state.vault?.root.path ?? "") + "|" + (state.selectedFolder ?? "") }

    var body: some View {
        Group {
            switch browser.style {
            case .columns: ColumnBrowser(state: state, model: browser, counts: state.commentCounts, dotted: agents.dotted)
            case .icons: IconSurface(browser: browser)
            }
        }
        .task(id: followKey) { if let url = state.sidebarFolderURL { browser.follow(url) } }
    }
}

/// The icon view: the folder's name, then what's in it as Finder-like tiles with real
/// thumbnails. Type to filter. Right-click for new files.
private struct IconSurface: View {
    struct Item: Identifiable, Sendable {
        let url: URL
        let name: String
        let folder: Bool
        /// Vault-relative path; nil outside the vault.
        let path: String?
        var id: String { url.path }
    }
    @EnvironmentObject var state: AppState
    @ObservedObject var browser: ColumnBrowserModel
    @State private var items: [Item] = []
    @State private var failure: String?
    @State private var filter = ""
    /// When the listing last arrived: tiles drawn within moments of it rise in one after
    /// another; tiles scrolled to later are simply there.
    @State private var loadedAt = Date.distantPast
    /// Bumped to list the folder again: a rename outside the vault changes no tree revision.
    @State private var listing = 0
    @FocusState private var filterFocused: Bool
    private var directory: URL? { browser.folder ?? browser.root }
    /// The folder's vault-relative path, nil outside the vault.
    private var folder: String? {
        guard let v = state.vault, let directory, !v.isState(directory) else { return nil }
        return v.relativePath(of: directory)
    }
    private var visible: [Item] { filter.isEmpty ? items : items.filter { $0.name.localizedStandardContains(filter) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                Text(directory.map { FileManager.default.displayName(atPath: $0.path) } ?? state.vault?.name ?? "")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.Color.text)
                    .lineLimit(1)
                Text(items.count.formatted())
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(items.count)))
                    .animation(Theme.Motion.normal, value: items.count)
                Spacer(minLength: Theme.Space.m)
                SearchField(text: $filter, focused: $filterFocused, onExit: { filter = "" })
                    .frame(width: 180)
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.xl)
            .padding(.bottom, Theme.Space.l)
            if let failure {
                Text(failure).font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary)
                    .padding(.horizontal, Theme.Space.xl)
            }
            if items.isEmpty, failure == nil {
                EmptyState("Empty folder")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 118, maximum: 150), spacing: Theme.Space.m, alignment: .top)],
                              alignment: .leading, spacing: Theme.Space.l) {
                        let arriving = Date().timeIntervalSince(loadedAt) < 0.5
                        ForEach(Array(visible.enumerated()), id: \.element.id) { i, item in
                            FolderTile(item: item, arrival: arriving && i < 24 ? i : nil) { listing += 1 }
                        }
                    }
                    .animation(Theme.Motion.normal, value: filter)
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.bottom, Theme.Space.xl)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .contextMenu {
            if let folder {
                Button("New File…") { state.showNewFile() }
                Button("New Note") { state.newNote() }
                Button("New Folder") { state.newFolder() }
                Divider()
                Button("Search in This Folder") { state.showSidebarSearch(SidebarSearchModel.scopedQuery(folder: folder)) }
            }
            if let directory {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
            }
        }
        .task(id: (directory?.path ?? "") + "@" + String(state.treeRevision) + "#" + String(listing)) { await load() }
        .onChange(of: directory) { filter = "" }
    }

    private func load() async {
        guard let directory else { items = []; return }
        let vault = state.vault
        failure = nil
        do {
            items = try await Task.detached(priority: .userInitiated) {
                let rules = vault.map { VaultScanner.ignoreRules(in: $0) }
                let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .localizedNameKey],
                                                                          options: [.skipsHiddenFiles])
                    .compactMap { url -> Item? in
                        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .localizedNameKey])
                        let isFolder = values?.isDirectory == true && !VaultScanner.isPackage(url)
                        let rel = vault.flatMap { v in v.isState(url) ? nil : v.relativePath(of: url) }
                        if let rel, let rules, !VaultScanner.admits(rel, isDirectory: isFolder, ignore: rules) { return nil }
                        return Item(url: ColumnBrowserModel.normal(url), name: values?.localizedName ?? url.lastPathComponent,
                                    folder: isFolder, path: rel)
                    }
                return entries.filter(\.folder).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    + entries.filter { !$0.folder }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }.value
            loadedAt = Date()
        } catch { failure = error.localizedDescription; items = [] }
    }
}

/// One item: a thumbnail (or the family glyph while it renders), the name under it.
/// Right-click ▸ Rename… edits the name in place, as in Finder's icon view.
private struct FolderTile: View {
    @EnvironmentObject var state: AppState
    let item: IconSurface.Item
    @State private var thumbnail: NSImage?
    @State private var hovering = false
    @State private var renaming = false
    /// Its place in the run of tiles rising in as the folder opens; nil when it's simply there.
    private let arrival: Int?
    @State private var shown: Bool
    /// After a rename, so the folder is listed again.
    private let renamed: () -> Void

    init(item: IconSurface.Item, arrival: Int? = nil, renamed: @escaping () -> Void = {}) {
        self.item = item
        self.arrival = arrival
        self.renamed = renamed
        _shown = State(initialValue: arrival == nil)
    }

    private var ref: FileRef? { item.path.map(FileRef.init(relativePath:)) }

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            ZStack {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(Squircle(radius: 3))
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .transition(.blurReplace)
                } else if item.folder {
                    FolderGlyph(size: 40)
                } else {
                    FileGlyph(ext: item.url.pathExtension.lowercased(), size: 34)
                }
            }
            .frame(width: 96, height: 76)
            if renaming {
                RenameField(name: item.url.lastPathComponent, isFolder: item.folder, font: Theme.NS.small,
                            alignment: .center, maxWidth: 110, lines: 3) { new in
                    if state.renameItem(at: item.url, to: new) != nil { renamed() }
                } end: { renaming = false }
            } else {
                Text(item.name)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.Color.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(Theme.Space.s)
        .background(Squircle(radius: Theme.Radius.m)
            .fill(Theme.Color.hover).opacity(hovering ? 1 : 0))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fast, value: hovering)
        .animation(Theme.Motion.normal, value: thumbnail != nil)
        .pressFeedback(shade: Theme.Radius.m)
        .onTapGesture { if !renaming { open() } }
        .help(item.path ?? item.url.path)
        .onDrag { FileHandoff.itemProvider(url: item.url, relativePath: item.path) }
        .contextMenu {
            if !item.folder {
                if let ref { Button("Open Beside") { state.openBeside(ref) } }
                Button("Open in Default App") { NSWorkspace.shared.open(item.url) }
            }
            if state.canRename(item.url) {
                if !item.folder { Divider() }
                Button("Rename…") { renaming = true }
            }
            Button(item.folder ? "Copy Folder" : "Copy File") { FileHandoff.copy(urls: [item.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
        .task(id: item.id) { await loadThumbnail() }
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown ? 1 : 0.94)
        .offset(y: shown ? 0 : 6)
        .onAppear {
            guard let arrival, !shown else { return }
            withAnimation(Theme.Motion.stagger(arrival)) { shown = true }
        }
    }

    private func open() {
        if item.folder, let path = item.path { state.revealFolder(path) }
        else { state.openFromBrowser(item.url, isFolder: item.folder) }
    }

    private func loadThumbnail() async {
        let url = item.url
        guard !item.folder else { return }
        if let cached = ThumbnailCache.shared.object(forKey: url.path as NSString) { thumbnail = cached; return }
        if (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .application) == true {
            // Apps have no Quick Look thumbnail; their icon is what Finder shows.
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 76, height: 76)
            ThumbnailCache.shared.setObject(icon, forKey: url.path as NSString)
            thumbnail = icon
            return
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 76), scale: scale,
                                                   representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
              !Task.isCancelled else { return }
        let image = rep.nsImage
        ThumbnailCache.shared.setObject(image, forKey: url.path as NSString)
        thumbnail = image
    }
}

/// Thumbnails rendered this session, so going back to a folder is instant.
enum ThumbnailCache {
    static let shared: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 600
        return cache
    }()
}
