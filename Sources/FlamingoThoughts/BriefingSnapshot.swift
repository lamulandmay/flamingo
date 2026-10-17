import Foundation
import FlamingoCore
import FlamingoIndex
import FlamingoTrail

/// A memo the night shift wrote that the person hasn't opened.
public struct MemoCardData: Identifiable, Sendable, Equatable {
    /// Relative to `.flamingo`, e.g. `work/2026-10-17/arc-price.md`.
    public var path: String
    public var memo: WorkMemo
    /// The memo's first paragraph.
    public var tldr: String
    /// The thought it answers, when it is still there.
    public var thought: ThoughtRecord?
    public var id: String { path }
}

/// A file with open thoughts that changed after both the thoughts and the last time it was opened.
public struct EditedFileItem: Identifiable, Sendable, Equatable {
    public var file: FileRef
    public var modified: Date
    public var openThoughts: Int
    public var id: String { file.relativePath }
}

/// A file close in meaning to one of the files most thought about.
public struct SimilarSuggestion: Identifiable, Sendable, Equatable {
    public var source: FileRef
    public var other: FileRef
    public var score: Double
    public var passage: String?
    public var id: String { BriefingHistory.pairKey(source.relativePath, other.relativePath) }
}

public struct IndexProblems: Sendable, Equatable {
    public var failed = 0
    public var partial = 0
    /// A few of the files, by path.
    public var samples: [String] = []
    public var total: Int { failed + partial }
}

/// Everything the briefing shows, as data. Built off the main thread from SQL, the trail and the
/// work folder; no graph is built.
public struct BriefingSnapshot: Sendable, Equatable {
    public var day: String
    public var generatedAt: Date
    /// Memos not yet opened, newest first.
    public var memos: [MemoCardData]
    /// Thoughts to address first, best first.
    public var address: [RankedThought]
    public var editedFiles: [EditedFileItem]
    /// Open thoughts in the inbox, newest first.
    public var looseCaptures: [ThoughtRecord]
    public var suggestions: [SimilarSuggestion]
    /// Drafts left behind by a crash, given by the shell (it owns `CaptureDraft`).
    public var recoveredDrafts: [String]
    public var problems: IndexProblems
    /// Yesterday's last session, to reopen.
    public var resume: [TrailLocation]
    /// How long building took.
    public var elapsed: TimeInterval

    public var isEmpty: Bool {
        memos.isEmpty && address.isEmpty && editedFiles.isEmpty && looseCaptures.isEmpty && suggestions.isEmpty
            && recoveredDrafts.isEmpty && problems.total == 0
    }

    /// A line for the QA log: `memos=1 address=7 attention=3`.
    public var summary: String {
        "memos=\(memos.count) address=\(address.count) attention=\(editedFiles.count + looseCaptures.count + suggestions.count + recoveredDrafts.count + (problems.total > 0 ? 1 : 0)) resume=\(resume.count)"
    }
}

public struct BriefingBuilder: Sendable {
    public let vault: Vault
    public let index: IndexStore
    public let trail: TrailStore
    public var calendar = Calendar.current
    public var ranker: AttentionRanker { AttentionRanker(limit: 12, calendar: calendar) }

    public init(vault: Vault, index: IndexStore, trail: TrailStore) {
        self.vault = vault; self.index = index; self.trail = trail
    }

    /// Call off the main thread. `history` is read, never written (the shell records what was shown).
    public func build(now: Date = Date(), history: BriefingHistory, recoveredDrafts: [String] = []) throws -> BriefingSnapshot {
        let began = Date()
        let events = (try? trail.events()) ?? []

        // Thoughts: open ones, and snoozed ones whose snooze has ended.
        var q = ThoughtQuery(states: [.open], order: .newest, limit: 1500)
        q.snoozeEndedBy = now
        let records = try index.thoughts(q)
        let roots = records.filter { $0.parent == nil && $0.origin == .human }

        // What models replied lately, by the thought they answer.
        var ai = ThoughtQuery(states: nil, order: .newest, limit: 600)
        ai.origin = .ai
        ai.createdAfter = now.addingTimeInterval(-14 * 86_400)
        let replies = (try? index.thoughts(ai)) ?? []

        let memos = unseenMemos(history: history)
        let memoUIDs = Set(memos.map(\.memo.thought))

        let files = Array(Set(roots.filter { !$0.file.isVirtual }.map(\.file)))
        let opened = lastOpened(in: events, of: Set(files))
        let degree = connectionDegree(of: files)
        var modifiedCache: [String: Date?] = [:]
        func modified(_ path: String) -> Date? {
            if let hit = modifiedCache[path] { return hit }
            let date = (try? FileManager.default.attributesOfItem(atPath: vault.url(for: FileRef(relativePath: path)).path))?[.modificationDate] as? Date
            modifiedCache[path] = date
            return date
        }

        var candidates: [(record: ThoughtRecord, signals: ThoughtSignals)] = []
        for r in roots {
            var s = ThoughtSignals()
            if let m = r.fileModified, m > r.comment.timestamp { s.editedAfter = true }
            if !s.editedAfter, let intent = r.comment.meta?.intent {
                for object in intent.objects.prefix(6) {
                    let path = object.split(separator: "#", maxSplits: 1).first.map(String.init) ?? object
                    if let m = modified(path), m > r.comment.timestamp { s.editedAfter = true; break }
                }
            }
            if let uid = r.uid {
                let mine = replies.filter { $0.parent == uid && $0.file == r.file }
                let unseen = mine.filter { $0.uid.map { !history.hasSeenReply($0) } ?? true }
                s.newAIReply = !unseen.isEmpty
                s.aiQuestionAwaiting = unseen.contains { $0.kind == .question }
                let memoWaiting = memoUIDs.contains(uid)
                s.memoReady = memoWaiting || unseen.contains { $0.comment.meta?.work != nil }
                s.awaitingUnseen = memoWaiting || !unseen.isEmpty
                s.timesSkipped = history.timesSkipped(uid, now: now, calendar: calendar)
            }
            if let o = opened[r.file], o > r.comment.timestamp, r.replies == 0 { s.openedWithoutReply = true }
            s.degree = degree[r.file.relativePath] ?? 0
            candidates.append((r, s))
        }
        let address = ranker.rank(candidates, now: now)

        return BriefingSnapshot(
            day: BriefingDay.key(now, calendar: calendar), generatedAt: now, memos: memos, address: address,
            editedFiles: editedFiles(roots, opened: opened),
            looseCaptures: Array(((try? looseCaptures()) ?? []).prefix(20)),
            suggestions: suggestions(roots, history: history),
            recoveredDrafts: recoveredDrafts, problems: problems(), resume: resume(now: now),
            elapsed: Date().timeIntervalSince(began))
    }

    // MARK: Memos

    /// Memos under `.flamingo/work` from the last two weeks that haven't been opened, newest first.
    func unseenMemos(history: BriefingHistory, limit: Int = 12) -> [MemoCardData] {
        let fm = FileManager.default
        guard let days = try? fm.contentsOfDirectory(atPath: vault.workDir.path) else { return [] }
        var out: [MemoCardData] = []
        for day in days.filter({ $0.count == 10 && $0.first?.isNumber == true }).sorted(by: >).prefix(14) {
            let dir = vault.workDir.appendingPathComponent(day)
            for name in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter({ $0.hasSuffix(".md") }).sorted() {
                let relative = "work/\(day)/\(name)"
                guard !history.hasSeenMemo(relative), let memo = WorkMemo.read(at: dir.appendingPathComponent(name)) else { continue }
                let thought = (try? index.thoughts({ var q = ThoughtQuery(states: nil, limit: 1); q.uid = memo.thought; return q }()))?.first
                out.append(MemoCardData(path: relative, memo: memo, tldr: Self.tldr(of: memo), thought: thought))
            }
        }
        out.sort { $0.memo.created != $1.memo.created ? $0.memo.created > $1.memo.created : $0.path < $1.path }
        return Array(out.prefix(limit))
    }

    static func tldr(of memo: WorkMemo) -> String {
        memo.body.split(separator: "\n", omittingEmptySubsequences: true).first { !$0.hasPrefix("#") }.map(String.init) ?? ""
    }

    // MARK: Attention

    private func lastOpened(in events: [TrailEvent], of files: Set<FileRef>) -> [FileRef: Date] {
        var out: [FileRef: Date] = [:]
        for e in events where e.kind == .opened {
            if let f = e.file, files.contains(f), out[f].map({ e.at > $0 }) ?? true { out[f] = e.at }
        }
        return out
    }

    /// Files joined to each file by thoughts that link them and by connections the person made.
    private func connectionDegree(of files: [FileRef]) -> [String: Int] {
        var out = (try? index.thoughtDegree(of: files.map(\.relativePath))) ?? [:]
        for c in (try? ConnectionStore(vault: vault).all()) ?? [] {
            out[c.source, default: 0] += 1
            out[c.target, default: 0] += 1
        }
        return out
    }

    func editedFiles(_ roots: [ThoughtRecord], opened: [FileRef: Date]) -> [EditedFileItem] {
        var newest: [FileRef: Date] = [:], count: [FileRef: Int] = [:], modified: [FileRef: Date] = [:]
        for r in roots {
            guard let m = r.fileModified, !r.file.isVirtual else { continue }
            newest[r.file] = max(newest[r.file] ?? .distantPast, r.comment.timestamp)
            count[r.file, default: 0] += 1
            modified[r.file] = m
        }
        return modified.compactMap { file, m -> EditedFileItem? in
            guard m > (newest[file] ?? .distantPast), m > (opened[file] ?? .distantPast) else { return nil }
            return EditedFileItem(file: file, modified: m, openThoughts: count[file] ?? 0)
        }.sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.file.relativePath < $1.file.relativePath }.prefix(8).map { $0 }
    }

    func looseCaptures() throws -> [ThoughtRecord] {
        var q = ThoughtQuery(states: [.open], order: .newest, limit: 200)
        q.folder = FileRef.inboxDirectory
        q.origin = .human
        q.isReply = false
        return try index.thoughts(q)
    }

    /// Unseen, undismissed similar files for the five files with the most thoughts.
    func suggestions(_ roots: [ThoughtRecord], history: BriefingHistory) -> [SimilarSuggestion] {
        var counts: [FileRef: Int] = [:]
        for r in roots where !r.file.isVirtual { counts[r.file, default: 0] += 1 }
        let top = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.relativePath < $1.key.relativePath }.prefix(5).map(\.key)
        guard !top.isEmpty else { return [] }
        let dismissed = DismissedConnectionStore(vault: vault).keys()
        let connected = Set(((try? ConnectionStore(vault: vault).all()) ?? []).map { DismissedConnection.key($0.source, $0.target) })
        var out: [SimilarSuggestion] = []
        for file in top {
            for similar in (try? index.similarFiles(to: file, limit: 3)) ?? [] {
                let key = DismissedConnection.key(file.relativePath, similar.file.relativePath)
                guard !dismissed.contains(key), !connected.contains(key),
                      !history.hasSeenPair(file.relativePath, similar.file.relativePath),
                      !out.contains(where: { $0.id == BriefingHistory.pairKey(file.relativePath, similar.file.relativePath) }) else { continue }
                out.append(SimilarSuggestion(source: file, other: similar.file, score: similar.score, passage: similar.passage))
            }
        }
        return Array(out.sorted { $0.score > $1.score }.prefix(6))
    }

    func problems() -> IndexProblems {
        guard let h = try? index.health(), h.failed + h.partial > 0 else { return IndexProblems() }
        let samples = ((try? index.incompleteFiles(limit: 5)) ?? []).map(\.file.relativePath)
        return IndexProblems(failed: h.failed, partial: h.partial, samples: samples)
    }

    /// The last session that ended before this briefing day began: where to pick up.
    func resume(now: Date) -> [TrailLocation] {
        let boundary = BriefingDay.begin(of: now, calendar: calendar)
        guard let sessions = try? trail.sessions(), let last = sessions.last(where: { $0.end < boundary }) else { return [] }
        return Array(last.locationsToReopen.filter { vault.exists($0.file) }.prefix(6))
    }
}
