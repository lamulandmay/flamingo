import Foundation
import SwiftUI
import FlamingoCore
import FlamingoThoughts

// Pure pieces and small models for thoughts v2 in the shell. The logic that needs the open
// vault is in AppState+Thoughts.swift. Privacy: nothing here reads a thought for a model; the
// callers only ever use the local-only entry points (`completeLocally`, `askStreamingLocally`,
// `ThoughtReader`, `engine.work`, `NightShiftService`).

/// `[[q3-model.xlsx#^t3k9x2m4q]]`: a link to one thought in a file's note.
enum ThoughtLink {
    /// The link text the rail copies and `openLink` understands.
    static func make(file: FileRef, uid: String) -> String { "[[" + file.relativePath + "#^" + uid + "]]" }

    /// The file part (may be empty: a link inside the same note) and the thought's uid, for a
    /// link whose anchor is `^uid`. Any other link gives nil.
    static func parse(_ raw: String) -> (target: String, uid: String)? {
        let parts = Wikilink.components(of: raw)
        guard let anchor = parts.anchor, anchor.hasPrefix("^") else { return nil }
        let uid = String(anchor.dropFirst()).trimmingCharacters(in: .whitespaces)
        guard !uid.isEmpty, uid.count <= 24, uid.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return (parts.target, uid)
    }
}

/// When a saved thought sets something in motion.
enum ThoughtTriggers {
    /// A thought the person wrote that addresses the assistant (`@ai` or `@flamingo`).
    static func asksAssistant(_ c: Comment) -> Bool {
        c.provenance?.origin != .ai && ThoughtRules.read(c.text, at: c.timestamp).mentionsAssistant
    }

    /// The question: the thought's words minus the mention.
    static func question(of c: Comment) -> String { ThoughtRules.prose(of: c.text) }

    /// Whether the understanding pass should read this thought a moment after it is saved.
    /// Not a model's reply, not a question for the assistant (the answer is its action), not empty.
    static func shouldUnderstand(_ c: Comment) -> Bool {
        c.provenance?.origin != .ai && !asksAssistant(c) && !ThoughtRules.prose(of: c.text).isEmpty
    }
}

/// How many thoughts the idle backfill may read per day.
struct DailyBudget: Equatable {
    var day: String
    var used: Int
    let limit: Int

    init(day: String = "", used: Int = 0, limit: Int = 50) { self.day = day; self.used = used; self.limit = limit }

    static func key(_ date: Date, calendar: Calendar = .current) -> String {
        ThoughtDates.string(from: date, hasTime: false, calendar: calendar)
    }

    /// Takes one from today's budget; false when it is spent. A new day starts at zero.
    mutating func take(on date: Date, calendar: Calendar = .current) -> Bool {
        let today = Self.key(date, calendar: calendar)
        if day != today { day = today; used = 0 }
        guard used < limit else { return false }
        used += 1
        return true
    }

    func remaining(on date: Date, calendar: Calendar = .current) -> Int {
        day == Self.key(date, calendar: calendar) ? max(0, limit - used) : limit
    }
}

/// What `thoughts: ...` lines say; one place so QA greps stay stable.
enum ThoughtLog {
    static func saved(_ uid: String?, file: FileRef) { Log.debug("thoughts: saved uid=\(uid ?? "-") file=\(file.relativePath)") }
}

/// The answers still being written and the work still running, by the uid of the thought they
/// are for. Kept apart from `AppState` so a streamed token redraws only the Thoughts tab.
@MainActor
final class ThoughtJobsModel: ObservableObject {
    /// The streaming text of an `@ai` answer (empty while a work job runs), by thought uid.
    @Published private(set) var pending: [String: String] = [:]
    /// Bumped when a note that is not the open file's changes (a folder's), so its tab reloads.
    @Published private(set) var noteRevision = 0
    private var tasks: [String: Task<Void, Never>] = [:]

    func isRunning(_ uid: String) -> Bool { tasks[uid] != nil }

    /// Starts `body` as the job for `uid`, unless one is already running for it.
    @discardableResult
    func begin(_ uid: String, _ body: @escaping @MainActor () async -> Void) -> Bool {
        guard tasks[uid] == nil else { return false }
        pending[uid] = ""
        tasks[uid] = Task { [weak self] in
            await body()
            self?.finish(uid)
        }
        return true
    }

    func set(_ uid: String, text: String) { if pending[uid] != nil, pending[uid] != text { pending[uid] = text } }

    func cancel(_ uid: String) { tasks[uid]?.cancel() }

    func cancelAll() { tasks.values.forEach { $0.cancel() } }

    func bumpNote() { noteRevision &+= 1 }

    private func finish(_ uid: String) {
        tasks[uid] = nil
        pending[uid] = nil
    }
}

/// A clock QA can set (`clock <ISO>`), read from any thread. Nil means the real time.
enum QAClock {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var value: Date?

    static var override: Date? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    /// `2026-10-17T02:00` or `2026-10-17 02:00`, local time; also with seconds or a date alone.
    static func parse(_ text: String, calendar: Calendar = .current) -> Date? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "T", with: " ")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = calendar; f.timeZone = calendar.timeZone
            f.dateFormat = format
            if let d = f.date(from: t) { return d }
        }
        return nil
    }
}

/// Lets QA run the night shift whatever the window, power and idle time say.
enum QAGate {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var open = false
    static var isOpen: Bool {
        get { lock.withLock { open } }
        set { lock.withLock { open = newValue } }
    }
}

/// Everything thoughts v2 keeps for the open vault that is not view state.
@MainActor
final class ThoughtsRuntime {
    let jobs = ThoughtJobsModel()
    var service: NightShiftService?
    var scheduler: NightShiftScheduler?
    var understanding: [String: Task<Void, Never>] = [:]
    var backfill: Task<Void, Never>?
    var backfillTried = Set<String>()
    /// Thoughts already shown by Resurface, so asking again brings another.
    var resurfaced = Set<String>()
    /// The service as the scheduler reads it, from any thread.
    let box = ServiceBox()

    func stop() {
        scheduler?.stop()
        scheduler = nil
        service = nil
        box.set(nil)
        understanding.values.forEach { $0.cancel() }
        understanding = [:]
        backfill?.cancel(); backfill = nil
        backfillTried = []
        resurfaced = []
        jobs.cancelAll()
    }
}

final class ServiceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: NightShiftService?
    func set(_ service: NightShiftService?) { lock.withLock { value = service } }
    func get() -> NightShiftService? { lock.withLock { value } }
}

/// With `FLAMINGO_DEBUG` and `FLAMINGO_QA_STREAM_DELAY=<seconds>`, a canned answer is shown word
/// by word, so QA can catch the pending row. Off otherwise.
enum QAPace {
    static let wordDelay: TimeInterval? = {
        guard Log.enabled, let text = ProcessInfo.processInfo.environment["FLAMINGO_QA_STREAM_DELAY"], let d = Double(text), d > 0 else { return nil }
        return d
    }()
}
