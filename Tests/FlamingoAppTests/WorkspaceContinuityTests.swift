import AppKit
import XCTest
@testable import Flamingo
import FlamingoCore
import FlamingoIndex
import FlamingoTrail

final class WorkspaceContinuityTests: XCTestCase {
    @MainActor
    func testResumingLocationsReplacesHistoryAndRestoresAnchorsInFilesMode() throws {
        try withWorkspace { state, roots in
            let first = FileRef(relativePath: "Research/first.md")
            let last = FileRef(relativePath: "Writing/last.md")
            let unrelated = FileRef(relativePath: "Other/unrelated.md")
            try write([first, last, unrelated], in: roots[0])
            openStopped(state, at: roots[0])
            state.select(unrelated, anchor: anchor(99), source: .other)
            state.mode = .trail

            state.resumeLocations([
                TrailLocation(file: first, anchor: anchor(3)),
                TrailLocation(file: FileRef(relativePath: "missing.md"), anchor: anchor(7)),
                TrailLocation(file: last, anchor: anchor(12)),
            ])

            XCTAssertEqual(state.mode, .files)
            XCTAssertEqual(state.selected, last)
            XCTAssertEqual(state.selectedFolder, "Writing")
            XCTAssertEqual(state.anchor, anchor(12))
            XCTAssertEqual(state.jumpRequest?.file, last)
            XCTAssertEqual(state.jumpRequest?.anchor, anchor(12))
            XCTAssertEqual(state.openFiles, [first, last])
            XCTAssertEqual(state.history.entries.compactMap(\.file), [first, last])
            XCTAssertEqual(state.history.index, 1)
            XCTAssertEqual(state.history.current?.file, last)
            XCTAssertEqual(state.history.current?.anchor, anchor(12))
            XCTAssertTrue(state.history.entries.allSatisfy { $0.mode == .files })
            XCTAssertEqual(Defaults.workspace(in: Vault(root: roots[0]))?.history.index, 1)

            state.goBack()
            XCTAssertEqual(state.selected, first)
            XCTAssertEqual(state.anchor, anchor(3))
            XCTAssertEqual(state.selectedFolder, "Research")
            XCTAssertEqual(state.mode, .files)
            XCTAssertFalse(state.canGoBack)
            XCTAssertTrue(state.canGoForward)
            state.goForward()
            XCTAssertEqual(state.selected, last)
            XCTAssertEqual(state.anchor, anchor(12))
            XCTAssertEqual(state.selectedFolder, "Writing")
        }
    }

    @MainActor
    func testLegacyResumeDoesNotInsertThePreviouslySelectedTrailFile() throws {
        try withWorkspace { state, roots in
            let first = FileRef(relativePath: "Research/first.md")
            let last = FileRef(relativePath: "Writing/last.md")
            let unrelated = FileRef(relativePath: "Other/unrelated.md")
            try write([first, last, unrelated], in: roots[0])
            openStopped(state, at: roots[0])
            state.select(unrelated, source: .other)
            state.mode = .trail

            state.resume([first, last])

            XCTAssertEqual(state.mode, .files)
            XCTAssertEqual(state.selected, last)
            XCTAssertEqual(state.selectedFolder, "Writing")
            XCTAssertEqual(state.history.entries.compactMap(\.file), [first, last])
            XCTAssertEqual(state.history.current?.file, last)
            state.goBack()
            XCTAssertEqual(state.selected, first)
            XCTAssertEqual(state.selectedFolder, "Research")
            XCTAssertEqual(state.mode, .files)
        }
    }

    @MainActor
    func testSwitchingVaultsRestoresEachWorkspaceWithoutErasingItsSelection() throws {
        try withWorkspace { state, roots in
            let first = FileRef(relativePath: "研究/first.md")
            let last = FileRef(relativePath: "Writing/last.md")
            let other = FileRef(relativePath: "Project B/other.md")
            try write([first, last], in: roots[0])
            try write([other], in: roots[1])
            openStopped(state, at: roots[0])
            state.select(first, anchor: anchor(3), source: .other)
            state.select(last, anchor: anchor(12), source: .other)
            state.mode = .trail
            let firstHistory = state.history.entries

            openStopped(state, at: roots[1])
            XCTAssertNil(state.selected)
            XCTAssertNil(state.selectedFolder)
            state.mode = .files
            state.select(other, anchor: anchor(27), source: .other)
            let secondHistory = state.history.entries

            openStopped(state, at: roots[0])
            XCTAssertEqual(state.selected, last)
            XCTAssertEqual(state.selectedFolder, "Writing")
            XCTAssertEqual(state.anchor, anchor(12))
            XCTAssertEqual(state.mode, .trail)
            XCTAssertEqual(state.openFiles, [first, last])
            assertPlaces(state.history.entries, equal: firstHistory)
            XCTAssertEqual(state.history.current?.file, last)
            XCTAssertEqual(Defaults.lastSelected(in: Vault(root: roots[0])), last)

            state.goBack()
            XCTAssertEqual(state.mode, .files)
            XCTAssertEqual(state.selected, last)
            state.goBack()
            XCTAssertEqual(state.selected, first)
            XCTAssertEqual(state.anchor, anchor(3))
            XCTAssertEqual(state.selectedFolder, "研究")

            openStopped(state, at: roots[1])
            XCTAssertEqual(state.selected, other)
            XCTAssertEqual(state.anchor, anchor(27))
            XCTAssertEqual(state.selectedFolder, "Project B")
            XCTAssertEqual(state.mode, .files)
            XCTAssertEqual(state.openFiles, [other])
            assertPlaces(state.history.entries, equal: secondHistory)
            XCTAssertEqual(Defaults.lastSelected(in: Vault(root: roots[1])), other)
        }
    }

    @MainActor
    func testSwitchingToRememberedFolderClearsThePreviousFileAndAnchor() throws {
        try withWorkspace { state, roots in
            let previous = FileRef(relativePath: "old.md")
            try write([previous], in: roots[0])
            let folder = "研究/Empty project"
            try FileManager.default.createDirectory(at: roots[1].appendingPathComponent(folder), withIntermediateDirectories: true)
            var history = History()
            history.push(.init(file: nil, anchor: nil, mode: .files, folder: folder))
            Defaults.setWorkspace(WorkspaceSnapshot(selected: nil, folder: folder, mode: AppState.Mode.files.rawValue,
                                                     anchors: [:], openFiles: [], history: SavedHistory(history)),
                                  in: Vault(root: roots[1]))
            openStopped(state, at: roots[0])
            state.select(previous, anchor: anchor(8), source: .other)
            openStopped(state, at: roots[1])

            XCTAssertNil(state.selected)
            XCTAssertNil(state.anchor)
            XCTAssertNil(state.jumpRequest)
            XCTAssertEqual(state.selectedFolder, folder)
            XCTAssertTrue(state.openFiles.isEmpty)
            XCTAssertEqual(state.history.current?.folder, folder)
            XCTAssertEqual(Defaults.workspace(in: Vault(root: roots[1]))?.folder, folder)
        }
    }

    @MainActor
    func testMissingRememberedPlacesSurviveFailedOrCancelledStartupAndEarlyVaultSwitch() throws {
        try withWorkspace { state, roots in
            let missing = FileRef(relativePath: "Research/budget.md"), v = Vault(root: roots[0])
            remember(missing, in: v)
            openStopped(state, at: roots[0])
            let s = try XCTUnwrap(state.session)
            XCTAssertNil(state.selected)
            XCTAssertEqual(state.openFiles, [missing])
            XCTAssertEqual(state.history.current?.file, missing)
            state.finishWorkspaceRestoration(in: s, indexOutcome: .failed("Fixture failure"), renamesDrained: true)
            state.finishWorkspaceRestoration(in: s, indexOutcome: .cancelled, renamesDrained: true)
            XCTAssertEqual(state.openFiles, [missing])
            XCTAssertEqual(state.history.current?.anchor, anchor(12))
            openStopped(state, at: roots[1])
            XCTAssertEqual(Defaults.workspace(in: v)?.selected, missing)
            XCTAssertEqual(Defaults.workspace(in: v)?.openFiles, [missing])
            openStopped(state, at: roots[0])
            XCTAssertEqual(state.history.current?.file, missing)
            XCTAssertEqual(state.mode, .graph)
        }
    }

    @MainActor
    func testOnlySuccessfulScanAndDrainedOutboxPruneDeletedPlaces() throws {
        try withWorkspace { state, roots in
            let missing = FileRef(relativePath: "gone.md"), v = Vault(root: roots[0])
            remember(missing, in: v)
            openStopped(state, at: roots[0])
            let s = try XCTUnwrap(state.session)
            state.finishWorkspaceRestoration(in: s, renamesDrained: true)
            XCTAssertEqual(state.openFiles, [missing])
            state.finishWorkspaceRestoration(in: s, indexOutcome: .completed)
            XCTAssertEqual(state.openFiles, [missing])
            state.finishWorkspaceRestoration(in: s, renamesDrained: true)
            XCTAssertTrue(state.openFiles.isEmpty)
            XCTAssertTrue(state.history.entries.isEmpty)
            XCTAssertNil(Defaults.workspace(in: v)?.selected)
        }
    }

    @MainActor
    func testLateStartupResolutionDoesNotReplaceUserSelection() throws {
        try withWorkspace { state, roots in
            let old = FileRef(relativePath: "old.md"), moved = FileRef(relativePath: "new.md"), user = FileRef(relativePath: "user.md")
            let v = Vault(root: roots[0])
            try write([moved, user], in: roots[0])
            remember(old, in: v)
            openStopped(state, at: roots[0])
            state.select(user, anchor: anchor(8), source: .other)
            try PathAliases(vault: v).reconcile(oldPath: old.relativePath, newPath: moved.relativePath)
            state.openFiles.append(moved)
            let s = try XCTUnwrap(state.session)
            state.finishWorkspaceRestoration(in: s, indexOutcome: .completed, renamesDrained: true)
            XCTAssertEqual(state.selected, user)
            XCTAssertEqual(state.anchor, anchor(8))
        }
    }

    @MainActor
    func testOfflineRenameRestoresSelectedTabAnchorAndHistoryAfterInitialIndex() async throws {
        try await withAsyncWorkspace { state, roots in
            let old = FileRef(relativePath: "Research/budget.md"), moved = FileRef(relativePath: "Research/Budget 2027.md")
            let companion = FileRef(relativePath: "notes.md"), v = Vault(root: roots[0])
            try write([old, companion], in: roots[0])
            try ConnectionStore(vault: v).setConnections(between: [old, companion], connected: true)
            let index = try IndexStore(vault: v)
            try index.update([old, companion])
            remember(old, in: v)
            try FileManager.default.moveItem(at: v.url(for: old), to: v.url(for: moved))

            state.open(roots[0])
            XCTAssertEqual(state.openFiles, [old])
            XCTAssertEqual(state.history.current?.file, old)
            let deadline = Date().addingTimeInterval(8)
            while state.selected != moved && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }

            XCTAssertEqual(state.selected, moved)
            XCTAssertEqual(state.anchor, anchor(12))
            XCTAssertEqual(state.jumpRequest?.file, moved)
            XCTAssertEqual(state.mode, .graph)
            XCTAssertEqual(state.openFiles, [moved])
            XCTAssertEqual(state.history.current?.file, moved)
            XCTAssertEqual(state.history.current?.anchor, anchor(12))
            XCTAssertEqual(Defaults.workspace(in: v)?.selected, moved)
            XCTAssertEqual(Wikilink.resolve(old.relativePath, in: v, candidates: [moved, companion]), moved)
            XCTAssertTrue(try ConnectionStore(vault: v).all().contains { $0.source == moved.relativePath || $0.target == moved.relativePath })
            XCTAssertNil(state.continuityError)
        }
    }

    @MainActor
    func testGraphConnectionCallbackIndexesNewEndpointIdentityBeforeExternalRename() async throws {
        try await withAsyncWorkspace { state, roots in
            let old = FileRef(relativePath: "first.md"), companion = FileRef(relativePath: "second.md"), moved = FileRef(relativePath: "renamed.md")
            let v = Vault(root: roots[0])
            try write([old, companion], in: roots[0])
            state.open(roots[0])
            let s = try XCTUnwrap(state.session), index = try XCTUnwrap(s.index)
            s.watcher.stop() // The callback must work without an xattr watcher event.
            let deadline = Date().addingTimeInterval(8)
            while (try index.indexedFiles().count < 2 || state.indexStatus != nil) && Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertEqual(try index.indexedFiles().count, 2)
            XCTAssertNil(try FileIdentity.existingID(for: v.url(for: old)))
            try s.connections.setConnections(between: [old, companion], connected: true)
            await state.connectionsChanged()
            try FileManager.default.moveItem(at: v.url(for: old), to: v.url(for: moved))
            let updated = await s.update([moved])
            XCTAssertTrue(updated)
            XCTAssertTrue(try index.pendingRenames().contains { $0.from == old && $0.to == moved })
            XCTAssertNil(state.continuityError)
        }
    }

    private func remember(_ file: FileRef, in vault: Vault) {
        var history = History()
        history.push(.init(file: file, anchor: anchor(12), mode: .graph, folder: file.directory))
        Defaults.setWorkspace(.init(selected: file, folder: file.directory, mode: AppState.Mode.graph.rawValue,
                                    anchors: [file.relativePath: anchor(12)], openFiles: [file], history: SavedHistory(history)), in: vault)
    }

    private func anchor(_ line: Int) -> FileAnchor { FileAnchor(kind: .line, value: String(line)) }

    private func write(_ files: [FileRef], in root: URL) throws {
        for file in files {
            let url = root.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Fixture content\n".utf8).write(to: url)
        }
    }

    @MainActor
    private func openStopped(_ state: AppState, at root: URL) {
        state.open(root)
        // Exercise the real open/restore path, then cancel watchers and indexing before
        // yielding the main actor. No model request or personal vault is involved.
        state.session?.stop()
    }

    @MainActor
    private func assertPlaces(_ actual: [History.Entry], equal expected: [History.Entry], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, b) in zip(actual, expected) {
            XCTAssertEqual(a.file, b.file, file: file, line: line)
            XCTAssertEqual(a.anchor, b.anchor, file: file, line: line)
            XCTAssertEqual(a.mode, b.mode, file: file, line: line)
            XCTAssertEqual(a.folder, b.folder, file: file, line: line)
        }
    }

    @MainActor
    private func withWorkspace(_ body: (AppState, [URL]) throws -> Void) throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Flamingo-WorkspaceTests-" + UUID().uuidString)
        let roots = [root.appendingPathComponent("A"), root.appendingPathComponent("B")]
        for url in roots { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let defaults = UserDefaults.standard
        let keys = ["lastVault", "recentVaults"] + roots.flatMap { url in
            ["workspace." + url.path, "vault.selected." + url.path, "vault.expanded." + url.path, "vault.foldedBookmarks." + url.path]
        }
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        let state = AppState()
        defer {
            // Selecting nil cancels the delayed opened event before the fixture is removed.
            state.selected = nil
            state.session?.stop()
            for key in keys {
                if let value = saved[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        try body(state, roots)
    }

    @MainActor
    private func withAsyncWorkspace(_ body: (AppState, [URL]) async throws -> Void) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Flamingo-WorkspaceTests-" + UUID().uuidString)
        let roots = [root.appendingPathComponent("A"), root.appendingPathComponent("B")]
        for url in roots { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        let defaults = UserDefaults.standard
        let keys = ["lastVault", "recentVaults"] + roots.flatMap { url in
            ["workspace." + url.path, "vault.selected." + url.path, "vault.expanded." + url.path, "vault.foldedBookmarks." + url.path]
        }
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        let state = AppState()
        defer {
            state.selected = nil
            state.session?.stop()
            for key in keys {
                if let value = saved[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        try await body(state, roots)
    }
}
