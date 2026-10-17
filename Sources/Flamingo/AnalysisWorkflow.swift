import Foundation
import FlamingoCore
import FlamingoAsk
import FlamingoTrail

extension AppState {
    /// Persist freshly established endpoint identities in the index before relying on
    /// rename detection. An xattr change does not reliably generate a watcher event.
    func connectionsChanged() async {
        guard let s = session else { return }
        do {
            let store = s.connections
            let endpoints = try await Task.detached(priority: .utility) {
                Array(Set(try store.all().flatMap { [FileRef(relativePath: $0.source), FileRef(relativePath: $0.target)] }))
            }.value
            guard session === s else { return }
            let updated = await s.update(endpoints)
            guard session === s else { return }
            if !updated { continuityError = "Connections saved; rename tracking needs retry: " + (s.indexingError ?? "The index is unavailable.") }
            await refreshGraph()
        } catch {
            guard session === s else { return }
            continuityError = "Connections saved; rename tracking needs retry: " + error.localizedDescription
        }
    }

    /// Native editing is tracked only for files deliberately opened from Flamingo.
    /// A whole-home indexing pass must never become a whole-home AI job.
    func editorFilesChanged(_ refs: [FileRef]) {
        guard let vault else { return }
        for file in refs {
            if let buffer = textBuffers[file.relativePath] { Task { await buffer.diskChanged() } }
        }
        for file in refs where trackedEditorFiles.contains(file) && vault.exists(file) {
            guard let modified = PreviewKind.modificationDate(of: vault.url(for: file)), analyzedStamps[file] != modified else { continue }
            documentSaved(file)
        }
    }

    func documentSaved(_ file: FileRef) {
        guard let session, let modified = PreviewKind.modificationDate(of: session.vault.url(for: file)) else { return }
        trackedEditorFiles.insert(file)
        analyzedStamps[file] = modified
        session.trail.recordSaved(file, anchor: selected == file ? anchor : nil)
        sidebarSearch.refresh()
        if automaticAnalysis { analyzeSavedFile(file) }
        else { Task { await session.update([file]) } }
    }

    func analyzeSavedFile(_ file: FileRef) {
        guard let session, let engine = session.ask else {
            analysisMessage = "Search is unavailable; analysis needs a working index."
            return
        }
        analysisTasks[file]?.cancel()
        analysisMessage = "Saved · waiting for \(file.name) to settle"
        analysisTasks[file] = Task { [weak self] in
            do {
                // Office saves often contain several atomic file replacements. Analyze the final version.
                try await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, self.session === session else { return }
                await session.update([file])
                try Task.checkCancellation()
                let analysis = try await engine.analyze(file: file, reason: "Saved in an editor") { [weak self] status in
                    Task { @MainActor in
                        guard let self, self.session === session else { return }
                        self.analysisMessage = status
                    }
                }
                try Task.checkCancellation()
                guard self.session === session, try engine.analysisFingerprint(for: file) == analysis.fingerprint else { return }
                // Only acknowledged persistence creates the thought and its trail event.
                try await self.saveComment(analysis.comment, to: file)
                self.analysisMessage = "\(file.name) · thought saved · \(analysis.connections.count) suggested connections"
                self.analysisTasks[file] = nil
            } catch is CancellationError {
                // A newer save owns the next analysis. No stale thought is committed.
            } catch {
                guard let self, self.session === session else { return }
                self.analysisMessage = "Analysis needs attention: " + error.localizedDescription
                self.analysisTasks[file] = nil
            }
        }
    }
}
