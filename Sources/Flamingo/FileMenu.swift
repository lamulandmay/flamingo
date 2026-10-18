import AppKit
import UniformTypeIdentifiers
import FlamingoCore

/// The context menu for a file or folder, the same in the file explorer and the columns, so
/// either can do what the other can. `url` can be anywhere on the Mac; what needs the vault
/// (thoughts, bookmarks, new notes, trash with undo) appears only for what is in it. The
/// list showing the item supplies what only it can do: open, rename in place, Quick Look.
/// Plan 01 owns.
@MainActor
enum FileMenu {
    struct Host {
        var open: () -> Void
        /// Starts renaming the row in place; nil where the item can't be renamed.
        var rename: (() -> Void)?
        var quickLook: (() -> Void)?
        var window: NSWindow?
        /// The list's own items (the columns' Sort By), in a section before Move to Trash.
        var extra: [NSMenuItem] = []
    }

    /// Fills `menu` for one item.
    static func build(_ menu: NSMenu, url: URL, isFolder: Bool, state: AppState, host: Host) {
        let rel = vaultPath(url, state: state)
        let ref = rel.map(FileRef.init(relativePath:))
        menu.addItem(ActionItem("Open", run: host.open))
        if isFolder {
            if let rel { addNewItems(to: menu, folder: rel, state: state) }
            if let rel {
                menu.addItem(ActionItem("Search in Folder") { state.showSidebarSearch(SidebarSearchModel.scopedQuery(folder: rel)) })
            }
        } else {
            if let ref { menu.addItem(ActionItem("Open Beside") { state.openBeside(ref) }) }
            if !isApplication(url) {
                menu.addItem(ActionItem("Open in " + (appName(for: url) ?? "Default App")) {
                    if let ref { state.openExternally(ref) } else if !NSWorkspace.shared.open(url) { NSSound.beep() }
                })
            }
        }
        if let quickLook = host.quickLook { menu.addItem(ActionItem("Quick Look", run: quickLook)) }
        if let ref, !isFolder {
            menu.addItem(ActionItem("Leave a Thought") {
                state.select(ref, source: .other)
                state.leaveThought()
            })
        }

        menu.addItem(.separator())
        if isFolder { addPaste(to: menu, folder: url, state: state, separated: false) }
        if let rename = host.rename { menu.addItem(ActionItem("Rename…", run: rename)) }
        if let rel {
            let marked = state.isBookmarked(rel, folder: isFolder)
            let title = isFolder ? (marked ? "Unpin Folder" : "Pin Folder") : (marked ? "Remove Bookmark" : "Bookmark")
            menu.addItem(ActionItem(title) { state.toggleBookmark(path: rel, folder: isFolder) })
        }

        menu.addItem(.separator())
        addFinderItems(to: menu, url: url, isFolder: isFolder)
        if !host.extra.isEmpty {
            menu.addItem(.separator())
            for item in host.extra { menu.addItem(item) }
        }
        if let rel {
            menu.addItem(.separator())
            menu.addItem(ActionItem("Move to Trash") { state.requestTrash(rel, in: host.window) })
        }
    }

    /// Fills `menu` for the empty space under a list of `folder`.
    static func buildBackground(_ menu: NSMenu, folder: URL, state: AppState, extra: [NSMenuItem] = []) {
        if let rel = vaultFolder(folder, state: state) {
            addNewItems(to: menu, folder: rel, state: state)
            menu.addItem(.separator())
        }
        addPaste(to: menu, folder: folder, state: state, separated: true)
        menu.addItem(ActionItem("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) })
        for item in extra { menu.addItem(item) }
    }

    // MARK: Pieces

    private static func addNewItems(to menu: NSMenu, folder rel: String, state: AppState) {
        menu.addItem(ActionItem("New File…") { state.showNewFile(in: rel) })
        menu.addItem(ActionItem("New Note") { state.newNote(in: rel) })
        menu.addItem(ActionItem("New Folder") { state.newFolder(in: rel) })
    }

    /// "Paste Item" or "Paste 3 Items" when the clipboard holds files, as Finder offers.
    private static func addPaste(to menu: NSMenu, folder: URL, state: AppState, separated: Bool) {
        let count = FileHandoff.fileURLs(on: .general).count
        guard count > 0 else { return }
        menu.addItem(ActionItem(count == 1 ? "Paste Item" : "Paste \(count) Items") { state.paste(into: folder, moving: false) })
        if separated { menu.addItem(.separator()) }
    }

    private static func addFinderItems(to menu: NSMenu, url: URL, isFolder: Bool) {
        menu.addItem(ActionItem("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        menu.addItem(ActionItem(isFolder ? "Copy Folder" : "Copy File") { FileHandoff.copy(urls: [url]) })
        menu.addItem(ActionItem("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        })
    }

    /// A user file's vault-relative path; nil outside the vault, for its root and for
    /// Flamingo's own state.
    static func vaultPath(_ url: URL, state: AppState) -> String? {
        guard let v = state.vault, let rel = v.relativePath(of: url), !rel.isEmpty, !v.isState(url) else { return nil }
        return rel
    }

    /// Like `vaultPath`, but the vault's root is "".
    static func vaultFolder(_ url: URL, state: AppState) -> String? {
        guard let v = state.vault else { return nil }
        if url.standardizedFileURL.path == v.root.standardizedFileURL.path { return "" }
        return vaultPath(url, state: state)
    }

    private static func isApplication(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .application) == true
    }

    /// The app that would open the file, for "Open in Keynote".
    private static func appName(for url: URL) -> String? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return (try? app.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? app.deletingPathExtension().lastPathComponent
    }
}

/// A context-menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func runAction() { run() }
}
