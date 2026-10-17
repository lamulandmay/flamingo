import Foundation
import Darwin
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
    let connections: ConnectionStore
    let dismissed: DismissedConnectionStore
    private(set) var startupError: String?
    var onIndexingError: ((String?) -> Void)?
    private(set) var indexingError: String? { didSet {
        if indexingError != nil { indexFailureGeneration &+= 1 }
        onIndexingError?(indexingError)
    } }
    private var indexFailureGeneration = 0
    private(set) var indexCancellationGeneration = 0

    /// The full reindex, which can run for hours on a first pass over `~`. Serial.
    private let reindexQueue = DispatchQueue(label: "com.flamingo.reindex", qos: .utility)
    /// Incremental index writes (a comment, a changed file). Serial, separate from the reindex
    /// so a new thought reaches the index between two reindex batches, not after the reindex.
    private let indexQueue = DispatchQueue(label: "com.flamingo.index", qos: .utility)
    /// Short reads and sidecar writes (comments, search, graph, trail). Serial, separate so a
    /// reindex never blocks a search.
    private let storeQueue = DispatchQueue(label: "com.flamingo.store", qos: .userInitiated)
    private(set) var isStopped = false
    enum SearchIndexPurpose: Hashable { case keyword, semantic, family }
    private var searchReaders: [SearchIndexPurpose: Task<IndexStore, Error>] = [:]

    /// Graph construction and embedding maintenance can hold the ordinary reader for
    /// minutes on a home folder. Interactive retrieval gets independent WAL readers.
    func searchIndex(for purpose: SearchIndexPurpose) async throws -> IndexStore {
        guard index != nil, !isStopped else { throw CancellationError() }
        if let task = searchReaders[purpose] { return try await task.value }
        let vault = vault
        let task = Task.detached(priority: .userInitiated) { try IndexStore(vault: vault, readOnly: true) }
        searchReaders[purpose] = task
        do {
            let result = try await task.value
            guard !isStopped else { throw CancellationError() }
            return result
        } catch {
            searchReaders[purpose] = nil
            throw error
        }
    }

    /// Injectable enumeration keeps scan/event ordering testable without real user files.
    nonisolated private let fileScanner: (Vault, IgnoreRules, (FileRef) -> Bool) -> Void

    init(vault: Vault, fileScanner: @escaping (Vault, IgnoreRules, (FileRef) -> Bool) -> Void = {
        vault, rules, visit in VaultScanner.scan(in: vault, ignore: rules, visit)
    }) {
        self.vault = vault
        self.fileScanner = fileScanner
        connections = ConnectionStore(vault: vault)
        dismissed = DismissedConnectionStore(vault: vault)
        try? FileManager.default.createDirectory(at: vault.notesDir, withIntermediateDirectories: true)
        sidecar = SidecarStore(vault: vault)
        var idx: IndexStore? = nil
        do { idx = try IndexStore(vault: vault) } catch {
            startupError = error.localizedDescription
            FileHandle.standardError.write("flamingo: index unavailable for \(vault.root.path): \(error)\n".data(using: .utf8)!)
        }
        index = idx
        trail = TrailStore(vault: vault)
        watcher = VaultWatcher(vault: vault)
        ask = idx.map { AskEngine(index: $0) }
    }

    func stop() {
        isStopped = true
        for reader in searchReaders.values { reader.cancel() }
        searchReaders.removeAll()
        cancelled.set()
        index?.cancelBackgroundWork()
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

    /// Graph builds read the whole index; on a disk-sized vault they take seconds, so they
    /// get their own queue rather than holding up searches and comment reads.
    private let graphQueue = DispatchQueue(label: "com.flamingo.graph", qos: .utility)

    private func onGraph<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            graphQueue.async { cont.resume(with: Result { try work() }) }
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
    private var indexCancelled = Flag()

    func cancelIndexing() {
        indexCancelled.set()
        indexCancellationGeneration &+= 1
    }

    /// The canonical file list. Touched only on `filesQueue`; the main thread gets snapshots.
    private final class Listing: @unchecked Sendable {
        var files: [FileRef] = []
        var set: Set<FileRef> = []
        var complete = false
        var scanning = false
        var pending = Set<FileRef>()
    }
    private var fileListTask: Task<([FileRef], Set<FileRef>), Never>?
    private var listingGeneration = 0
    private let listing = Listing()
    private let filesQueue = DispatchQueue(label: "com.flamingo.files", qos: .utility)

    /// Every user file, walked at `.utility` QoS, unsorted, with the same files as a set
    /// (built here so the main thread never hashes a whole disk). Empty if the session stops
    /// first. `partial` gets what has been found so far every couple of seconds, so ⌘K can
    /// reach files before a whole-disk walk ends.
    func listFiles(partial: (@MainActor ([FileRef], Set<FileRef>) -> Void)? = nil) async -> ([FileRef], Set<FileRef>) {
        if let task = fileListTask {
            // A rescan requested during the first walk must replay fresh rules before
            // publishing, rather than launching another walk that can overwrite it.
            let listing = listing
            filesQueue.async { listing.pending.insert(FileRef(relativePath: "")) }
            return await task.value
        }
        listingGeneration &+= 1
        let generation = listingGeneration
        let v = vault, cancelled = cancelled, listing = listing, filesQueue = filesQueue
        // With a checkpoint the index already lists every file as of then, and the watcher's
        // replay patches the rest: a second walk of the disk at launch would only repeat it.
        let scan = checkpoint == nil || index == nil ? fileScanner : Self.indexedFiles
        let task = Task { [self] () -> ([FileRef], Set<FileRef>) in
            await withCheckedContinuation { cont in
                filesQueue.async {
                    listing.scanning = true
                    DispatchQueue.global(qos: .utility).async {
                        var out: [FileRef] = [], set = Set<FileRef>()
                        var lastPartial = Date()
                        scan(v, VaultScanner.ignoreRules(in: v)) { ref in
                            out.append(ref); set.insert(ref)
                            if let partial, out.count % 1024 == 0, Date().timeIntervalSince(lastPartial) > 2 {
                                lastPartial = Date()
                                let (list, members) = (out, set)
                                Task { @MainActor [weak self] in
                                    guard let self, self.listingGeneration == generation, !cancelled.isSet,
                                          self.fileListTask != nil else { return }
                                    partial(list, members)
                                }
                            }
                            return !cancelled.isSet
                        }
                        filesQueue.async {
                            guard !cancelled.isSet else {
                                listing.scanning = false; listing.pending.removeAll()
                                cont.resume(returning: ([], [])); return
                            }
                            var rootDirectory: ObjCBool = false
                            guard FileManager.default.fileExists(atPath: v.root.path, isDirectory: &rootDirectory), rootDirectory.boolValue else {
                                listing.scanning = false
                                cont.resume(returning: (listing.files, listing.set)); return
                            }
                            let rules = VaultScanner.ignoreRules(in: v)
                            // A skipped/unreadable directory is not proof its files vanished.
                            for known in listing.files where !set.contains(known) {
                                var info = stat()
                                let result = lstat(v.url(for: known).path, &info), code = errno
                                let exists = result == 0 && ((info.st_mode & S_IFMT) == S_IFREG || VaultScanner.isPackage(v.url(for: known)))
                                let unavailable = result != 0 && code != ENOENT && code != ENOTDIR
                                if (exists || unavailable) && VaultScanner.admits(known.relativePath, isDirectory: false, ignore: rules) {
                                    out.append(known); set.insert(known)
                                }
                            }
                            (listing.files, listing.set, listing.complete) = (out, set, true)
                            // Events are queued even before a first snapshot exists. Replay
                            // them against the completed walk before anybody sees that walk.
                            let pending = Array(listing.pending)
                            listing.pending.removeAll()
                            Self.patchListing(listing, refs: pending, vault: v, cancelled: cancelled)
                            listing.scanning = false
                            cont.resume(returning: (listing.files, listing.set))
                        }
                    }
                }
            }
        }
        fileListTask = task
        let result = await task.value
        if listingGeneration == generation { fileListTask = nil }
        return result
    }

    /// `fileScanner`'s shape, from the index's own reader: graph builds can hold the shared
    /// one for minutes. Walks the disk if the index can't be read.
    nonisolated private static func indexedFiles(_ vault: Vault, _ rules: IgnoreRules, _ visit: (FileRef) -> Bool) {
        guard let files = try? IndexStore(vault: vault, readOnly: true).indexedFiles() else {
            return VaultScanner.scan(in: vault, ignore: rules, visit)
        }
        for file in files where !visit(file) { return }
    }

    /// Applies a watcher batch to the canonical listing. Events arriving during a walk
    /// are also replayed before its final snapshot, including events before first listing.
    func applyDiskChanges(_ refs: [FileRef]) async -> ([FileRef], Set<FileRef>)? {
        let v = vault, listing = listing, cancelled = cancelled
        return await withCheckedContinuation { cont in
            filesQueue.async {
                if listing.scanning || !listing.complete { listing.pending.formUnion(refs) }
                guard listing.complete else { cont.resume(returning: nil); return }
                let before = listing.set
                Self.patchListing(listing, refs: refs, vault: v, cancelled: cancelled)
                cont.resume(returning: before == listing.set ? nil : (listing.files, listing.set))
            }
        }
    }

    nonisolated private static func patchListing(_ listing: Listing, refs: [FileRef], vault: Vault, cancelled: Flag) {
        guard !refs.isEmpty, !cancelled.isSet else { return }
        let rules = VaultScanner.ignoreRules(in: vault)
        var members = listing.set
        func confirmedAbsent(_ ref: FileRef) -> Bool {
            var st = stat()
            if lstat(vault.url(for: ref).path, &st) == 0 { return false }
            return errno == ENOENT || errno == ENOTDIR
        }
        for ref in Set(refs) {
            let url = vault.url(for: ref)
            var st = stat()
            let exists = lstat(url.path, &st) == 0
            let type = st.st_mode & S_IFMT
            let folder = exists && type == S_IFDIR && !VaultScanner.isPackage(url)
            let admitted = VaultScanner.admits(ref.relativePath, isDirectory: folder, ignore: rules)
            let prefix = ref.relativePath.isEmpty ? "" : ref.relativePath + "/"
            if ref.relativePath.isEmpty || (folder && admitted) {
                var found = Set<FileRef>()
                VaultScanner.scan(in: vault, ignore: rules, under: ref.relativePath) { item in
                    found.insert(item); return !cancelled.isSet
                }
                guard !cancelled.isSet else { return }
                for item in members where item.relativePath.hasPrefix(prefix) && !found.contains(item) {
                    if !VaultScanner.admits(item.relativePath, isDirectory: false, ignore: rules) || confirmedAbsent(item) {
                        members.remove(item)
                    }
                }
                members.formUnion(found)
                if !ref.relativePath.isEmpty { members.remove(ref) }
            } else if !admitted || (exists && type != S_IFREG && type != S_IFDIR) || confirmedAbsent(ref) {
                members.remove(ref)
                members = members.filter { !$0.relativePath.hasPrefix(prefix) }
            } else if exists {
                members.insert(ref)
                members = members.filter { !$0.relativePath.hasPrefix(prefix) }
            }
        }
        let added = members.subtracting(listing.set)
        listing.files.removeAll { !members.contains($0) }
        listing.files.append(contentsOf: added)
        listing.set = members
    }

    // MARK: Index

    /// What indexing is doing. The hairline's length and tooltip, the palette's status line
    /// and Workspace Health all read it.
    struct IndexStatus: Equatable {
        enum Phase: Equatable {
            /// Applying what changed on disk while Flamingo was closed (an FSEvents replay).
            case catchingUp
            /// Comparing every file on disk with the index.
            case walking
            /// Re-reading files an extractor update left stale, and failed reads now due.
            case refreshing
        }
        var phase = Phase.walking
        /// Files looked at: compared with the index on a walk, handled otherwise.
        var files = 0
        /// Of those, files whose contents were read again.
        var read = 0
        /// How many files the pass expects to look at, when it can tell.
        var expected: Int?
        /// Files looked at per second.
        var perSecond = 0.0
        /// The file read most recently.
        var current: FileRef?
        /// Re-reads every file, changed or not.
        var force = false

        var fraction: Double? {
            guard let expected else { return nil }
            return expected > 0 ? min(1, Double(files) / Double(expected)) : 0
        }

        /// Seconds left at the current rate.
        var remaining: TimeInterval? {
            guard let expected, perSecond > 0, files > 0 else { return nil }
            return Double(max(0, expected - files)) / perSecond
        }

        /// What the pass is doing and how far it got: `Checking for changes  412,000 of 876,700`.
        var headline: String {
            let what = switch phase {
            case .catchingUp: "Catching up on changes since last time"
            case .walking: force ? "Re-reading every file" : "Checking every file for changes"
            case .refreshing: "Re-reading files after an update"
            }
            guard files > 0 || expected != nil else { return what }
            let count = expected.map { "\(files.formatted()) of \($0.formatted())" } ?? "\(files.formatted()) files"
            return what + "  " + count
        }

        /// Rate, time left, and how many files had to be read again: `3,100/s  about 4 min left  38 read`.
        var detail: String? {
            var parts: [String] = []
            if perSecond >= 1 { parts.append("\(Int(perSecond.rounded()).formatted())/s") }
            if let remaining, remaining >= 1, let left = Self.duration.string(from: remaining.rounded(.up)) {
                parts.append("about \(left) left")
            }
            if phase == .walking, !force, files > 0 { parts.append("\(read.formatted()) changed") }
            return parts.isEmpty ? nil : parts.joined(separator: "  ")
        }

        /// The headline, the detail and the file read last, one per line, for a tooltip.
        var summary: String {
            [headline, detail, current.map { "Reading " + $0.relativePath }].compactMap { $0 }.joined(separator: "\n")
        }

        private static let duration: DateComponentsFormatter = {
            let f = DateComponentsFormatter()
            f.allowedUnits = [.hour, .minute, .second]
            f.unitsStyle = .abbreviated
            f.maximumUnitCount = 2
            return f
        }()
    }

    nonisolated static let reindexBatch = 200

    enum ReindexOutcome: Equatable {
        case completed, cancelled, failed(String)
    }

    /// Counts on the indexing thread and hands the main thread a status at most four times
    /// a second. Touched only by the thread running the pass.
    private final class ProgressMeter: @unchecked Sendable {
        private(set) var status: IndexStatus
        private let started = Date()
        private var lastReport = Date.distantPast
        private let report: (IndexStatus) -> Void

        init(_ status: IndexStatus, report: @escaping (IndexStatus) -> Void) {
            self.status = status; self.report = report
        }

        func looked(_ n: Int) { status.files += n; tick() }
        /// Reported with the batch's `looked`, which follows its reads.
        func read(_ n: Int, last: FileRef) { status.read += n; status.current = last }
        func expect(_ n: Int?) { status.expected = n }

        func tick(now: Bool = false) {
            let t = Date()
            guard now || t.timeIntervalSince(lastReport) >= 0.25 else { return }
            lastReport = t
            status.perSecond = Double(status.files) / max(t.timeIntervalSince(started), 0.001)
            report(status)
        }
    }

    // MARK: Checkpoint

    /// Every disk change before this is in the index; nil when the index can't vouch for
    /// that (no complete walk yet, a failed write, events FSEvents lost).
    private(set) var checkpoint: ScanCheckpoint?
    /// The newest FSEvents id whose batch is in the index.
    private var appliedThrough: UInt64 = 0
    private var walking = false
    /// Something went unindexed during the running walk, so it can't set a checkpoint.
    private var walkTainted = false

    /// Opening a vault: watch from where the index left off when it can say so, replaying
    /// what changed while Flamingo was closed, else from now. True when replaying: wait for
    /// `watcher.onHistoryDone`, then `refreshStale`, instead of walking every file.
    func startWatching() -> Bool {
        if let index, let point = index.scanCheckpoint(history: VaultWatcher.historyID(for: vault.root)) {
            watcher.start(since: point.eventID)
            if watcher.isRunning {
                checkpoint = point
                appliedThrough = point.eventID
                Log.debug("index: resuming from event \(point.eventID), walked \(point.walkedAt)")
                return true
            }
        }
        watcher.start()
        return false
    }

    /// A watcher batch reaching `through` is in the index: so is everything before it.
    private func noteApplied(through: UInt64?) {
        guard let through, through > appliedThrough else { return }
        appliedThrough = through
        guard var point = checkpoint, let index else { return }
        point.eventID = through
        checkpoint = point
        indexQueue.async { try? index.saveScanCheckpoint(point) }
    }

    /// The index missed something (lost events, a failed write): the next open walks,
    /// unless a walk that starts after this one completes first.
    func distrustCheckpoint() {
        checkpoint = nil
        if walking { walkTainted = true }
        guard let index else { return }
        indexQueue.async { try? index.clearScanCheckpoint() }
    }

    /// Walks every file, re-reading those whose stamp changed, commits bounded batches, and
    /// prunes only after an uncancelled, successful walk. Failures remain visible until the
    /// next successful full pass or explicit retry. A completed walk sets the checkpoint the
    /// next open resumes from.
    @discardableResult
    func reindex(force: Bool = false, progress: @escaping @MainActor (IndexStatus) -> Void) async -> ReindexOutcome {
        guard let index else {
            let message = startupError ?? "The index is unavailable. Reopen this folder to retry."
            indexingError = message
            return .failed(message)
        }
        guard !isStopped else { return .cancelled }
        let v = vault, sidecar = sidecar
        let failureGeneration = indexFailureGeneration
        // Changes from here on reach the index through the watcher, which is already running.
        let walkStart = VaultWatcher.currentEventID, history = VaultWatcher.historyID(for: v.root)
        walking = true; walkTainted = false
        defer { walking = false }
        indexCancelled = Flag()
        let cancelled = cancelled, indexCancelled = indexCancelled
        let meter = ProgressMeter(IndexStatus(phase: .walking, force: force)) { status in
            Task { @MainActor in
                guard !cancelled.isSet, !indexCancelled.isSet else { return }
                progress(status)
            }
        }
        let result: Result<IndexStatus, Error> = await withCheckedContinuation { cont in
            reindexQueue.async {
                cont.resume(returning: Result {
                    func checkCancellation() throws {
                        if cancelled.isSet || indexCancelled.isSet { throw CancellationError() }
                    }
                    let shouldCancel = { cancelled.isSet || indexCancelled.isSet }
                    try checkCancellation()
                    let known = Set(try index.indexedFiles().map(\.relativePath))
                    meter.expect(known.isEmpty ? nil : known.count)
                    let rules = VaultScanner.ignoreRules(in: v)
                    var seen = Set<String>(), batch: [FileRef] = []
                    var failure: Error?
                    func flush() throws {
                        guard !batch.isEmpty else { return }
                        try checkCancellation()
                        // Stale rows wait for `refreshStale`, so the walk finishes and sets a
                        // checkpoint even when an extractor update left most rows stale.
                        try index.update(batch, force: force, shouldCancel: shouldCancel, deferStale: true, onRead: meter.read)
                        try checkCancellation()
                        meter.looked(batch.count)
                        batch.removeAll(keepingCapacity: true)
                    }
                    VaultScanner.scan(in: v, ignore: rules) { ref in
                        guard !shouldCancel() else { return false }
                        seen.insert(ref.relativePath); batch.append(ref)
                        if batch.count >= Self.reindexBatch {
                            do { try flush() } catch { failure = error; return false }
                        }
                        return true
                    }
                    if let failure { throw failure }
                    try checkCancellation()
                    try flush()
                    try checkCancellation()
                    try index.pruneUnseen(known.subtracting(seen).map(FileRef.init(relativePath:)))
                    _ = try sidecar.reconcile()
                    let notes = try sidecar.sidecarRefs().filter { !seen.contains($0.relativePath) }
                    try checkCancellation()
                    try index.update(notes, force: false, shouldCancel: shouldCancel)
                    _ = try index.resumePendingExtractions(maxPasses: 8, shouldCancel: shouldCancel)
                    try checkCancellation()
                    return meter.status
                })
            }
        }
        switch result {
        case .success(var status):
            if indexFailureGeneration == failureGeneration { indexingError = nil }
            if !walkTainted, let history {
                let point = ScanCheckpoint(eventID: max(walkStart, appliedThrough), history: history, walkedAt: Date())
                checkpoint = point
                try? await onIndex { try index.saveScanCheckpoint(point) }
            }
            status.expected = status.files
            progress(status)
            Log.debug("index: walked \(status.files) files, read \(status.read)")
            return .completed
        case .failure(is CancellationError): return .cancelled
        case .failure(let error):
            indexingError = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    /// After a replay reaching `through`: records the checkpoint, then re-reads the rows an
    /// extractor update left stale and the failed reads now due. No walk.
    @discardableResult
    func refreshStale(through: UInt64?, progress: @escaping @MainActor (IndexStatus) -> Void) async -> ReindexOutcome {
        guard let index else {
            let message = startupError ?? "The index is unavailable. Reopen this folder to retry."
            indexingError = message
            return .failed(message)
        }
        guard !isStopped else { return .cancelled }
        // Replayed batches were queued on `indexQueue` before this; let them land first.
        await withCheckedContinuation { cont in indexQueue.async { cont.resume() } }
        noteApplied(through: through)
        let failureGeneration = indexFailureGeneration
        indexCancelled = Flag()
        let cancelled = cancelled, indexCancelled = indexCancelled
        let meter = ProgressMeter(IndexStatus(phase: .refreshing)) { status in
            Task { @MainActor in
                guard !cancelled.isSet, !indexCancelled.isSet else { return }
                progress(status)
            }
        }
        let result: Result<IndexStatus, Error> = await withCheckedContinuation { cont in
            reindexQueue.async {
                cont.resume(returning: Result {
                    let shouldCancel = { cancelled.isSet || indexCancelled.isSet }
                    let stale = try index.staleFiles()
                    meter.expect(stale.count)
                    meter.tick(now: true)
                    var start = 0
                    while start < stale.count {
                        if shouldCancel() { throw CancellationError() }
                        let chunk = Array(stale[start..<min(start + Self.reindexBatch, stale.count)])
                        try index.update(chunk, force: false, shouldCancel: shouldCancel, onRead: meter.read)
                        meter.looked(chunk.count)
                        start += chunk.count
                    }
                    _ = try index.resumePendingExtractions(maxPasses: 8, shouldCancel: shouldCancel)
                    if shouldCancel() { throw CancellationError() }
                    return meter.status
                })
            }
        }
        switch result {
        case .success(let status):
            if indexFailureGeneration == failureGeneration { indexingError = nil }
            progress(status)
            Log.debug("index: caught up; re-read \(status.read) of \(status.files) stale files")
            return .completed
        case .failure(is CancellationError): return .cancelled
        case .failure(let error):
            indexingError = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    /// Incremental errors are retained for health/status UI and returned to the caller.
    /// `through` is the watcher batch's `deliveredThrough`, which the checkpoint advances to.
    @discardableResult
    func update(_ refs: [FileRef], through: UInt64? = nil) async -> Bool {
        guard !refs.isEmpty, !isStopped else { return true }
        guard let index else { indexingError = startupError ?? "The index is unavailable."; return false }
        let cancelled = cancelled
        do {
            try await onIndex { try index.update(refs, force: false, shouldCancel: { cancelled.isSet }) }
            noteApplied(through: through)
            return true
        } catch {
            indexingError = error.localizedDescription
            distrustCheckpoint()
            return false
        }
    }

    /// Re-reads every note into the index, after FSEvents lost events under `.flamingo/notes`.
    func reloadNotes() async {
        guard let index, !isStopped else { return }
        do { try await onIndex { try index.reloadComments() } }
        catch { indexingError = error.localizedDescription; distrustCheckpoint() }
    }

    @discardableResult
    func remove(_ refs: [FileRef]) async -> Bool {
        guard !refs.isEmpty, !isStopped else { return true }
        guard let index else { indexingError = startupError ?? "The index is unavailable."; return false }
        do { try await onIndex { try index.remove(refs) }; return true }
        catch { indexingError = error.localizedDescription; return false }
    }

    func takeIndexedRenames() async -> [IndexedRename] {
        guard let index else { return [] }
        do { return try await onIndex { try index.pendingRenames() } }
        catch { indexingError = error.localizedDescription; return [] }
    }

    /// The user deliberately moved this path. Establish identity and persist the retry
    /// record before touching its dependent stores, even if indexing had not reached it.
    func recordRename(from old: FileRef, to new: FileRef) async throws {
        guard let index else { throw CocoaError(.fileReadUnknown) }
        let vault = vault
        try await onIndex {
            let identity = try FileIdentity.id(for: vault.url(for: new))
            try index.recordRename(from: old, to: new, identity: identity)
        }
    }

    func pruneMovedSources(_ refs: [FileRef]) async throws {
        guard let index else { throw CocoaError(.fileReadUnknown) }
        _ = try await onIndex { try index.pruneUnseen(refs) }
    }

    func acknowledgeIndexedRename(_ move: IndexedRename) async throws {
        guard let index else { throw CocoaError(.fileReadUnknown) }
        try await onIndex { try index.acknowledgeRename(move) }
    }

    func search(_ query: String, limit: Int = 50) async -> [SearchHit] {
        guard let index else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return (try? await onStore { try index.search(q, inFolder: nil, limit: limit, includeSemantic: false) }) ?? []
    }

    /// Every matching section and thought, best first, for the search tab: a file can
    /// appear many times. Thoughts carry their comment id.
    func searchAll(_ query: String, inFolder folder: String? = nil, limit: Int = 300) async throws -> [SearchHit] {
        guard let index else { throw CocoaError(.fileReadUnknown) }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return try await onStore {
            let sections = try index.searchSections(q, inFolder: folder, limit: limit, includeSemantic: false)
            let files = try index.search(q, inFolder: folder, limit: limit, includeSemantic: false)
            let comments = try index.searchComments(q, inFolder: folder, limit: limit).map {
                SearchHit(file: $0.file, anchor: $0.comment.anchor, snippet: $0.snippet, score: $0.score * 1.5, commentID: $0.comment.id)
            }
            var seen = Set<String>()
            return Array((sections + comments + files).sorted { $0.score > $1.score }.filter { seen.insert($0.id).inserted }.prefix(max(0, limit)))
        }
    }

    func sections(of ref: FileRef) async -> [FlamingoExtract.Section] {
        guard let index else { return [] }
        return (try? await onStore { try index.sections(of: ref) }) ?? []
    }

    /// Resolve document context off the main thread without waiting for a graph build.
    func relatedFiles(of ref: FileRef, limit: Int = 100) async throws -> RelatedFilesSnapshot {
        guard let index, !isStopped else { throw CocoaError(.fileReadUnknown) }
        let connections = connections
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try index.relatedFiles(to: ref, connections: connections.all(), limit: limit,
                                          checkCancellation: { try Task.checkCancellation() })
        }
        let result = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        guard !isStopped else { throw CancellationError() }
        return result
    }

    /// The selected file's connections, one per other file, explicit and suggested.
    /// `edges` are the built graph's, so discovered mentions and sessions need no rebuild.
    func fileConnections(of ref: FileRef, edges: [Graph.Edge]) async throws -> FileConnectionsSnapshot {
        guard let index, !isStopped else { throw CocoaError(.fileReadUnknown) }
        let connections = connections, dismissed = dismissed
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let similar = ((try? index.similarFiles(to: ref, limit: 8)) ?? []).map {
                (file: $0.file, score: index.relatedness($0.score), passage: $0.passage)
            }
            return try index.fileConnections(of: ref, connections: connections.all(), edges: edges, similar: similar,
                                             dismissed: dismissed.keys(), checkCancellation: { try Task.checkCancellation() })
        }
        let result = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        guard !isStopped else { throw CancellationError() }
        return result
    }

    /// What ties each seed file to everything else: links, similar content, opened together,
    /// mentions. One detached pass, no excerpt reads. `edges` are the built graph's, if any.
    func paneEvidence(for seeds: [FileRef], edges: [Graph.Edge]) async throws -> [FileRef: FileConnectionsSnapshot] {
        guard let index, !isStopped else { throw CocoaError(.fileReadUnknown) }
        let connections = connections, dismissed = dismissed, trail = trail
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let all = ((try? trail.edges()) ?? []) + edges
            let manual = try connections.all(), hidden = dismissed.keys()
            var out: [FileRef: FileConnectionsSnapshot] = [:]
            for seed in seeds {
                try Task.checkCancellation()
                let related = try index.relatedFiles(to: seed, connections: manual, limit: 40,
                                                     checkCancellation: { try Task.checkCancellation() })
                let similar = ((try? index.similarFiles(to: seed, limit: 12)) ?? []).map {
                    (file: $0.file, score: index.relatedness($0.score), passage: nil as String?)
                }
                out[seed] = FileConnections.merge(for: seed, related: related, edges: all, similar: similar, dismissed: hidden)
            }
            return out
        }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard !isStopped else { throw CancellationError() }
        return result
    }

    /// When each file was first touched: its first open in Trail, its oldest thought, else
    /// its modification date. Feeds the graph's Replay History.
    func firstSeen() async -> [String: Date] {
        let trail = trail
        guard let index else { return [:] }
        return await Task.detached(priority: .userInitiated) {
            var dates = (try? index.firstSeenDates()) ?? [:]
            for event in (try? trail.events()) ?? [] {
                guard let path = event.file?.relativePath else { continue }
                if dates[path].map({ event.at < $0 }) ?? true { dates[path] = event.at }
            }
            return dates
        }.value
    }

    /// A thought from a while ago, at random.
    func resurfaceableThought() async -> (FileRef, Comment)? {
        guard let index else { return nil }
        return await Task.detached(priority: .userInitiated) { try? index.resurfaceableThought() }.value
    }

    func buildGraph() async -> Graph {
        let trail = trail
        let connections = connections
        let dismissed = dismissed
        guard let index else {
            return Graph(nodes: [], edges: (try? trail.edges()) ?? [])
        }
        let started = Date()
        let g = (try? await onGraph {
            let extra = ((try? trail.edges()) ?? []) + ((try? connections.edges()) ?? [])
                + ((try? index.similarEdges()) ?? [])
            let built = try index.buildGraph(extraEdges: extra)
            // A dismissed suggestion is gone from the graph too; explicit edges always stay.
            let hidden = dismissed.keys()
            let kept = hidden.isEmpty ? built : Graph(nodes: built.nodes, edges: built.edges.filter {
                !$0.kind.isInferred || !hidden.contains(DismissedConnection.key($0.source, $0.target))
            })
            return Self.drawable(kept)
        }) ?? Graph()
        Log.debug("graph: \(g.nodes.count) nodes, \(g.edges.count) edges in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        return g
    }

    /// Past `orphanLimit` files, files with no relationship and no thought are dropped.
    /// Keep their folder ancestry so zooming can still reveal every indexed folder.
    nonisolated static func drawable(_ g: Graph) -> Graph {
        let fileCount = g.nodes.lazy.filter { !$0.id.hasSuffix("/") }.count
        guard fileCount > orphanLimit else { return GraphFolders.addingAncestors(to: g) }
        var linked = Set<String>()
        for e in g.edges where e.kind != .folder { linked.insert(e.source); linked.insert(e.target) }
        let retained = Graph(nodes: g.nodes.filter { $0.id.hasSuffix("/") || $0.commentCount > 0 || linked.contains($0.id) }, edges: g.edges)
        return GraphFolders.addingAncestors(to: retained, from: g.nodes)
    }

    nonisolated static let orphanLimit = 5_000

    func health() async throws -> (IndexHealth, [IndexedFileCoverage], Int64) {
        guard let index else { throw CocoaError(.fileReadUnknown) }
        let path = vault.stateDir.appendingPathComponent("index.sqlite").path
        return try await onStore {
            let size = [path, path + "-wal", path + "-shm"].reduce(Int64(0)) { total, file in
                total + ((try? FileManager.default.attributesOfItem(atPath: file)[.size] as? NSNumber)?.int64Value ?? 0)
            }
            return (try index.health(), try index.incompleteFiles(limit: 100), size)
        }
    }

    func retryIncomplete() async throws {
        guard let index else { throw CocoaError(.fileReadUnknown) }
        let cancelled = cancelled
        do {
            try await onIndex {
                try index.retryFailed(shouldCancel: { cancelled.isSet })
                _ = try index.resumePendingExtractions(maxPasses: 8, shouldCancel: { cancelled.isSet })
            }
        } catch { indexingError = error.localizedDescription; throw error }
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

    func attachInboxThought(_ comment: Comment, original: UUID, from source: FileRef, to target: FileRef) async throws {
        let s = sidecar
        try await onStore {
            // A failed inbox removal can be retried without duplicating the acknowledged target write.
            let existing = try s.comments(for: target)
            if !existing.contains(where: { $0.text == comment.text && abs($0.timestamp.timeIntervalSince(comment.timestamp)) < 1 && $0.provenance == comment.provenance }) {
                try s.append(comment, to: target)
            }
            if try s.comments(for: source).contains(where: { $0.id == original }) { try s.delete(original, from: source) }
        }
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
