import Foundation

public struct NightShiftSettings: Sendable, Equatable {
    /// The palette's Pause/Resume. On by default.
    public var enabled = true
    /// Local hours: the window runs from `startHour` to `endHour` the next morning.
    public var startHour = 22
    public var endHour = 6
    /// How long the Mac must have been left alone.
    public var minimumIdle: TimeInterval = 15 * 60
    /// The least battery a catch-up on battery may start with.
    public var catchUpMinimumBattery = 50

    public init() {}
}

/// What a batch of night work may spend.
public struct NightBudget: Sendable, Equatable {
    public var jobs: Int
    public var wallSeconds: TimeInterval
    public var tokens: Int
    public var perJobSeconds: TimeInterval

    public init(jobs: Int, wallSeconds: TimeInterval, tokens: Int, perJobSeconds: TimeInterval) {
        self.jobs = jobs; self.wallSeconds = wallSeconds; self.tokens = tokens; self.perJobSeconds = perJobSeconds
    }

    /// Six jobs, 45 minutes, 150k local tokens, 8 minutes a job.
    public static let night = NightBudget(jobs: 6, wallSeconds: 45 * 60, tokens: 150_000, perJobSeconds: 8 * 60)
    /// The first open of the day after a missed night: three jobs, 12 minutes.
    public static let catchUp = NightBudget(jobs: 3, wallSeconds: 12 * 60, tokens: 150_000, perJobSeconds: 8 * 60)
    /// "Work on open thoughts now": a few jobs while the person waits.
    public static let now = NightBudget(jobs: 3, wallSeconds: 12 * 60, tokens: 150_000, perJobSeconds: 8 * 60)

    /// The smaller of each limit.
    public func capped(by other: NightBudget) -> NightBudget {
        NightBudget(jobs: min(jobs, other.jobs), wallSeconds: min(wallSeconds, other.wallSeconds),
                    tokens: min(tokens, other.tokens), perJobSeconds: min(perJobSeconds, other.perJobSeconds))
    }
}

/// A hook for a compute budget kept elsewhere (plan 13's `ComputeBudget`): ask it before
/// working. It need not be merged for this to build; nothing is set by default.
public enum BudgetOverride: Sendable, Equatable {
    /// Not now.
    case deny
    /// Work, but no more than this.
    case cap(NightBudget)
}

/// What the ledger says about earlier nights, which is all the gate needs to know of it.
public struct NightHistory: Sendable, Equatable {
    /// Night ids (`yyyy-MM-dd`, the date the window opened) that ran to the end of their work.
    public var endedNights: Set<String> = []
    /// Briefing days (`yyyy-MM-dd`) that already had a catch-up.
    public var catchUpDays: Set<String> = []
    public init(endedNights: Set<String> = [], catchUpDays: Set<String> = []) {
        self.endedNights = endedNights; self.catchUpDays = catchUpDays
    }
}

public enum GateSkip: Sendable, Equatable {
    case disabled
    case alreadyRanTonight
    case onBattery
    case lowPowerMode
    case thermal
    case notIdle(seconds: TimeInterval)
    case budgetDenied
    /// Catch-up only.
    case windowOpen
    case lastNightDidNotMiss
    case alreadyCaughtUp
    case nothingToDo
}

public enum GateDecision: Sendable, Equatable {
    case run(NightBudget)
    /// Outside the window: try again at this time.
    case wait(until: Date)
    case skip(GateSkip)
}

/// Whether night work may start. Pure: the clock, the power state and the idle time come in
/// as values, so every combination is a test.
public struct NightShiftGate: Sendable {
    public var settings: NightShiftSettings
    public var calendar: Calendar

    public init(settings: NightShiftSettings = NightShiftSettings(), calendar: Calendar = .current) {
        self.settings = settings; self.calendar = calendar
    }

    // MARK: The window

    /// The night `now` belongs to, named by the date the window opened (`2026-10-16` for 02:00
    /// on the 17th), or nil outside the window.
    public func nightID(at now: Date) -> String? {
        let hour = calendar.component(.hour, from: now)
        let s = settings
        if s.startHour > s.endHour {
            if hour >= s.startHour { return Self.dayString(now, calendar) }
            if hour < s.endHour { return Self.dayString(calendar.date(byAdding: .day, value: -1, to: now) ?? now, calendar) }
            return nil
        }
        return hour >= s.startHour && hour < s.endHour ? Self.dayString(now, calendar) : nil
    }

    /// When the window next opens, strictly after `now`.
    public func nextWindowStart(after now: Date) -> Date {
        calendar.nextDate(after: now, matching: DateComponents(hour: settings.startHour, minute: 0), matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(3600)
    }

    /// The night whose window most recently opened at or before `now` (the one in progress, or
    /// the last one to have ended).
    public func latestNightID(at now: Date) -> String {
        let start = calendar.nextDate(after: now, matching: DateComponents(hour: settings.startHour, minute: 0),
                                      matchingPolicy: .previousTimePreservingSmallerComponents, direction: .backward)
        return Self.dayString(start ?? now, calendar)
    }

    static func dayString(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: Decisions

    /// A normal night: in the window, plugged in, cool, full power, the Mac left alone, and not
    /// already done tonight.
    public func decide(now: Date, power: PowerSnapshot, idleSeconds: TimeInterval, history: NightHistory,
                       budgetOverride: (@Sendable () -> BudgetOverride?)? = nil) -> GateDecision {
        guard settings.enabled else { return .skip(.disabled) }
        guard let night = nightID(at: now) else { return .wait(until: nextWindowStart(after: now)) }
        if history.endedNights.contains(night) { return .skip(.alreadyRanTonight) }
        if !power.onAC { return .skip(.onBattery) }
        if power.lowPowerMode { return .skip(.lowPowerMode) }
        if power.isHot { return .skip(.thermal) }
        if idleSeconds < settings.minimumIdle { return .skip(.notIdle(seconds: settings.minimumIdle - idleSeconds)) }
        return applying(budgetOverride, to: .night)
    }

    /// The first open of the day after a night that didn't run: up to three jobs in 12 minutes,
    /// on AC or on a battery of at least 50% outside Low Power Mode. `candidates` is how many
    /// jobs the planner has.
    public func decideCatchUp(now: Date, power: PowerSnapshot, history: NightHistory, candidates: Int,
                              budgetOverride: (@Sendable () -> BudgetOverride?)? = nil) -> GateDecision {
        guard settings.enabled else { return .skip(.disabled) }
        if nightID(at: now) != nil { return .skip(.windowOpen) }
        if history.endedNights.contains(latestNightID(at: now)) { return .skip(.lastNightDidNotMiss) }
        if history.catchUpDays.contains(BriefingDay.key(now, calendar: calendar)) { return .skip(.alreadyCaughtUp) }
        guard candidates > 0 else { return .skip(.nothingToDo) }
        if power.lowPowerMode { return .skip(.lowPowerMode) }
        if power.isHot { return .skip(.thermal) }
        if !power.onAC, (power.batteryPercent ?? 0) < settings.catchUpMinimumBattery { return .skip(.onBattery) }
        return applying(budgetOverride, to: .catchUp)
    }

    private func applying(_ override: (@Sendable () -> BudgetOverride?)?, to budget: NightBudget) -> GateDecision {
        switch override?() {
        case .deny: return .skip(.budgetDenied)
        case .cap(let cap): return .run(budget.capped(by: cap))
        case nil: return .run(budget)
        }
    }
}
