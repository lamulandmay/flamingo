import AppKit
import SwiftUI
import FlamingoCore
import FlamingoCapture
import FlamingoIndex
import FlamingoAsk
import FlamingoThoughts

// Thoughts v2 in the shell: saving with uids, state/kind/reply, understanding, `@ai`, the
// night shift, recall and thought links. The engine pieces are in FlamingoCore, FlamingoIndex,
// FlamingoAsk and FlamingoThoughts; this file only connects them to the open vault.
//
// Privacy: a thought never reaches a model that is not on this Mac. Every model call here goes
// through `ThoughtReader`, `askStreamingLocally`, `engine.work` (via `NightShiftService`) or
// the local-only completions. Nothing here touches `LlamaServer.endpoint`, `MessagesClient`,
// `ClaudeCodeClient` or Ask's provider.

extension Defaults {
    /// "Pause Night Shift" / "Resume Night Shift". On by default.
    static var nightShiftEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "nightShiftEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "nightShiftEnabled") }
    }

    /// The idle backfill's count for the day it last ran.
    static var thoughtBackfill: DailyBudget {
        get {
            DailyBudget(day: UserDefaults.standard.string(forKey: "thoughtBackfillDay") ?? "",
                        used: UserDefaults.standard.integer(forKey: "thoughtBackfillUsed"))
        }
        set {
            UserDefaults.standard.set(newValue.day, forKey: "thoughtBackfillDay")
            UserDefaults.standard.set(newValue.used, forKey: "thoughtBackfillUsed")
        }
    }
}

extension AppState {
    /// QA's clock (`clock <ISO>`), nil for the real time. The night shift reads it; the daily
    /// briefing reads it too, so QA can put both at 02:00 or 08:30.
    nonisolated static var qaNow: Date? {
        get { QAClock.override }
        set { QAClock.override = newValue }
    }

    /// Now, or QA's time.
    nonisolated static var now: Date { QAClock.override ?? Date() }

    // MARK: Saving

    /// Called after a thought has been written and indexed: logs it and sets in motion what its
    /// words call for. Never blocks the save.
    func thoughtDidSave(_ comment: Comment, in file: FileRef, session s: VaultSession) {
        ThoughtLog.saved(comment.uid, file: file)
        guard let uid = comment.uid, session === s else { return }
        if ThoughtTriggers.asksAssistant(comment) {
            // A thought brought back by undo is not a new question.
            guard abs(comment.timestamp.timeIntervalSinceNow) < 90 else { return }
            askAssistant(uid: uid, in: file)
        } else if ThoughtTriggers.shouldUnderstand(comment) {
            scheduleUnderstanding(uid: uid, in: file)
        }
    }

    /// Save for a thought on a note that may not exist yet (a folder, a web page).
    func saveNoteComment(_ comment: Comment, to file: FileRef, frontmatter: [String: String]) async throws {
        guard let s = session else { throw CocoaError(.fileWriteUnknown) }
        let comment = comment.stamped()
        try changeComments(in: s, files: [file], name: "Add Thought") {
            if frontmatter.isEmpty { try s.sidecar.append(comment, to: file) }
            else { try s.sidecar.append(comment, to: file, frontmatter: frontmatter) }
        }
        thoughtDidSave(comment, in: file, session: s)
        await thoughtsDidChange(in: file, session: s)
    }

    /// An edit: the same thought, by uid, so what a model or the person decided meanwhile
    /// survives. The words changing clears a model's reading of them (the person's choices stay).
    func saveEditedThought(_ comment: Comment, in file: FileRef) async throws {
        guard let s = session else { throw CocoaError(.fileWriteUnknown) }
        let edited = comment.modified()
        let store = s.sidecar
        try changeComments(in: s, files: [file], name: "Edit Thought") {
            if let uid = comment.uid, (try? store.comment(uid: uid, in: file)) != nil {
                try store.update(uid: uid, in: file) { stored in
                    let changed = stored.text != edited.text
                    stored.text = edited.text
                    stored.meta?.modified = edited.meta?.modified
                    if changed, stored.meta?.kindBy == .model {
                        stored.meta?.kind = nil; stored.meta?.kindBy = nil; stored.meta?.intent = nil
                    }
                }
            } else {
                try store.update(edited, in: file)
            }
        }
        await thoughtsDidChange(in: file, session: s)
        if ThoughtTriggers.shouldUnderstand(edited), let uid = edited.uid { scheduleUnderstanding(uid: uid, in: file) }
    }

    /// Re-index and refresh after a change to `file`'s note (a folder's included).
    func thoughtsDidChange(in file: FileRef, session s: VaultSession) async {
        await commentsDidChange(for: file, in: s)
        thoughts.jobs.bumpNote()
    }

    /// A folder, whose note is not about any file: re-reading it as a file would walk the folder.
    func isFolderNote(_ file: FileRef) -> Bool {
        guard let url = url(for: file) else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// The thoughts on a note that is not the open file (a folder's).
    func noteComments(_ file: FileRef) async -> [Comment] {
        guard let s = session else { return [] }
        return await s.comments(for: file)
    }

    // MARK: State, kind, replies

    /// The uid of `comment`, giving a legacy thought one the first time something refers to it.
    func thoughtUID(for comment: Comment, in file: FileRef) async throws -> String {
        if let uid = comment.uid { return uid }
        guard let s = session else { throw CocoaError(.fileNoSuchFile) }
        let store = s.sidecar, id = comment.id
        return try await Task.detached { try store.ensureUID(forCommentID: id, in: file) }.value
    }

    /// Done, open again, snoozed or dismissed. One undo step.
    func setThoughtState(_ comment: Comment, to state: ThoughtState, until: Date? = nil, in file: FileRef) {
        Task {
            do {
                let uid = try await thoughtUID(for: comment, in: file)
                let decided = comment.settingState(state, snoozeUntil: until)
                try await changeThought(uid: uid, in: file, name: state == .done ? "Mark Done" : state == .open ? "Reopen Thought" : "Snooze Thought") { stored in
                    stored.meta?.state = decided.meta?.state
                    stored.meta?.stateAt = decided.meta?.stateAt
                    stored.meta?.snoozeUntil = decided.meta?.snoozeUntil
                }
            } catch { Log.debug("thoughts: state not saved: \(error)") }
        }
    }

    /// The kind the person chose (`kindBy: user`).
    func setThoughtKind(_ comment: Comment, to kind: ThoughtKind, in file: FileRef) {
        Task {
            do {
                let uid = try await thoughtUID(for: comment, in: file)
                try await changeThought(uid: uid, in: file, name: "Change Kind") { stored in
                    stored.meta?.kind = kind
                    stored.meta?.kindBy = .user
                }
            } catch { Log.debug("thoughts: kind not saved: \(error)") }
        }
    }

    private func changeThought(uid: String, in file: FileRef, name: String, _ change: @escaping (inout Comment) -> Void) async throws {
        guard let s = session else { throw CocoaError(.fileWriteUnknown) }
        let store = s.sidecar
        try changeComments(in: s, files: [file], name: name) {
            try store.update(uid: uid, in: file) { change(&$0) }
        }
        await thoughtsDidChange(in: file, session: s)
    }

    /// A reply from the person: below the thought with `parentUID` in `file`'s note.
    func saveThoughtReply(text: String, anchor: FileAnchor? = nil, toUID parentUID: String, in file: FileRef) async throws {
        guard let s = session else { throw CocoaError(.fileWriteUnknown) }
        let reply = Comment(timestamp: Self.now, anchor: anchor, text: text).replying(toUID: parentUID)
        let store = s.sidecar
        var stored = reply
        try changeComments(in: s, files: [file], name: "Reply") {
            stored = try store.appendReply(reply, toUID: parentUID, in: file)
        }
        if !isFolderNote(file) { s.trail.recordComment(stored, on: file) }
        thoughtDidSave(stored, in: file, session: s)
        celebrate(stored, on: file)
        await thoughtsDidChange(in: file, session: s)
    }

    /// Copy Link to Thought: `[[<file>#^<uid>]]`.
    func copyThoughtLink(_ comment: Comment, in file: FileRef) {
        Task {
            guard let uid = try? await thoughtUID(for: comment, in: file) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ThoughtLink.make(file: file, uid: uid), forType: .string)
        }
    }

    // MARK: Understanding

    /// About two seconds after a thought is saved, a local model reads it. Silent when none is
    /// running; the save has long since finished.
    func scheduleUnderstanding(uid: String, in file: FileRef, after delay: TimeInterval = 2) {
        guard let s = session, let engine = s.ask else { return }
        thoughts.understanding[uid]?.cancel()
        thoughts.understanding[uid] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.session === s else { return }
            let store = s.sidecar
            let open = Array(self.openFiles.prefix(8))
            let reader = ThoughtReader(engine: engine, store: store)
            let outcome = await Task.detached(priority: .utility) { () -> ThoughtReadOutcome in
                var candidates = open
                if let c = try? store.comment(uid: uid, in: file) {
                    candidates = engine.thoughtScope(for: c, on: file, limit: 8) + open
                }
                return await reader.read(uid: uid, on: file, candidates: candidates)
            }.value
            guard self.session === s else { return }
            self.thoughts.understanding[uid] = nil
            await self.thoughtWasRead(outcome, uid: uid, in: file, session: s)
        }
    }

    private func thoughtWasRead(_ outcome: ThoughtReadOutcome, uid: String, in file: FileRef, session s: VaultSession) async {
        switch outcome {
        case .saved(let u):
            Log.debug("thoughts: understood uid=\(uid) kind=\(u.kind.rawValue) action=\(u.intent?.action ?? "none") confidence=\(u.confidence)")
            await thoughtsDidChange(in: file, session: s)
        case .unsure(let u): Log.debug("thoughts: unsure uid=\(uid) kind=\(u.kind.rawValue) confidence=\(u.confidence)")
        case .skipped(let why): Log.debug("thoughts: skipped uid=\(uid) \(why)")
        case .unavailable(let why): Log.debug("thoughts: no model uid=\(uid) \(why)")
        }
    }

    /// While the Mac is idle: open thoughts of the last 30 days nobody has read, at most 50 a day.
    func startThoughtBackfill(for s: VaultSession) {
        thoughts.backfill?.cancel()
        thoughts.backfill = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)
            while !Task.isCancelled {
                guard let self, self.session === s else { return }
                await self.backfillPass(s)
                try? await Task.sleep(nanoseconds: 10 * 60 * 1_000_000_000)
            }
        }
    }

    func backfillPass(_ s: VaultSession, idleNeeded: TimeInterval = 120) async {
        guard let index = s.index, let engine = s.ask, UserIdle.seconds() >= idleNeeded else { return }
        var budget = Defaults.thoughtBackfill
        let left = budget.remaining(on: Date())
        guard left > 0 else { return }
        let found = await Task.detached(priority: .utility) { ThoughtReader.backfillCandidates(in: index, limit: left) }.value
        let reader = ThoughtReader(engine: engine, store: s.sidecar)
        for record in found {
            guard !Task.isCancelled, session === s, UserIdle.seconds() >= 60, let uid = record.uid,
                  !thoughts.backfillTried.contains(uid), budget.take(on: Date()) else { continue }
            thoughts.backfillTried.insert(uid)
            Defaults.thoughtBackfill = budget
            let file = record.file
            let outcome = await Task.detached(priority: .utility) { await reader.read(uid: uid, on: file) }.value
            if case .unavailable = outcome { return }
            await thoughtWasRead(outcome, uid: uid, in: file, session: s)
        }
    }

    // MARK: Ask AI (@ai, @flamingo)

    /// Answers a thought with a model on this Mac, scoped to its file, the files it links to
    /// and its thread. The answer streams into the rail as a pending row, then is saved as a reply.
    func askAssistant(uid: String, in file: FileRef) {
        guard let s = session, let engine = s.ask else { return }
        thoughts.jobs.begin(uid) { [weak self] in
            await self?.runAsk(uid: uid, in: file, session: s, engine: engine)
        }
    }

    /// Ask AI from the rail, for a thought that has no `@ai` in it.
    func askAssistant(about comment: Comment, in file: FileRef) {
        Task {
            guard let uid = try? await thoughtUID(for: comment, in: file) else { return }
            askAssistant(uid: uid, in: file)
        }
    }

    private func runAsk(uid: String, in file: FileRef, session s: VaultSession, engine: AskEngine) async {
        let store = s.sidecar
        guard let doc = try? store.document(for: file), let comment = doc.comment(uid: uid) else { return }
        let thread = ThoughtThread.members(of: comment, in: doc.comments)
        var question = ThoughtTriggers.question(of: comment)
        if question.isEmpty { question = comment.text }
        let history = ThoughtThread.history(of: thread, before: comment)
        let scope = engine.thoughtScope(for: comment, on: file, thread: thread)
        let context = AskContext(openFile: file.isVirtual || isFolderNote(file) ? nil : file, anchor: comment.anchor)
        Log.debug("ai: ask uid=\(uid) scope=\(scope.map(\.relativePath))")

        var text = ""
        var final: Answer?
        do {
            for try await delta in engine.askStreamingLocally(question, history: history, files: scope, context: context) {
                if Task.isCancelled { break }
                switch delta {
                case .text(let piece):
                    if let pace = QAPace.wordDelay {
                        // QA only: a canned reply arrives at once; let it stream so a screenshot can catch the pending row.
                        for word in piece.split(separator: " ", omittingEmptySubsequences: false) {
                            if Task.isCancelled { break }
                            text += (text.isEmpty || text.hasSuffix(" ") ? "" : " ") + word
                            thoughts.jobs.set(uid, text: text)
                            try? await Task.sleep(nanoseconds: UInt64(pace * 1_000_000_000))
                        }
                    } else {
                        text += piece; thoughts.jobs.set(uid, text: text)
                    }
                case .discard: text = ""; thoughts.jobs.set(uid, text: "")
                case .answer(let answer): final = answer
                default: break
                }
            }
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { Log.debug("ai: cancelled uid=\(uid)"); return }
            Log.debug("ai: failed uid=\(uid) \(error)")
            showToast(ToastMessage(text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            return
        }
        guard !Task.isCancelled else { Log.debug("ai: cancelled uid=\(uid)"); return }
        guard let answer = final, self.session === s else { return }
        let reply = Comment(text: answer.wikified(), provenance: CommentProvenance(origin: .ai, model: answer.model)).stamped()
        do {
            let stored = try await Task.detached { try store.appendReply(reply, toUID: uid, in: file) }.value
            Log.debug("ai: answer uid=\(uid) reply=\(stored.uid ?? "-") thoughts=\(answer.drewOnThoughts)")
            await thoughtsDidChange(in: file, session: s)
        } catch {
            Log.debug("ai: not saved uid=\(uid) \(error)")
            showToast(ToastMessage(text: error.localizedDescription))
        }
    }

    // MARK: Night shift

    /// A night shift and its scheduler for the vault just opened. Local models only.
    func startThoughts(for s: VaultSession) {
        thoughts.stop()
        guard let index = s.index, let engine = s.ask else { return }
        let service = NightShiftService(vault: s.vault, index: index, store: s.sidecar, trail: s.trail, worker: engine,
                                        clock: { QAClock.override ?? Date() })
        service.settings.enabled = Defaults.nightShiftEnabled
        thoughts.service = service
        thoughts.box.set(service)
        let box = thoughts.box
        let scheduler = NightShiftScheduler(
            service: { box.get() },
            power: { QAGate.isOpen ? .pluggedIn : PowerSnapshot.current() },
            idle: { QAGate.isOpen ? 3_600 : UserIdle.seconds() },
            onEvent: { [weak self] event in
                Self.logNightShift(event)
                if case .replied = event { Task { @MainActor in await self?.refreshComments() } }
            },
            onOutcome: { Log.debug("nightshift: \(Self.describe($0))") })
        scheduler.start()
        thoughts.scheduler = scheduler
        startThoughtBackfill(for: s)
    }

    func stopThoughts() { thoughts.stop() }

    nonisolated static func logNightShift(_ event: NightShiftEvent) {
        switch event {
        case .started(let job, let recipe, let file): Log.debug("nightshift: started job=\(job) recipe=\(recipe) file=\(file)")
        case .status(let job, let text): Log.debug("nightshift: status job=\(job) \(text)")
        case .finished(let job, let memo, _): Log.debug("nightshift: finished job=\(job) memo=\(memo)")
        case .replied(let job): Log.debug("nightshift: replied job=\(job)")
        case .failed(let job, let why): Log.debug("nightshift: failed job=\(job) \(why)")
        }
    }

    nonisolated static func describe(_ outcome: NightShiftOutcome) -> String {
        switch outcome {
        case .ran(let s): return "ran attempted=\(s.attempted) finished=\(s.finished) replied=\(s.replied) failed=\(s.failed) stop=\(s.stop.rawValue)"
        case .waiting(let until): return "waiting until=\(until)"
        case .skipped(let why): return "skipped \(why)"
        }
    }

    /// The first open of the day: up to three jobs for a night that did not run. The briefing
    /// calls this once; it declines on its own when it is not needed. Events stream to `onEvent`
    /// from a background thread.
    @discardableResult
    func nightShiftCatchUp(onEvent: @escaping @Sendable (NightShiftEvent) -> Void = { _ in }) async -> NightShiftOutcome? {
        guard let service = thoughts.service, service.settings.enabled else { return nil }
        let outcome = await Task.detached(priority: .utility) {
            await service.catchUp(power: PowerSnapshot.current(), onEvent: { Self.logNightShift($0); onEvent($0) })
        }.value
        Log.debug("nightshift: catch-up \(Self.describe(outcome))")
        return outcome
    }

    var nightShiftPaused: Bool { !Defaults.nightShiftEnabled }

    func setNightShiftEnabled(_ on: Bool) {
        Defaults.nightShiftEnabled = on
        thoughts.service?.settings.enabled = on
        Log.debug("nightshift: \(on ? "resumed" : "paused")")
    }

    /// "Work on Open Thoughts Now": up to three, whatever the hour.
    func workOnOpenThoughtsNow() {
        guard let service = thoughts.service else { return }
        showToast(ToastMessage(text: "Working on open thoughts"))
        Task { [weak self] in
            let summary = await Task.detached(priority: .utility) {
                await service.workNow(limit: 3, onEvent: { Self.logNightShift($0) })
            }.value
            Log.debug("nightshift: now attempted=\(summary.attempted) finished=\(summary.finished) replied=\(summary.replied) failed=\(summary.failed)")
            self?.dismissToast()
            await self?.refreshComments()
        }
    }

    /// Rail: Work on This Now ▸ recipe. A pending row shows while it runs.
    func workOnThought(_ comment: Comment, recipe: RailRecipe, in file: FileRef) {
        guard let service = thoughts.service, let recipe = WorkRecipe(rawValue: recipe.rawValue) else { return }
        Task { [weak self] in
            guard let self, let uid = try? await self.thoughtUID(for: comment, in: file) else { return }
            self.thoughts.jobs.begin(uid) { [weak self] in
                let summary = await Task.detached(priority: .utility) {
                    await service.workNow(thoughtUID: uid, in: file, recipe: recipe, onEvent: { Self.logNightShift($0) })
                }.value
                Log.debug("nightshift: work uid=\(uid) recipe=\(recipe.rawValue) finished=\(summary?.finished ?? 0) replied=\(summary?.replied ?? 0)")
                await self?.refreshComments()
            }
        }
    }

    // MARK: Echo and recall

    /// Earlier thoughts that say something like `draft`, for the echo rows. Meaning only, off
    /// the main thread, and nothing when the index is not ready.
    func similarThoughtHits(_ draft: String, excluding uid: String? = nil) async -> [EchoHit] {
        guard let s = session, s.index != nil, let index = try? await s.searchIndex(for: .semantic) else { return [] }
        let hits = await Task.detached(priority: .userInitiated) { index.similarThoughts(to: draft, excludingUID: uid, limit: 2) }.value
        guard session === s else { return [] }
        return hits.map { hit in
            EchoHit(uid: hit.record.uid, file: hit.record.file, firstLine: ThoughtLines.first(of: hit.record.comment.text),
                    kind: hit.record.kind, state: hit.record.state, date: hit.record.comment.timestamp)
        }
    }

    /// An echo row or Capture's echo row was clicked.
    func jumpToThought(_ hit: EchoHit) {
        revealThought(in: hit.file, uid: hit.uid)
    }

    /// Shows a thought: its file open at its place, the Thoughts tab, the thought selected.
    /// A folder's thought opens the folder.
    func revealThought(in file: FileRef, uid: String?, commentID: UUID? = nil, anchor: FileAnchor? = nil) {
        guard let s = session else { return }
        NSApp.activate(ignoringOtherApps: true)
        hostWindow?.makeKeyAndOrderFront(nil)
        let folder = isFolderNote(file)
        if folder, let url = url(for: file) { showFolder(url, focus: false) }
        else if vault?.exists(file) == true { jump(to: file, anchor: anchor) }
        showInspector(.thoughts)
        Task { [weak self] in
            guard let self else { return }
            let stored = await s.comments(for: file)
            let id = commentID ?? uid.flatMap { u in stored.first { $0.uid == u }?.id }
            guard let id else { return }
            if folder { try? await Task.sleep(nanoseconds: 400_000_000) }
            else {
                for _ in 0..<40 where !self.comments.contains(where: { $0.id == id }) { try? await Task.sleep(nanoseconds: 50_000_000) }
            }
            guard self.session === s else { return }
            self.selectedCommentID = nil
            try? await Task.sleep(nanoseconds: 30_000_000)
            self.selectedCommentID = id
        }
    }

    /// `[[file#^uid]]` clicked: true when it was a link to a thought and has been handled.
    func openThoughtLink(_ raw: String, from source: FileRef?) -> Bool {
        guard let parsed = ThoughtLink.parse(raw), let v = vault else { return false }
        let base = source ?? selected
        var file: FileRef?
        if parsed.target.isEmpty { file = base }
        else {
            file = base.flatMap { Wikilink.resolve(parsed.target, from: $0, in: v, candidates: files) }
                ?? Wikilink.resolve(parsed.target, in: v, candidates: files)
            if file == nil, isFolderNote(FileRef(relativePath: parsed.target)) { file = FileRef(relativePath: parsed.target) }
        }
        guard let file else { return false }
        revealThought(in: file, uid: parsed.uid)
        return true
    }

    /// The files showing now, in pane order.
    var visibleFiles: [FileRef] {
        var out: [FileRef] = []
        for id in tiling.arrangement.visible { if let f = pane(id).file, !out.contains(f) { out.append(f) } }
        if let selected, !out.contains(selected) { out.insert(selected, at: 0) }
        return out
    }

    /// Resurface: a thought from a while ago that bears on what is open, else any old one.
    func resurfaceThought() {
        guard let s = session else { return }
        let near = visibleFiles
        let seen = thoughts.resurfaced
        Task { [weak self] in
            var found: (FileRef, Comment)?
            if !near.isEmpty, let index = try? await s.searchIndex(for: .semantic) {
                found = await Task.detached(priority: .userInitiated) { try? index.resurfaceableThought(near: near, seen: seen) }.value
            }
            if found == nil { found = await s.resurfaceableThought() }
            guard let self, self.session === s else { return }
            guard let found else { self.showToast(ToastMessage(text: "No thoughts yet")); return }
            self.thoughts.resurfaced.insert(found.1.id.uuidString)
            if let uid = found.1.uid { self.thoughts.resurfaced.insert(uid) }
            self.revealThought(in: found.0, uid: found.1.uid, commentID: found.1.id, anchor: found.1.anchor)
        }
    }

    // MARK: Capture

    func wireThoughtCapture() {
        let cc = CaptureController.shared
        cc.similarThoughts = { [weak self] draft in await self?.similarThoughtHits(draft) ?? [] }
        cc.onJumpToThought = { [weak self] hit in self?.jumpToThought(hit) }
        cc.currentFolder = { [weak self] in
            guard let folder = self?.selectedFolder, !folder.isEmpty else { return nil }
            return FileRef(relativePath: folder)
        }
        cc.onSaveNoteComment = { [weak self] file, comment, frontmatter in
            guard let self else { throw CocoaError(.fileWriteUnknown) }
            try await self.saveNoteComment(comment, to: file, frontmatter: frontmatter)
        }
    }

    // MARK: Palette

    var thoughtCommands: [PaletteCommand] {
        let ready = vault != nil && thoughts.service != nil
        var list: [PaletteCommand] = []
        if nightShiftPaused {
            list.append(PaletteCommand(id: "nightshift-resume", title: "Resume Night Shift", keys: nil, symbol: "moon.stars", enabled: ready) { [weak self] in self?.setNightShiftEnabled(true) })
        } else {
            list.append(PaletteCommand(id: "nightshift-pause", title: "Pause Night Shift", keys: nil, symbol: "moon.zzz", enabled: ready) { [weak self] in self?.setNightShiftEnabled(false) })
        }
        list.append(PaletteCommand(id: "nightshift-now", title: "Work on Open Thoughts Now", keys: nil, symbol: "bolt", enabled: ready) { [weak self] in self?.workOnOpenThoughtsNow() })
        return list
    }

    // MARK: QA

    /// `reply`, `ai`, `nightshift`, `clock` from the QA hook.
    func runThoughtsQA(_ verb: String, _ rest: String) {
        switch verb {
        case "clock":
            if rest == "reset" { Self.qaNow = nil; Log.debug("qa: clock real") }
            else if let date = QAClock.parse(rest) { Self.qaNow = date; Log.debug("qa: clock \(date)") }
            else { Log.debug("qa: clock not understood: \(rest)") }
        case "reply":
            guard let file = selected else { return Log.debug("qa: reply needs an open file") }
            Task {
                let target = selectedCommentID.flatMap { id in comments.first { $0.id == id } }
                    ?? comments.last { $0.meta?.parent == nil && $0.provenance?.origin != .ai }
                guard let target else { return Log.debug("qa: no thought to reply to") }
                do {
                    let uid = try await thoughtUID(for: target, in: file)
                    try await saveThoughtReply(text: rest, toUID: uid, in: file)
                } catch { Log.debug("qa: reply not saved: \(error)") }
            }
        case "ai":
            guard let file = selected else { return Log.debug("qa: ai needs an open file") }
            Task {
                do { try await saveComment(Comment(timestamp: Self.now, anchor: anchor, text: "@ai " + rest), to: file) }
                catch { Log.debug("qa: ai not saved: \(error)") }
            }
        case "nightshift":
            guard let service = thoughts.service else { return Log.debug("nightshift: no service") }
            if rest == "plan" {
                Task.detached {
                    do {
                        let jobs = try service.plan()
                        Log.debug("nightshift: plan jobs=\(jobs.count)")
                        for j in jobs { Log.debug("nightshift: plan job=\(j.id) recipe=\(j.recipe.rawValue) uid=\(j.uid) file=\(j.file.relativePath)") }
                    } catch { Log.debug("nightshift: plan failed \(error)") }
                }
            } else if rest == "now", let scheduler = thoughts.scheduler {
                let saved = service.plannerSettings
                service.plannerSettings.minimumAge = -1e9   // QA's clock may sit before the thought was written
                QAGate.isOpen = true
                Task.detached {
                    let outcome = await scheduler.tick()
                    QAGate.isOpen = false
                    service.plannerSettings = saved
                    Log.debug("nightshift: now \(outcome.map { Self.describe($0) } ?? "nothing")")
                }
            }
        default: break
        }
    }
}

/// The pieces of a thread the `@ai` path needs.
enum ThoughtThread {
    /// The thought's whole thread, root first, then replies in time order.
    static func members(of comment: Comment, in all: [Comment]) -> [Comment] {
        var byUID: [String: Comment] = [:]
        for c in all { if let uid = c.uid { byUID[uid] = c } }
        func root(of c: Comment) -> Comment {
            var at = c, steps = 0
            while let p = at.meta?.parent, let up = byUID[p], steps <= all.count { at = up; steps += 1 }
            return at
        }
        let top = root(of: comment)
        var family: Set<String> = top.uid.map { [$0] } ?? []
        var out = [top]
        for c in all.sorted(by: { $0.timestamp < $1.timestamp }) where c.id != top.id {
            if let p = c.meta?.parent, family.contains(p) {
                out.append(c)
                if let uid = c.uid { family.insert(uid) }
            }
        }
        return out
    }

    /// Earlier exchanges of the thread: a thought and the AI reply to it. Each is marked as
    /// drawn from thoughts, because its question is one.
    static func history(of thread: [Comment], before comment: Comment) -> [ConversationTurn] {
        var byUID: [String: Comment] = [:]
        for c in thread { if let uid = c.uid { byUID[uid] = c } }
        var turns: [ConversationTurn] = []
        for reply in thread where reply.provenance?.origin == .ai && reply.timestamp <= comment.timestamp {
            guard let parent = reply.meta?.parent.flatMap({ byUID[$0] }), parent.id != comment.id, parent.provenance?.origin != .ai else { continue }
            let q = ThoughtRules.prose(of: parent.text)
            turns.append(ConversationTurn(question: q.isEmpty ? parent.text : q, answer: reply.text, thoughtDerived: true))
        }
        return turns
    }
}

enum ThoughtLines {
    /// The first line that is the person's own words (not a `>` quote), at most 120 characters.
    static func first(of text: String) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first { !$0.hasPrefix(">") }.map(String.init) ?? text
        return String(line.prefix(120)).trimmingCharacters(in: .whitespaces)
    }
}
