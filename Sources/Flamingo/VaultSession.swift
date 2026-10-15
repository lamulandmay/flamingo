import Foundation
import FlamingoCore
import FlamingoIndex
import FlamingoTrail
import FlamingoAsk
import FlamingoExtract

/// stderr diagnostics, on when `FLAMINGO_DEBUG` is set in the environment.
enum Log {
    static let enabled = ProcessInfo.processInfo.environment["FLAMINGO_DEBUG"] != nil
    static func debug(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
        FileHandle.standardError.write("flamingo \(stamp) \(message())\n".data(using: .utf8)!)
    }
}

/// A thread-safe one-way switch.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// Everything that exists only while a vault is open: the stores, the watcher,
/// and the queues that keep their work off the main thread. Plan 01 owns.
@MainActor
final class VaultSession {
    let vault: Vault
    let sidecar: SidecarStore
    let index: IndexStore?
    let trail: TrailStore
    let watcher: VaultWatcher
    let ask: AskEngine?

    /// The full reindex, which can run for hours on a first pass over `~`. Serial.
    private let reindexQueue = DispatchQueue(label: "com.flamingo.reindex", qos: .utility)
    /// Incremental index writes (a comment, a changed file). Serial, separate from the reindex
    /// so a new thought reaches the index between two reindex batches, not after the reindex.
    private let indexQueue = DispatchQueue(label: "com.flamingo.index", qos: .utility)
    /// Short reads and sidecar writes (comments, search, graph, trail). Serial, separate so a
    /// reindex never blocks a search.
    private let storeQueue = DispatchQueue(label: "com.flamingo.store", qos: .userInitiated)
    private(set) var isStopped = false

    init(vault: Vault) {
        self.vault = vault
        try? FileManager.default.createDirectory(at: vault.notesDir, withIntermediateDirectories: true)
        sidecar = SidecarStore(vault: vault)
        var idx: IndexStore? = nil
        do { idx = try IndexStore(vault: vault) } catch {
            FileHandle.standardError.write("flamingo: index unavailable for \(vault.root.path): \(error)\n".data(using: .utf8)!)
        }
        index = idx
        trail = TrailStore(vault: vault)
        watcher = VaultWatcher(vault: vault)
        ask = idx.map { AskEngine(index: $0) }
    }

    func stop() {
        isStopped = true
        cancelled.set()
        watcher.onChange = nil
        watcher.onSidecarChange = nil
        watcher.stop()
        trail.flush()
    }

    // MARK: Queue helpers

    private func onStore<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            storeQueue.async { cont.resume(with: Result { try work() }) }
        }
    }

    private func onIndex<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            indexQueue.async { cont.resume(with: Result { try work() }) }
        }
    }

    // MARK: Files

    /// Set by `stop()`; walks and the reindex check it between files.
    let cancelled = Flag()

    /// Every user file, walked at `.utility` QoS. Unsorted. Empty if the session stops first.
    /// `partial` gets what has been found so far every couple of seconds, so ⌘K can reach
    /// files before a whole-disk walk ends.
    func listFiles(partial: (@MainActor ([FileRef]) -> Void)? = nil) async -> [FileRef] {
        let v = vault
        let cancelled = cancelled
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                var out: [FileRef] = []
                var lastPartial = Date()
                VaultScanner.scan(in: v, ignore: VaultScanner.ignoreRules(in: v)) { ref in
                    out.append(ref)
                    if let partial, out.count % 1024 == 0, Date().timeIntervalSince(lastPartial) > 2 {
                        lastPartial = Date()
                        let snapshot = out
                        Task { @MainActor in partial(snapshot) }
                    }
                    return !cancelled.isSet
                }
                cont.resume(returning: cancelled.isSet ? [] : out)
            }
        }
    }

    /// How the file list changes for these watcher refs, worked out off the main thread:
    /// files to add (a new folder brings everything under it) and listed files to drop (a
    /// vanished folder takes its contents). `known` and `files` are the current list.
    func diskChanges(for refs: [FileRef], known: Set<FileRef>, files: [FileRef]) async -> (added: [FileRef], removed: Set<FileRef>) {
        let v = vault
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let rules = VaultScanner.ignoreRules(in: v)
                var added: [FileRef] = [], removed = Set<FileRef>(), goneFolders: [String] = []
                for ref in refs {
                    let url = v.url(for: ref)
                    var isDir: ObjCBool = false
                    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                    let folder = exists && isDir.boolValue && !VaultScanner.isPackage(url)
                    if !exists || !VaultScanner.admits(ref.relativePath, isDirectory: folder, ignore: rules) {
                        if known.contains(ref) { removed.insert(ref) } else { goneFolders.append(ref.relativePath + "/") }
                    } else if folder {
                        VaultScanner.scan(in: v, ignore: rules, under: ref.relativePath) { f in
                            if !known.contains(f) { added.append(f) }
                            return true
                        }
                    } else if !known.contains(ref) {
                        added.append(ref)
                    }
                }
                if !goneFolders.isEmpty {
                    for f in files where goneFolders.contains(where: { f.relativePath.hasPrefix($0) }) { removed.insert(f) }
                }
                cont.resume(returning: (added, removed))
            }
        }
    }

    // MARK: Index

    /// Where a reindex is. `fraction` is set only by a forced reindex, which knows its total.
    struct IndexStatus: Equatable {
        var files = 0
        var perSecond = 0.0
        var fraction: Double?
    }

    static let reindexBatch = 200

    /// Brings the index up to date with the disk at `.utility` QoS. Streams the vault walk
    /// into `IndexStore.update` `reindexBatch` files at a time, so each batch is committed
    /// and searchable before the walk ends, then drops indexed paths the walk didn't see.
    /// Stops between batches when the session stops. `force` (the menu command) re-extracts
    /// everything through `IndexStore.reindex(force:)`. `progress` runs on the main actor.
    func reindex(force: Bool = false, progress: @escaping @MainActor (IndexStatus) -> Void) async {
        guard let index else { return }
        let started = Date()
        Log.debug("reindex: start")
        if force {
            var last = -1.0
            try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                reindexQueue.async { cont.resume(with: Result {
                try index.reindex(force: true) { p in
                    guard p - last >= 0.01 || p >= 1 else { return }
                    last = p
                    Task { @MainActor in progress(IndexStatus(fraction: p)) }
                }
                }) }
            }
            Log.debug("reindex: forced, done in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            return
        }
        let v = vault
        let sidecar = sidecar
        let cancelled = cancelled
        let finished: Int = await withCheckedContinuation { cont in
            reindexQueue.async {
                let known = Set((try? index.indexedFiles())?.map(\.relativePath) ?? [])
                let rules = VaultScanner.ignoreRules(in: v)
                var seen = Set<String>()
                var batch: [FileRef] = []
                var done = 0
                var lastReport = Date.distantPast
                func flush() {
                    guard !batch.isEmpty else { return }
                    do { try index.update(batch) } catch { Log.debug("reindex: batch failed: \(error)") }
                    done += batch.count
                    batch.removeAll(keepingCapacity: true)
                    let now = Date()
                    guard now.timeIntervalSince(lastReport) >= 0.25 else { return }
                    lastReport = now
                    let status = IndexStatus(files: done, perSecond: Double(done) / max(now.timeIntervalSince(started), 0.001))
                    Task { @MainActor in progress(status) }
                }
                VaultScanner.scan(in: v, ignore: rules) { ref in
                    guard !cancelled.isSet else { return false }
                    seen.insert(ref.relativePath)
                    batch.append(ref)
                    if batch.count >= Self.reindexBatch { flush() }
                    return !cancelled.isSet
                }
                guard !cancelled.isSet else { cont.resume(returning: -1); return }
                flush()
                let gone = known.subtracting(seen).map(FileRef.init(relativePath:))
                try? index.remove(gone)
                // Notes whose file was renamed while we weren't looking, and notes with no
                // file behind them (the inbox): their comments still belong in the index.
                _ = try? sidecar.reconcile()
                let notes = ((try? sidecar.sidecarRefs()) ?? []).filter { !seen.contains($0.relativePath) }
                try? index.update(notes)
                cont.resume(returning: done)
            }
        }
        let seconds = Date().timeIntervalSince(started)
        if finished < 0 {
            Log.debug("reindex: cancelled after \(String(format: "%.2f", seconds))s")
        } else {
            Log.debug("reindex: \(finished) files in \(String(format: "%.2f", seconds))s, \(Int(Double(finished) / max(seconds, 0.001)))/s")
            progress(IndexStatus(files: finished, perSecond: Double(finished) / max(seconds, 0.001)))
        }
    }

    func update(_ refs: [FileRef]) async {
        guard let index, !refs.isEmpty else { return }
        try? await onIndex { try index.update(refs) }
    }

    func remove(_ refs: [FileRef]) async {
        guard let index, !refs.isEmpty else { return }
        try? await onIndex { try index.remove(refs) }
    }

    func search(_ query: String, limit: Int = 50) async -> [SearchHit] {
        guard let index else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return (try? await onStore { try index.search(q, limit: limit) }) ?? []
    }

    func sections(of ref: FileRef) async -> [FlamingoExtract.Section] {
        guard let index else { return [] }
        return (try? await onStore { try index.sections(of: ref) }) ?? []
    }

    func buildGraph() async -> Graph {
        let trail = trail
        guard let index else {
            return Graph(nodes: [], edges: (try? trail.edges()) ?? [])
        }
        return (try? await onStore {
            let extra = (try? trail.edges()) ?? []
            return try index.buildGraph(extraEdges: extra)
        }) ?? Graph()
    }

    // MARK: Comments

    func comments(for ref: FileRef) async -> [Comment] {
        let s = sidecar
        return (try? await onStore { try s.comments(for: ref) }) ?? []
    }

    /// From the index when there is one (cheap), else by walking the sidecars.
    func commentCounts() async -> [FileRef: Int] {
        let s = sidecar
        let index = index
        return (try? await onStore {
            if let index, let counts = try? index.commentCounts() { return counts }
            return try s.all().mapValues(\.count)
        }) ?? [:]
    }

    func append(_ comment: Comment, to ref: FileRef) async throws {
        let s = sidecar
        try await onStore { try s.append(comment, to: ref) }
    }

    func update(_ comment: Comment, in ref: FileRef) async throws {
        let s = sidecar
        try await onStore { try s.update(comment, in: ref) }
    }

    func delete(_ id: UUID, from ref: FileRef) async throws {
        let s = sidecar
        try await onStore { try s.delete(id, from: ref) }
    }

}
