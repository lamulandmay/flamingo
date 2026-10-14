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

    /// Long-running index work (reindex, update). Serial.
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

    func scan() async -> ([FileRef], FileTree) {
        let v = vault
        return (try? await onStore {
            let files = VaultScanner.files(in: v)
            return (files, FileTree(files: files))
        }) ?? ([], .empty)
    }

    // MARK: Index

    /// Full reindex (`force` re-extracts unchanged files too). `progress` is delivered on
    /// the main actor, throttled.
    func reindex(force: Bool = false, progress: @escaping @MainActor (Double) -> Void) async {
        guard let index else { return }
        var last = -1.0
        let started = Date()
        Log.debug("reindex: start")
        do {
            try await onIndex {
                try index.reindex(force: force) { p in
                    guard p - last >= 0.01 || p >= 1 else { return }
                    last = p
                    Log.debug("reindex: \(Int(p * 100))% at \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
                    Task { @MainActor in progress(p) }
                }
            }
            Log.debug("reindex: done in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        } catch {
            Log.debug("reindex: failed after \(String(format: "%.2f", Date().timeIntervalSince(started)))s: \(error)")
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
