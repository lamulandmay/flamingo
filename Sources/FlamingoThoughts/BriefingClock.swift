import Foundation

/// How the app came to the front.
public enum ActivationSource: Sendable, Equatable {
    /// A click, ⌘-Tab, the Dock.
    case user
    /// The system opened a file in Flamingo. The briefing waits for a later activation.
    case openFileRequest
    /// The global palette brought the app up.
    case globalPalette
}

public enum BriefingEvent: Sendable, Equatable {
    /// After the vault was restored and its first comments loaded.
    case launch
    case activation(ActivationSource)
    /// The Mac woke from sleep.
    case wake
}

/// What is true about the app right now, supplied by the shell.
public struct BriefingConditions: Sendable, Equatable {
    /// A sheet or the capture panel is up.
    public var sheetOrPanelUp = false
    /// Nothing to show: no memos, no thoughts to address, nothing needing attention.
    public var nothingToShow = false
    public var underTest = false
    /// The "Morning Inbox" toggle.
    public var autoOpenEnabled = true
    /// Launch only: the vault is restored and the first comments have loaded.
    public var contentReady = true
    /// Launch only: the app was started by opening a file.
    public var launchedByFileRequest = false
    /// Wake only: Flamingo is already the active app.
    public var appIsActive = false

    public init() {}
}

public enum BriefingSkip: Sendable, Equatable {
    case alreadyShownToday
    case disabled
    case underTest
    /// Launch before the comments loaded; ask again when they have.
    case notReady
    /// A file opened the app; the day stays pending for the next activation.
    case openFileRequest
    case globalPalette
    /// A sheet or the capture panel is up.
    case blocked
    case nothingToShow
    /// The Mac woke while Flamingo was in the background: the next activation is the trigger.
    case waitingForActivation
}

public enum BriefingDecision: Sendable, Equatable {
    case show(day: String)
    case skip(BriefingSkip)
}

/// When the morning briefing opens: the first time each briefing day (which starts at 04:00)
/// that the app launches, comes to the front, or comes to the front after a wake, unless
/// something is in the way. Pure value: the shell persists `lastShownDay`
/// (`Defaults.lastBriefingDay`) and feeds in events and conditions.
public struct BriefingClock: Sendable, Equatable {
    public var calendar: Calendar
    /// `yyyy-MM-dd` of the last briefing day that was shown.
    public var lastShownDay: String?
    /// The day an open-file request put off. It is shown at the next ordinary activation.
    public private(set) var pendingDay: String?
    private var wokeSinceActivation = false

    public init(calendar: Calendar = .current, lastShownDay: String? = nil) {
        self.calendar = calendar; self.lastShownDay = lastShownDay
    }

    public func day(_ now: Date) -> String { BriefingDay.key(now, calendar: calendar) }

    /// Decides for one event. Call `didShow` when the briefing is actually put up.
    public mutating func evaluate(_ event: BriefingEvent, now: Date, conditions: BriefingConditions = BriefingConditions()) -> BriefingDecision {
        let today = day(now)
        if conditions.underTest { return .skip(.underTest) }
        if !conditions.autoOpenEnabled { return .skip(.disabled) }
        if lastShownDay == today { pendingDay = nil; return .skip(.alreadyShownToday) }

        switch event {
        case .wake:
            wokeSinceActivation = true
            guard conditions.appIsActive else { return .skip(.waitingForActivation) }
        case .activation(let source):
            wokeSinceActivation = false
            switch source {
            case .openFileRequest: pendingDay = today; return .skip(.openFileRequest)
            case .globalPalette: return .skip(.globalPalette)
            case .user: break
            }
        case .launch:
            if conditions.launchedByFileRequest { pendingDay = today; return .skip(.openFileRequest) }
            if !conditions.contentReady { return .skip(.notReady) }
        }
        if conditions.sheetOrPanelUp { return .skip(.blocked) }
        if conditions.nothingToShow { return .skip(.nothingToShow) }
        return .show(day: today)
    }

    /// The briefing went up: this day is done.
    public mutating func didShow(at now: Date) {
        lastShownDay = day(now)
        pendingDay = nil
    }
}
