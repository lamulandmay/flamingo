import Foundation
import AppKit
import FlamingoCore
import FlamingoIndex

extension AppState {
    /// All search surfaces use the same retrieval and scope. Work happens off the UI thread;
    /// a response from a closed vault can never navigate the replacement workspace.
    func unifiedSearch(_ raw: String, includeSemantic: Bool = false, limit: Int = 100) async throws -> UnifiedSearchResponse {
        guard let session else { throw CocoaError(.fileReadUnknown) }
        let index = try await session.searchIndex(for: includeSemantic ? .semantic : .keyword)
        try Task.checkCancellation()
        let query = UnifiedSearchQuery(raw: raw)
        let recent = history.entries.reversed().compactMap { $0.file?.relativePath }
        let preferred = selectedFolder
        let catalog = files
        let directoryPaths = tree.knownFolderPaths
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try index.unifiedSearch(query, recentPaths: recent, preferredFolder: preferred,
                                           limit: limit, includeSemantic: includeSemantic,
                                           directoryPaths: directoryPaths, catalogFiles: catalog,
                                           shouldCancel: { Task.isCancelled })
        }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard self.session === session else { throw CancellationError() }
        return result
    }

    func searchFamily(for file: FileRef) async throws -> ArtifactFamilySnapshot {
        guard let session else { throw CocoaError(.fileReadUnknown) }
        let index = try await session.searchIndex(for: .family)
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try index.fileFamily(for: file, checkCancellation: { try Task.checkCancellation() })
        }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard self.session === session else { throw CancellationError() }
        return result
    }

    func openSearchResult(_ result: UnifiedSearchResult, hit: SearchHit? = nil, query: String = "", externally: Bool = false) {
        recordSearch(query)
        if !externally { NSApp.activate(ignoringOtherApps: true); hostWindow?.makeKeyAndOrderFront(nil) }
        if result.isDirectory {
            if externally { openExternally(result.file) }
            else if let folder = url(for: result.file) { showFolder(folder, focus: true) }
            return
        }
        if externally { openExternally(result.file); return }
        let target = hit ?? result.hits.first
        jump(to: result.file, anchor: target?.anchor)
        sourceHighlight = UnifiedSearchQuery(raw: query).text
        selectedCommentID = target?.commentID
        if target?.commentID != nil { railVisible = true }
    }
}
