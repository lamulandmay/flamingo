import Foundation
import FlamingoCore
import FlamingoIndex
import FlamingoAsk

/// One piece of work the night shift could do.
public struct PlannedJob: Sendable, Equatable, Identifiable {
    public enum Resume: Sendable, Equatable {
        case fresh
        /// The memo is already written; only its reply is missing.
        case reply(memo: String)
    }

    /// `<uid>:<recipe>:<8 hex>`.
    public var id: String
    public var uid: String
    public var file: FileRef
    public var anchor: FileAnchor?
    public var recipe: WorkRecipe
    /// The files (and places) the thought names.
    public var objects: [String]
    public var fingerprint: String
    public var thoughtText: String
    public var thoughtTimestamp: Date
    public var kind: ThoughtKind
    public var resume: Resume
    /// Tries already made.
    public var attempts: Int
}

public struct PlannerSettings: Sendable, Equatable {
    /// A thought younger than this is still fresh in the person's mind.
    public var minimumAge: TimeInterval = 6 * 3600
    /// Time on a thought's files, since it was written, that counts as having acted on it.
    public var actedOnAfter: TimeInterval = 3 * 60
    /// After a memo, files that changed are not looked at again for this long.
    public var changedSourcesWait: TimeInterval = 7 * 86_400
    /// "Work on open thoughts now": the person asked, so age and attention don't matter.
    public var ignoresAgeAndAttention = false

    public init() {}
    public static var now: PlannerSettings { var s = PlannerSettings(); s.ignoresAgeAndAttention = true; return s }
}

/// Which thoughts the night shift works on. Pure over the thoughts, the trail's attention
/// and the ledger.
///
/// A thought becomes a job when it is open and asks for work (an intent, or a question or
/// to-do that a recipe fits), is at least six hours old, has no reply from the person, and
/// they haven't spent three minutes on all the files it names since writing it. It is not a job
/// again while a finished or failed one has the same fingerprint, and a memo's files changing
/// does not bring it back for seven days.
public struct NightShiftPlanner: Sendable {
    public var settings: PlannerSettings
    public var vault: Vault

    public init(vault: Vault, settings: PlannerSettings = PlannerSettings()) {
        self.vault = vault; self.settings = settings
    }

    /// Whether a thought could ever be a job, before looking at time or the ledger. Cheap; the
    /// service uses it to decide which legacy thoughts deserve a uid.
    public static func recipe(for r: ThoughtRecord) -> WorkRecipe? {
        guard r.state == .open, r.origin == .human, r.parent == nil, r.kind != .idea || r.action != nil else { return nil }
        if let action = r.action, let recipe = WorkRecipe(action: action) { return recipe }
        // The words alone: an intent or a to-do that names its recipe.
        guard let name = ThoughtRules.read(r.comment.text, at: r.comment.timestamp).recipe else { return nil }
        return WorkRecipe(action: name)
    }

    /// Jobs in the order to run them: due soonest, then oldest first.
    ///
    /// - Parameters:
    ///   - attention: seconds the person spent on a file since a time (`TrailStore.attention`).
    ///   - resolve: a link name to a file in the vault.
    public func plan(records: [ThoughtRecord], now: Date, ledger: WorkLedger,
                     attention: (_ files: [FileRef], _ since: Date) -> [FileRef: TimeInterval],
                     resolve: (_ link: String, _ near: FileRef) -> FileRef? = { _, _ in nil }) -> [PlannedJob] {
        let jobs = ledger.jobs()
        var planned: [(job: PlannedJob, due: Date?)] = []
        for r in records {
            guard let recipe = Self.recipe(for: r), let uid = r.uid else { continue }
            guard r.lastHumanReplyAt == nil else { continue }
            if !settings.ignoresAgeAndAttention, now.timeIntervalSince(r.comment.timestamp) < settings.minimumAge { continue }

            let objects = Self.objects(of: r, resolve: resolve)
            let paths = WorkFingerprint.paths(objects: objects, target: r.file)
            let sources = WorkFingerprint.sources(of: paths, in: vault)
            guard !sources.isEmpty else { continue }

            if !settings.ignoresAgeAndAttention {
                // Acted on: the person went and spent the time on every file it names.
                let named = Set(WorkFingerprint.paths(objects: objects, target: objects.isEmpty ? r.file : nil).map(FileRef.init(relativePath:)))
                if !named.isEmpty {
                    let spent = attention(Array(named), r.comment.timestamp)
                    if named.allSatisfy({ (spent[$0] ?? 0) >= settings.actedOnAfter }) { continue }
                }
            }

            let hash = WorkFingerprint.hash(sources)
            let id = WorkFingerprint.jobID(uid: uid, recipe: recipe.rawValue, hash: hash)
            var resume = PlannedJob.Resume.fresh
            var attempts = 0
            if let record = jobs[id] {
                attempts = record.attempts
                switch record.phase {
                case .done, .exhausted: continue
                case .needsReply: if let memo = record.memo { resume = .reply(memo: memo) }
                case .queued, .interrupted, .retryable: break
                }
            } else if let last = ledger.lastFinished(uid: uid, recipe: recipe.rawValue),
                      now.timeIntervalSince(last.at) < settings.changedSourcesWait {
                // Same thought, same recipe, different files: too soon to look again.
                continue
            }
            let job = PlannedJob(id: id, uid: uid, file: r.file, anchor: r.comment.anchor, recipe: recipe, objects: objects,
                                 fingerprint: hash, thoughtText: r.comment.text, thoughtTimestamp: r.comment.timestamp,
                                 kind: r.kind, resume: resume, attempts: attempts)
            planned.append((job, r.due))
        }
        return planned.sorted { a, b in
            switch (a.due, b.due) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.job.thoughtTimestamp != b.job.thoughtTimestamp ? a.job.thoughtTimestamp < b.job.thoughtTimestamp : a.job.id < b.job.id
            }
        }.map(\.job)
    }

    /// The files a thought names: the model's reading of it when it has one, else the files its
    /// words link to. The place it was left (`path#slide 7`) comes first when there is one.
    static func objects(of r: ThoughtRecord, resolve: (String, FileRef) -> FileRef?) -> [String] {
        if let objects = r.comment.meta?.intent?.objects, !objects.isEmpty { return Array(objects.prefix(6)) }
        var out: [String] = []
        if !r.file.isVirtual { out.append(r.file.relativePath + (r.comment.anchor.map { "#" + $0.label } ?? "")) }
        for link in r.comment.links {
            let target = Wikilink.components(of: link).target
            guard let ref = resolve(target, r.file), !out.contains(where: { $0.hasPrefix(ref.relativePath) }) else { continue }
            out.append(ref.relativePath)
            if out.count == 6 { break }
        }
        return out
    }
}
