import XCTest
import FlamingoCore
import FlamingoAsk
@testable import FlamingoIndex
@testable import FlamingoThoughts

final class NightShiftRunnerTests: ThoughtsTestCase {
    let written = at("2026-10-16 18:40")
    var now: Date { at("2026-10-17 02:14") }
    let text = "review conflict between this and [[q3-model.xlsx]] before friday"
    var worker = FakeWorker()
    var runner: NightShiftRunner!

    override func setUpWithError() throws {
        try super.setUpWithError()
        worker = FakeWorker()
        runner = NightShiftRunner(vault: vault, store: store, ledger: ledger(), worker: worker, clock: { [now] in now })
    }

    /// A thought in the deck's note, and the job the planner would make of it.
    func thought(_ text: String? = nil, uid: String = "t8m2k4q9xa", at date: Date? = nil) throws -> (Comment, PlannedJob) {
        let body = text ?? self.text
        try store.append(Comment(timestamp: date ?? written, anchor: FileAnchor(kind: .slide, value: "7"), text: body,
                                 provenance: CommentProvenance(origin: .human), meta: ThoughtMeta(uid: uid)), to: Self.deck)
        let c = try XCTUnwrap(store.comment(uid: uid, in: Self.deck))
        let objects = ["decks/q3-board-review.pptx#slide 7", "finance/q3-model.xlsx"]
        let hash = WorkFingerprint.hash(WorkFingerprint.sources(of: WorkFingerprint.paths(objects: objects, target: Self.deck), in: vault))
        let job = PlannedJob(id: WorkFingerprint.jobID(uid: uid, recipe: "review-conflict", hash: hash), uid: uid, file: Self.deck,
                             anchor: c.anchor, recipe: .reviewConflict, objects: objects, fingerprint: hash, thoughtText: c.text,
                             thoughtTimestamp: c.timestamp, kind: .intent, resume: .fresh, attempts: 0)
        return (c, job)
    }

    func run(_ jobs: [PlannedJob], budget: NightBudget = .night, shouldContinue: @escaping @Sendable () -> Bool = { true }) async -> RunSummary {
        await runner.run(jobs, budget: budget, night: "2026-10-16", shouldContinue: shouldContinue)
    }

    func thread(_ uid: String = "t8m2k4q9xa") throws -> [Comment] { try store.comments(for: Self.deck).filter { $0.meta?.parent == uid } }

    // MARK: The happy path

    func testAMemoThenAnAIReplyOnTheThought() async throws {
        let (_, job) = try thought()
        let summary = await run([job])
        XCTAssertEqual(summary.attempted, 1); XCTAssertEqual(summary.finished, 1); XCTAssertEqual(summary.replied, 1); XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(summary.tokens, 1_000)
        XCTAssertEqual(summary.stop, .finishedAll)

        let memoURL = vault.stateDir.appendingPathComponent("work/2026-10-17/arc-price-deck-249-model-229.md")
        let memo = try XCTUnwrap(WorkMemo.read(at: memoURL))
        XCTAssertEqual(memo.thought, "t8m2k4q9xa")
        XCTAssertEqual(memo.recipe, "review-conflict")

        let reply = try XCTUnwrap(thread().first)
        XCTAssertEqual(reply.meta?.parent, "t8m2k4q9xa")
        XCTAssertEqual(reply.meta?.work, "work/2026-10-17/arc-price-deck-249-model-229.md")
        XCTAssertEqual(reply.provenance?.origin, .ai)
        XCTAssertEqual(reply.provenance?.model, "fake-model")
        XCTAssertEqual(reply.provenance?.reason, "review-conflict")
        XCTAssertNotNil(reply.meta?.uid)
        XCTAssertEqual(reply.anchor, FileAnchor(kind: .slide, value: "7"))
        XCTAssertEqual(reply.timestamp, now)
        XCTAssertTrue(reply.text.hasPrefix("Conflict. Slide 7 says $249"))
        XCTAssertTrue(reply.text.contains("[[decks/q3-board-review.pptx#slide 7]]"), "Obsidian sees the sources")
        XCTAssertFalse(reply.text.contains("work/"), "the memo path is in the hidden key, not the words")

        let events = ledger().events().map(\.event)
        XCTAssertEqual(events, [.queued, .started, .finished, .replied])
        XCTAssertEqual(ledger().record(for: job.id)?.phase, .done)
        XCTAssertEqual(ledger().events()[2].tokens, 1_000)
    }

    func testTheMemoRequestCarriesTheThoughtAndTheFilesItNames() async throws {
        let (c, job) = try thought()
        _ = await run([job])
        let r = try XCTUnwrap(worker.requests.first)
        XCTAssertEqual(r.thoughtUID, "t8m2k4q9xa")
        XCTAssertEqual(r.thoughtText, c.text)
        XCTAssertEqual(r.objects, job.objects)
        XCTAssertEqual(r.recipe, .reviewConflict)
        XCTAssertEqual(r.purpose, .nightShift)
        XCTAssertEqual(r.now, now)
    }

    func testItWritesNothingOutsideDotFlamingoAndRecordsNoTrail() async throws {
        let before = try snapshot(excludingState: true)
        let (_, job) = try thought()
        let trailBefore = FileManager.default.fileExists(atPath: vault.trailURL.path)
        _ = await run([job])
        XCTAssertEqual(try snapshot(excludingState: true), before, "no user file was touched")
        XCTAssertEqual(FileManager.default.fileExists(atPath: vault.trailURL.path), trailBefore, "and no trail event")
        let written = try FileManager.default.subpathsOfDirectory(atPath: vault.stateDir.path).filter { !$0.contains(".tmp") }
        XCTAssertTrue(written.contains { $0.hasPrefix("work/2026-10-17/") })
        XCTAssertTrue(written.contains("work/ledger.jsonl"))
        XCTAssertTrue(written.contains { $0.hasPrefix("notes/decks/") })
        XCTAssertFalse(written.contains { $0.hasPrefix("trail") })
    }

    /// Every file outside `.flamingo` with its size and modification time.
    func snapshot(excludingState: Bool) throws -> [String: String] {
        var out: [String: String] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: root.path) where !path.hasPrefix(".flamingo") {
            let a = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)
            out[path] = "\(a[.size] ?? 0)|\(a[.modificationDate] ?? Date())"
        }
        return out
    }

    func testAMemoTitledLikeAPathStaysInsideTheWorkFolder() async throws {
        worker.title = { _ in "../../../etc/passwd" }
        let (_, job) = try thought()
        _ = await run([job])
        let memos = try FileManager.default.subpathsOfDirectory(atPath: vault.workDir.path).filter { $0.hasSuffix(".md") }
        XCTAssertEqual(memos.count, 1)
        XCTAssertTrue(memos[0].hasPrefix("2026-10-17/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("etc").path))
    }

    func testTwoThoughtsWithTheSameTitleDoNotOverwriteEachOther() async throws {
        let (_, a) = try thought(uid: "ta00000000")
        let (_, b) = try thought("review conflict, second thought [[q3-model.xlsx]]", uid: "tb00000000", at: written.addingTimeInterval(60))
        _ = await run([a, b])
        let memos = try FileManager.default.subpathsOfDirectory(atPath: vault.workDir.path).filter { $0.hasSuffix(".md") }
        XCTAssertEqual(memos.count, 2, "\(memos)")
        XCTAssertEqual(Set(memos.compactMap { WorkMemo.read(at: vault.workDir.appendingPathComponent($0))?.thought }), ["ta00000000", "tb00000000"])
    }

    // MARK: Idempotent, resumable, two tries

    func testRunningADoneJobAgainDoesNothing() async throws {
        let (_, job) = try thought()
        _ = await run([job])
        let again = await run([job])
        XCTAssertEqual(worker.requests.count, 1)
        XCTAssertEqual(try thread().count, 1, "one reply")
        XCTAssertEqual(again.finished, 0); XCTAssertEqual(again.replied, 0)
        XCTAssertEqual(ledger().events().map(\.event), [.queued, .started, .finished, .replied])
    }

    func testAMemoWithoutItsReplyGetsOnlyTheReply() async throws {
        let (c, job) = try thought()
        // The first run wrote the memo and died before the reply.
        let first = await run([job])
        XCTAssertEqual(first.replied, 1)
        try store.delete(try XCTUnwrap(thread().first).id, from: Self.deck)
        // ...and the ledger forgot the reply (the crash came before it was logged).
        let l = ledger()
        let kept = l.events().filter { $0.event != .replied }
        try FileManager.default.removeItem(at: vault.workLedgerURL)
        for e in kept { try l.append(e) }
        XCTAssertEqual(l.record(for: job.id)?.phase, .needsReply)

        var resumed = job; if let memo = l.record(for: job.id)?.memo { resumed.resume = .reply(memo: memo) }
        let second = await run([resumed])
        XCTAssertEqual(worker.requests.count, 1, "the model was not asked again")
        XCTAssertEqual(second.replied, 1); XCTAssertEqual(second.finished, 0)
        let reply = try XCTUnwrap(thread().first)
        XCTAssertTrue(reply.text.hasPrefix("Conflict."), reply.text)
        XCTAssertTrue(reply.text.contains("[[decks/q3-board-review.pptx#slide 7]]") || reply.text.contains("Sources:"))
        XCTAssertEqual(l.record(for: job.id)?.phase, .done)
        _ = c
    }

    func testAReplyThatIsAlreadyThereIsNotAddedAgain() async throws {
        let (_, job) = try thought()
        _ = await run([job])
        // Crash after the reply was saved but before the ledger heard of it.
        let l = ledger()
        let kept = l.events().filter { $0.event != .replied }
        try FileManager.default.removeItem(at: vault.workLedgerURL)
        for e in kept { try l.append(e) }
        _ = await run([job])
        XCTAssertEqual(try thread().count, 1)
        XCTAssertEqual(l.record(for: job.id)?.phase, .done)
    }

    func testAFailedTryLeavesNoMemoAndNoReplyAndAJobGetsTwo() async throws {
        let (_, job) = try thought()
        worker.behaviour = { _ in throw WorkError.invalidOutput("not JSON") }
        let first = await run([job])
        XCTAssertEqual(first.failed, 1); XCTAssertEqual(first.finished, 0)
        XCTAssertTrue(try thread().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.workDir.appendingPathComponent("2026-10-17").path))
        XCTAssertEqual(ledger().record(for: job.id)?.phase, .retryable)
        XCTAssertEqual(ledger().record(for: job.id)?.lastError, "The model's answer wasn't usable: not JSON")
        _ = await run([job])
        XCTAssertEqual(ledger().record(for: job.id)?.phase, .exhausted)
        _ = await run([job])
        XCTAssertEqual(worker.requests.count, 2, "never a third")
        XCTAssertTrue(try thread().isEmpty)
    }

    func testASecondTryCanSucceed() async throws {
        let (_, job) = try thought()
        let calls = Counter()
        worker.behaviour = { _ in if calls.next() == 1 { throw WorkError.invalidOutput("not JSON") } }
        _ = await run([job])
        XCTAssertTrue(try thread().isEmpty)
        let second = await run([job])
        XCTAssertEqual(second.replied, 1)
        XCTAssertEqual(try thread().count, 1)
        XCTAssertEqual(ledger().events().map(\.event), [.queued, .started, .failed, .started, .finished, .replied])
    }

    func testACrashedTryCountsAndTheJobResumes() async throws {
        let (_, job) = try thought()
        let l = ledger()
        try l.append(LedgerEvent(.queued, at: now, job: job.id, uid: job.uid, recipe: "review-conflict"))
        try l.append(LedgerEvent(.started, at: now, job: job.id, uid: job.uid, recipe: "review-conflict", attempt: 1)) // then the Mac slept
        XCTAssertEqual(l.record(for: job.id)?.phase, .interrupted)
        let summary = await run([job])
        XCTAssertEqual(summary.replied, 1)
        XCTAssertEqual(l.events().filter { $0.event == .started }.compactMap(\.attempt), [1, 2])
    }

    func testAFileThatChangedMidRunLeavesNoReply() async throws {
        let (_, job) = try thought()
        worker.behaviour = { _ in throw WorkError.sourceChanged }
        _ = await run([job])
        XCTAssertTrue(try thread().isEmpty)
        XCTAssertNil(ledger().record(for: job.id)?.memo)
        XCTAssertEqual(ledger().record(for: job.id)?.phase, .retryable)
    }

    func testNoReadableSourceIsFinalAtOnce() async throws {
        let (_, job) = try thought()
        worker.behaviour = { _ in throw WorkError.noSources("gone") }
        _ = await run([job])
        XCTAssertEqual(ledger().record(for: job.id)?.phase, .exhausted)
    }

    // MARK: The thought changes under it

    func testAThoughtThePersonAnsweredIsLeftAlone() async throws {
        let (_, job) = try thought()
        try store.appendReply(Comment(timestamp: now, text: "Already sorted it", provenance: CommentProvenance(origin: .human)), toUID: "t8m2k4q9xa", in: Self.deck)
        let summary = await run([job])
        XCTAssertTrue(worker.requests.isEmpty)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(try thread().count, 1, "only the person's reply")
        XCTAssertEqual(ledger().record(for: job.id)?.phase, .exhausted)
    }

    func testAThoughtDoneOrEditedBeforeTheRunIsLeftAlone() async throws {
        let (_, job) = try thought()
        try store.update(uid: "t8m2k4q9xa", in: Self.deck) { $0.meta?.state = .done }
        _ = await run([job])
        XCTAssertTrue(worker.requests.isEmpty)

        let (_, second) = try thought("a different thought [[q3-model.xlsx]]", uid: "tb00000000")
        try store.update(uid: "tb00000000", in: Self.deck) { $0.text = "edited since the plan" }
        _ = await run([second])
        XCTAssertTrue(worker.requests.isEmpty)
        XCTAssertTrue(try thread("tb00000000").isEmpty)
    }

    func testAThoughtDoneWhileTheModelWorkedGetsNoMemo() async throws {
        let (_, job) = try thought()
        let store = self.store!
        worker.behaviour = { _ in try store.update(uid: "t8m2k4q9xa", in: ThoughtsTestCase.deck) { $0.meta?.state = .done } }
        _ = await run([job])
        XCTAssertTrue(try thread().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.workDir.appendingPathComponent("2026-10-17").path))
    }

    func testAThoughtThatIsGoneIsRecordedAndSkipped() async throws {
        let (_, job) = try thought()
        try store.delete(try XCTUnwrap(store.comment(uid: "t8m2k4q9xa", in: Self.deck)).id, from: Self.deck)
        let summary = await run([job])
        XCTAssertEqual(summary.failed, 1)
        XCTAssertTrue(worker.requests.isEmpty)
    }

    // MARK: Budgets

    func jobs(_ n: Int) throws -> [PlannedJob] {
        try (0..<n).map { i in try thought("review conflict \(i) [[q3-model.xlsx]]", uid: "t\(i)000000000", at: written.addingTimeInterval(Double(i) * 60)).1 }
    }

    func testStopsAtTheJobBudget() async throws {
        let list = try jobs(4)
        let summary = await run(list, budget: NightBudget(jobs: 2, wallSeconds: 3600, tokens: 1_000_000, perJobSeconds: 60))
        XCTAssertEqual(summary.attempted, 2); XCTAssertEqual(summary.stop, .jobBudget)
        XCTAssertEqual(worker.requests.count, 2)
    }

    func testStopsAtTheTokenBudget() async throws {
        worker.tokens = 400
        let summary = await run(try jobs(5), budget: NightBudget(jobs: 6, wallSeconds: 3600, tokens: 1_000, perJobSeconds: 60))
        XCTAssertEqual(summary.stop, .tokenBudget)
        XCTAssertEqual(summary.attempted, 3, "400 + 400 + 400 passes 1,000")
    }

    func testStopsAtTheTimeBudget() async throws {
        worker.behaviour = { _ in try await Task.sleep(nanoseconds: 60_000_000) }
        let summary = await run(try jobs(6), budget: NightBudget(jobs: 6, wallSeconds: 0.1, tokens: 1_000_000, perJobSeconds: 60))
        XCTAssertEqual(summary.stop, .timeBudget)
        XCTAssertLessThan(summary.attempted, 6)
    }

    func testStopsWhenTheConditionsStopHolding() async throws {
        let list = try jobs(4)
        let seen = Counter()
        let summary = await run(list, shouldContinue: { seen.next() <= 2 })
        XCTAssertEqual(summary.stop, .conditionsChanged)
        XCTAssertEqual(summary.attempted, 2, "asked before each job")
    }

    func testAJobThatRunsTooLongIsStoppedAndFailed() async throws {
        let (_, job) = try thought()
        worker.behaviour = { _ in try await Task.sleep(nanoseconds: 5_000_000_000) }
        let started = Date()
        let summary = await run([job], budget: NightBudget(jobs: 6, wallSeconds: 3600, tokens: 1_000_000, perJobSeconds: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertTrue(try thread().isEmpty)
    }

    func testCancellingStopsTheBatchWithoutBurningATry() async throws {
        let (_, job) = try thought()
        worker.behaviour = { _ in try await Task.sleep(nanoseconds: 5_000_000_000) }
        let runner = self.runner!
        let task = Task { await runner.run([job], budget: .night, night: "2026-10-16") }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let summary = await task.value
        XCTAssertEqual(summary.stop, .cancelled)
        XCTAssertTrue(try thread().isEmpty)
        XCTAssertNotEqual(ledger().record(for: job.id)?.phase, .exhausted)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}
