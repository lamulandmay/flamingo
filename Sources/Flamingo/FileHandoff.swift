import AppKit
import FlamingoCore

/// The real file URL is shared with other apps. The private path additionally lets
/// Flamingo recognize its own drags without moving or rewriting the source file.
enum FileHandoff {
    static let relativePathType = NSPasteboard.PasteboardType("com.flamingo.sidebar.path")

    static func pasteboardItem(url: URL, relativePath: String? = nil) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        guard url.isFileURL else { return item }
        item.setString(url.standardizedFileURL.absoluteString, forType: .fileURL)
        if let relativePath, !relativePath.isEmpty {
            item.setString(relativePath, forType: relativePathType)
        }
        return item
    }

    static func itemProvider(url: URL, relativePath: String? = nil) -> NSItemProvider {
        guard url.isFileURL else { return NSItemProvider() }
        let provider = NSItemProvider(object: url.standardizedFileURL as NSURL)
        provider.suggestedName = url.lastPathComponent
        if let relativePath, !relativePath.isEmpty {
            provider.registerDataRepresentation(forTypeIdentifier: relativePathType.rawValue,
                                                visibility: .ownProcess) { completion in
                completion(Data(relativePath.utf8), nil)
                return nil
            }
        }
        return provider
    }

    /// Copies references to existing files, as Finder does, for paste into other
    /// applications. Leaves the clipboard untouched when there is nothing to copy.
    @MainActor
    @discardableResult
    static func copy(urls: [URL], to pasteboard: NSPasteboard = .general) -> Bool {
        var seen = Set<URL>()
        let files = urls.filter { url in
            url.isFileURL && FileManager.default.fileExists(atPath: url.path)
                && seen.insert(url.standardizedFileURL).inserted
        }.map { $0.standardizedFileURL as NSURL }
        guard !files.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(files)
    }

    /// The files on a pasteboard: a Finder copy, or a drag from Finder or Flamingo.
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.map { ColumnBrowserModel.normal($0) }
    }
}

extension AppState {
    /// The selected folder is a valid handoff target when no file is selected.
    @discardableResult
    func copyFiles(_ refs: [FileRef]? = nil) -> Bool {
        let targets = refs ?? selected.map { [$0] }
            ?? selectedFolder.map { [FileRef(relativePath: $0)] } ?? []
        return FileHandoff.copy(urls: targets.compactMap(url(for:)))
    }
}
