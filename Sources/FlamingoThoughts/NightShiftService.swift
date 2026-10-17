import Foundation
import FlamingoCore
import FlamingoIndex
import FlamingoAsk
import FlamingoTrail

public enum NightShiftOutcome: Sendable, Equatable {
    case ran(RunSummary)
    /// Outside the window; the scheduler will ask again then.
    case waiting(until: Date)
    case skipped(GateSkip)
}

/// The night shift for one vault: plan, gate, run. Everything the app shell calls (the
/// scheduler, catch-up at first open, "Work on Open Thoughts Now", the QA hooks) goes through here.
///
/// Local models only: the worker is a `WorkPerforming`, in the app the `AskEngine`, whose
/// `work` can only reach a model on this Mac.
public final class NightShiftService: @unchecked Sendable {
    public let vault: Vault
    public let index: IndexStore
    public let store: SidecarStore
    public let trail: TrailStore
    public let ledger: WorkLedger
    public let runner: NightShiftRunner

    public var settings = NightShiftSettings()
    public var plannerSettings = PlannerSettings()
    /// Plan 13's compute budget plugs in here; nil until it does.
    public var budgetOverride: (@Sendable () -> BudgetOverride?)?
    public var calendar = Calendar.current
    let clock: @Sendable () -> Date
    let resolve: @Sendable (String, FileRef) -> FileRef?

    public init(vault: Vault, index: IndexStore, store: SidecarStore, trail: TrailStore, worker: WorkPerforming,
                resolve: (@Sendable (String, FileRef) -> FileRef?)? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.vault = vault; self.index = index; self.store = store; self.trail = trail
        self.ledger = WorkLedger(vault: vault)
        self.clock = clock
        self.resolve = resolve ?? { [index] target, near in resolveVaultFile(target, near: near, in: index) }
        self.runner = NightShiftRunner(vault: vault, store: store, ledger: ledger, worker: worker, clock: clock)
    }

    // MARK: Planning

    /// The jobs there are right now. Reads the index and the trail; call off the main thread.
    /// A legacy thought that would be a job gets its uid here (the first time something refers to it).
    public func plan(now: Date? = nil, relaxed: Bool = false) throws -> [PlannedJob] {
        let now = now ?? clock()
        var q = ThoughtQuery(states: [.open], kinds: [.intent, .question, .todo], order: .oldest, limit: 600)
        q.origin = .human
        q.isReply = false
        var records = try index.thoughts(q)
        // Ideas the model read as asking for work carry an intent action and kind `intent`, so they are here too.
        for i in records.indices where records[i].uid == nil && NightShiftPlanner.recipe(for: records[i]) != nil {
            if let uid = try? store.ensureUID(forCommentID: records[i].comment.id, in: records[i].file) { records[i].uid = uid }
        }
        let events = try trail.events()
        var planner = NightShiftPlanner(vault: vault, settings: relaxed ? .now : plannerSettings)
        planner.settings.changedSourcesWait = plannerSettings.changedSourcesWait
        return planner.plan(records: records, now: now, ledger: ledger,
                            attention: { files, since in TrailStore.attention(in: events, on: Set(files), since: since, now: now) },
                            resolve: resolve)
    }

    // MARK: Running

    public func gate() -> NightShiftGate { NightShiftGate(settings: settings, calendar: calendar) }

    /// One scheduler tick: if the night allows it and there is something to do, does it.
    /// `shouldContinue` is asked between jobs, so a person coming back (or the cable coming out)
    /// ends the batch after the job in hand.
    public func runTonight(power: PowerSnapshot, idleSeconds: TimeInterval,
                           shouldContinue: @escaping @Sendable () -> Bool = { true },
                           onEvent: @escaping @Sendable (NightShiftEvent) -> Void = { _ in }) async -> NightShiftOutcome {
        let now = clock()
        let gate = gate()
        switch gate.decide(now: now, power: power, idleSeconds: idleSeconds, history: ledger.history(), budgetOverride: budgetOverride) {
        case .skip(let why): return .skipped(why)
        case .wait(let until): return .waiting(until: until)
        case .run(let budget):
            guard let night = gate.nightID(at: now) else { return .skipped(.disabled) }
            guard let jobs = try? plan(now: now), !jobs.isEmpty else { return .skipped(.nothingToDo) }
            try? ledger.append(LedgerEvent(.nightStart, at: now, night: night))
            let summary = await runner.run(jobs, budget: budget, night: night, purpose: .nightShift, shouldContinue: shouldContinue, onEvent: onEvent)
            // The night is over for this shift when it ran out of budget or of work, not when it was interrupted.
            if [.finishedAll, .jobBudget, .timeBudget, .tokenBudget].contains(summary.stop) {
                try? ledger.append(LedgerEvent(.nightEnd, at: clock(), night: night, reason: summary.stop.rawValue))
            }
            return .ran(summary)
        }
    }

    /// The first open of the day after a night that didn't run: up to three jobs in 12 minutes.
    /// Call it once per day at the first activation; it declines on its own when it isn't needed.
    public func catchUp(power: PowerSnapshot, onEvent: @escaping @Sendable (NightShiftEvent) -> Void = { _ in }) async -> NightShiftOutcome {
        let now = clock()
        let gate = gate()
        let history = ledger.history()
        // Cheap checks first: planning reads the index and the trail.
        let probe = gate.decideCatchUp(now: now, power: power, history: history, candidates: 1, budgetOverride: budgetOverride)
        guard case .run(let budget) = probe else {
            if case .skip(let why) = probe { return .skipped(why) }
            return .skipped(.nothingToDo)
        }
        guard let jobs = try? plan(now: now), !jobs.isEmpty else { return .skipped(.nothingToDo) }
        let day = BriefingDay.key(now, calendar: calendar)
        try? ledger.append(LedgerEvent(.catchUpStart, at: now, night: day))
        let summary = await runner.run(jobs, budget: budget, night: day, purpose: .nightShift, onEvent: onEvent)
        try? ledger.append(LedgerEvent(.catchUpEnd, at: clock(), night: day, reason: summary.stop.rawValue))
        return .ran(summary)
    }

    /// "Work on Open Thoughts Now": the person asked, so the window, power and idle time don't
    /// matter and a thought's age and attention are ignored. Interactive models, a short budget.
    public func workNow(limit: Int = 3, onEvent: @escaping @Sendable (NightShiftEvent) -> Void = { _ in }) async -> RunSummary {
        let now = clock()
        guard let jobs = try? plan(now: now, relaxed: true), !jobs.isEmpty else { return RunSummary() }
        return await runner.run(jobs, budget: NightBudget.now.capped(by: NightBudget(jobs: limit, wallSeconds: .infinity, tokens: .max, perJobSeconds: .infinity)),
                                night: BriefingDay.key(now, calendar: calendar), purpose: .interactive, onEvent: onEvent)
    }

    /// "Work on This Now ▸ recipe": one thought, one recipe, whatever its age. Returns nil when
    /// the thought can't be found.
    public func workNow(thoughtUID uid: String, in file: FileRef, recipe: WorkRecipe, objects: [String]? = nil,
                        onEvent: @escaping @Sendable (NightShiftEvent) -> Void = { _ in }) async -> RunSummary? {
        guard let thought = try? store.comment(uid: uid, in: file) else { return nil }
        let named = objects ?? thought.meta?.intent?.objects ?? [file.relativePath + (thought.anchor.map { "#" + $0.label } ?? "")]
        let sources = WorkFingerprint.sources(of: WorkFingerprint.paths(objects: named, target: file), in: vault)
        guard !sources.isEmpty else { return nil }
        let hash = WorkFingerprint.hash(sources)
        let job = PlannedJob(id: WorkFingerprint.jobID(uid: uid, recipe: recipe.rawValue, hash: hash), uid: uid, file: file,
                             anchor: thought.anchor, recipe: recipe, objects: named, fingerprint: hash, thoughtText: thought.text,
                             thoughtTimestamp: thought.timestamp, kind: .intent, resume: .fresh, attempts: 0)
        let now = clock()
        return await runner.run([job], budget: .now, night: BriefingDay.key(now, calendar: calendar), purpose: .interactive, onEvent: onEvent)
    }
}
