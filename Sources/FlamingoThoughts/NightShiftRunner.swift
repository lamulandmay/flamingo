import Foundation
import FlamingoCore
import FlamingoAsk

public enum NightShiftEvent: Sendable, Equatable {
    case started(job: String, recipe: String, file: String)
    case status(job: String, String)
    /// The memo is written (`memo` is relative to `.flamingo`); `tldr` is its first paragraph.
    case finished(job: String, memo: String, tldr: String)
    case replied(job: String)
    case failed(job: String, String)
}

public struct RunSummary: Sendable, Equatable {
    public enum Stop: String, Sendable { case finishedAll, jobBudget, timeBudget, tokenBudget, conditionsChanged, cancelled }
    public var attempted = 0
    public var finished = 0
    public var replied = 0
    public var failed = 0
    public var tokens = 0
    public var seconds: TimeInterval = 0
    public var stop: Stop = .finishedAll
}

/// Does planned jobs, one at a time, and leaves a trail in the ledger.
///
/// For each job: the work (a local model reads the files the thought names), the memo written
/// under `.flamingo/work`, then an AI reply on the thought, added to its note under
/// `.flamingo/notes`, carrying the TL;DR and wikilinks to the sources. It writes nothing else:
/// no user file, no Trail event. Running the same job twice does the second part only if the
/// first did not finish, and a job gets two tries at most.
public final class NightShiftRunner: @unchecked Sendable {
    public let vault: Vault
    let store: SidecarStore
    let ledger: WorkLedger
    let worker: WorkPerforming
    let clock: @Sendable () -> Date

    public init(vault: Vault, store: SidecarStore, ledger: WorkLedger, worker: WorkPerforming,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.vault = vault; self.store = store; self.ledger = ledger; self.worker = worker; self.clock = clock
    }

    /// Runs `jobs` in order until the budget is spent, the conditions stop holding or the task is
    /// cancelled. `night` is the id the ledger files these jobs under.
    public func run(_ jobs: [PlannedJob], budget: NightBudget, night: String, purpose: CompletionPurpose = .nightShift,
                    shouldContinue: @Sendable () -> Bool = { true },
                    onEvent: @escaping @Sendable (NightShiftEvent) -> Void = { _ in }) async -> RunSummary {
        var summary = RunSummary()
        let started = Date()
        for job in jobs {
            if Task.isCancelled { summary.stop = .cancelled; return summary }
            if !shouldContinue() { summary.stop = .conditionsChanged; return summary }
            if summary.attempted >= budget.jobs { summary.stop = .jobBudget; return summary }
            if Date().timeIntervalSince(started) >= budget.wallSeconds { summary.stop = .timeBudget; return summary }
            if summary.tokens >= budget.tokens { summary.stop = .tokenBudget; return summary }
            summary.attempted += 1
            let outcome = await runOne(job, night: night, purpose: purpose, perJobSeconds: budget.perJobSeconds, onEvent: onEvent)
            summary.tokens += outcome.tokens
            summary.seconds = Date().timeIntervalSince(started)
            if outcome.finished { summary.finished += 1 }
            if outcome.replied { summary.replied += 1 }
            if outcome.failed { summary.failed += 1 }
            if outcome.cancelled { summary.stop = .cancelled; return summary }
        }
        summary.seconds = Date().timeIntervalSince(started)
        return summary
    }

    struct Outcome { var finished = false, replied = false, failed = false, cancelled = false; var tokens = 0 }

    func runOne(_ job: PlannedJob, night: String, purpose: CompletionPurpose, perJobSeconds: TimeInterval,
                onEvent: @escaping @Sendable (NightShiftEvent) -> Void) async -> Outcome {
        var outcome = Outcome()
        func log(_ e: LedgerEvent) { try? ledger.append(e) }
        func base(_ kind: LedgerEvent.Kind) -> LedgerEvent {
            LedgerEvent(kind, at: clock(), night: night, job: job.id, uid: job.uid, recipe: job.recipe.rawValue, file: job.file.relativePath)
        }
        func fail(_ message: String, attempt: Int?, permanent: Bool) {
            var e = base(.failed); e.attempt = attempt; e.error = message; e.permanent = permanent ? true : nil
            log(e)
            onEvent(.failed(job: job.id, message))
            outcome.failed = true
        }

        // The thought must still be there, open and unchanged, with no reply from the person.
        guard let thought = try? store.comment(uid: job.uid, in: job.file) else {
            fail("The thought is gone", attempt: nil, permanent: true); return outcome
        }
        if let why = Self.reasonToLeaveAlone(thought, job: job, store: store) {
            fail(why, attempt: nil, permanent: true); return outcome
        }

        let record = ledger.record(for: job.id)
        // Done is done, and two tries are all a job gets.
        if let phase = record?.phase, phase == .done || phase == .exhausted { return outcome }
        if record == nil { log(base(.queued)) }

        // A memo without its reply: only the reply is missing.
        if let memoPath = record?.memo ?? { if case .reply(let m) = job.resume { return m } else { return nil } }(),
           record?.phase == .needsReply || { if case .reply = job.resume { return true } else { return false } }(),
           let memo = WorkMemo.read(at: vault.stateDir.appendingPathComponent(memoPath)) {
            let text = Self.replyText(from: memo)
            do {
                try appendReply(text, model: memo.model, recipe: job.recipe, memoPath: memoPath, to: thought, job: job)
                log(base(.replied)); onEvent(.replied(job: job.id)); outcome.replied = true
            } catch {
                fail("The reply could not be saved: \(error)", attempt: nil, permanent: false)
            }
            return outcome
        }

        let attempt = (record?.attempts ?? 0) + 1
        guard attempt <= JobRecord.maxAttempts else { return outcome }
        var startedEvent = base(.started); startedEvent.attempt = attempt
        log(startedEvent)
        onEvent(.started(job: job.id, recipe: job.recipe.rawValue, file: job.file.relativePath))

        let begun = Date()
        let request = WorkRequest(recipe: job.recipe, thoughtUID: job.uid, thoughtText: thought.text, thoughtTimestamp: thought.timestamp,
                                  file: job.file, anchor: thought.anchor, objects: job.objects, purpose: purpose, now: clock())
        let result: WorkResult
        do {
            result = try await Self.withTimeout(perJobSeconds) { [worker] in
                try await worker.work(request) { onEvent(.status(job: job.id, $0)) }
            }
        } catch is CancellationError {
            // Interrupted from outside: not the job's fault, and not a try.
            var e = base(.failed); e.attempt = attempt; e.error = "Cancelled"
            log(e); outcome.cancelled = true; return outcome
        } catch {
            let permanent = (error as? WorkError).map { if case .noSources = $0 { return true } else { return false } } ?? false
            fail((error as? LocalizedError)?.errorDescription ?? "\(error)", attempt: attempt, permanent: permanent)
            return outcome
        }

        // The thought may have been dealt with while the model worked.
        guard let again = try? store.comment(uid: job.uid, in: job.file), again.text == thought.text,
              Self.reasonToLeaveAlone(again, job: job, store: store) == nil else {
            fail("The thought changed while this ran", attempt: attempt, permanent: true); return outcome
        }

        let memoPath: String
        do { memoPath = try writeMemo(result.memo, job: job) }
        catch {
            fail("The memo could not be saved: \(error)", attempt: attempt, permanent: false); return outcome
        }
        var done = base(.finished)
        done.memo = memoPath; done.tokens = result.tokens; done.seconds = Date().timeIntervalSince(begun); done.model = result.model
        log(done)
        outcome.finished = true; outcome.tokens = result.tokens
        onEvent(.finished(job: job.id, memo: memoPath, tldr: String(result.memo.body.split(separator: "\n").first ?? "")))

        do {
            try appendReply(result.replyText, model: result.model, recipe: job.recipe, memoPath: memoPath, to: again, job: job)
            log(base(.replied)); onEvent(.replied(job: job.id)); outcome.replied = true
        } catch {
            // The memo stands; the next run adds only the reply.
            fail("The reply could not be saved: \(error)", attempt: attempt, permanent: false)
        }
        return outcome
    }

    // MARK: Pieces

    /// Why a thought is no longer a job: done or dropped, edited since it was planned, or answered
    /// by the person.
    static func reasonToLeaveAlone(_ thought: Comment, job: PlannedJob, store: SidecarStore) -> String? {
        if thought.state != .open { return "The thought is no longer open" }
        if thought.text != job.thoughtText { return "The thought was edited since it was planned" }
        let thread = ((try? store.comments(for: job.file)) ?? []).filter { $0.meta?.parent == job.uid }
        if thread.contains(where: { $0.provenance?.origin != .ai }) { return "The person already replied" }
        return nil
    }

    /// Writes the memo under `.flamingo/work`, never anywhere else. A memo with the same name
    /// that belongs to a different thought is not overwritten.
    func writeMemo(_ memo: WorkMemo, job: PlannedJob) throws -> String {
        var slug = WorkMemo.slug(for: memo.title.isEmpty ? memo.recipe : memo.title)
        let existing = memo.url(in: vault, slug: slug)
        if FileManager.default.fileExists(atPath: existing.path), let other = WorkMemo.read(at: existing),
           other.thought != memo.thought || other.recipe != memo.recipe {
            slug += "-" + String(job.uid.dropFirst().prefix(4))
        }
        let url = memo.url(in: vault, slug: slug)
        let root = vault.stateDir.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(root) else { throw SidecarError.writeFailed(path: url.path, errno: EPERM) }
        return try memo.write(in: vault, slug: slug)
    }

    /// The AI reply on the thought, once: if a reply for this memo is already in the thread, nothing is added.
    func appendReply(_ text: String, model: String, recipe: WorkRecipe, memoPath: String, to thought: Comment, job: PlannedJob) throws {
        let existing = try store.comments(for: job.file)
        if existing.contains(where: { $0.meta?.parent == job.uid && $0.meta?.work == memoPath }) { return }
        let reply = Comment(timestamp: clock(), anchor: thought.anchor, text: text,
                            provenance: CommentProvenance(origin: .ai, model: model, reason: recipe.rawValue),
                            meta: ThoughtMeta(work: memoPath))
        try store.appendReply(reply.stamped(), toUID: job.uid, in: job.file)
    }

    /// The reply for a memo whose reply was lost: its TL;DR and links to the sources it lists.
    static func replyText(from memo: WorkMemo) -> String {
        let tldr = memo.body.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? memo.title
        let links = memo.sources.map { entry -> String in
            let path = entry.components(separatedBy: " \u{00B7} ").first ?? entry
            return "[[\(path)]]"
        }
        let lead = ["conflict": "Conflict. ", "changed": "Changed. ", "consistent": "Consistent. ", "same": "Unchanged. "][memo.verdict ?? ""] ?? ""
        return lead + tldr + (links.isEmpty ? "" : "\nSources: " + links.joined(separator: ", "))
    }

    /// Runs `body`, giving up (and cancelling it) after `seconds`.
    static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw WorkError.invalidOutput("Took longer than \(Int(seconds / 60)) minutes")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }
}
