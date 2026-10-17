import Foundation
import IOKit.pwr_mgt
import FlamingoAsk

/// Wakes every half hour and asks the night shift whether it may work. The app creates one,
/// calls `start()` when a vault opens and `stop()` when it closes.
///
/// While work is under way it holds a power assertion against idle sleep and tells the system
/// it is doing background work; the assertion is released when the batch ends. It cannot wake
/// a sleeping Mac, which is why the first open of the day catches up (`NightShiftService.catchUp`).
public final class NightShiftScheduler: @unchecked Sendable {
    public static let identifier = "com.flamingo.nightshift"

    private let serviceProvider: @Sendable () -> NightShiftService?
    private let power: @Sendable () -> PowerSnapshot
    private let idle: @Sendable () -> TimeInterval
    private let onEvent: @Sendable (NightShiftEvent) -> Void
    private let onOutcome: @Sendable (NightShiftOutcome) -> Void
    private let lock = NSLock()
    private var activity: NSBackgroundActivityScheduler?
    private var working = false

    /// - Parameters:
    ///   - service: the night shift of the open vault, nil when none is open.
    ///   - onOutcome: told after every tick that did or declined something, for the log and QA.
    public init(service: @escaping @Sendable () -> NightShiftService?,
                power: @escaping @Sendable () -> PowerSnapshot = { PowerSnapshot.current() },
                idle: @escaping @Sendable () -> TimeInterval = { UserIdle.seconds() },
                onEvent: @escaping @Sendable (NightShiftEvent) -> Void = { _ in },
                onOutcome: @escaping @Sendable (NightShiftOutcome) -> Void = { _ in }) {
        self.serviceProvider = service; self.power = power; self.idle = idle; self.onEvent = onEvent; self.onOutcome = onOutcome
    }

    public var isRunning: Bool { lock.withLock { activity != nil } }
    public var isWorking: Bool { lock.withLock { working } }

    public func start() {
        lock.withLock {
            guard activity == nil else { return }
            let scheduler = NSBackgroundActivityScheduler(identifier: Self.identifier)
            scheduler.repeats = true
            scheduler.interval = 30 * 60
            scheduler.tolerance = 10 * 60
            scheduler.qualityOfService = .utility
            scheduler.schedule { [weak self, weak scheduler] completion in
                guard let self, let scheduler else { return completion(.finished) }
                if scheduler.shouldDefer { return completion(.deferred) }
                let ask = Deferral(scheduler)
                Task.detached(priority: .utility) {
                    _ = await self.tick(shouldDefer: { ask.shouldDefer })
                    completion(.finished)
                }
            }
            activity = scheduler
        }
    }

    public func stop() {
        lock.withLock {
            activity?.invalidate()
            activity = nil
        }
    }

    /// One tick, also what "nightshift now" in the QA hook calls. Returns what happened.
    @discardableResult
    public func tick(shouldDefer: @escaping @Sendable () -> Bool = { false }) async -> NightShiftOutcome? {
        guard let service = serviceProvider() else { return nil }
        let begin = lock.withLock { () -> Bool in
            if working { return false }
            working = true
            return true
        }
        guard begin else { return nil }
        defer { lock.withLock { working = false } }

        let wasRunning = LlamaServer.shared.isRunning
        let startedAt = Date()
        let power = self.power, idle = self.idle, settings = service.settings
        let outcome = await Self.whileAwake {
            await service.runTonight(power: power(), idleSeconds: idle(), shouldContinue: {
                // The person came back, the cable came out, or the system asked us to stop.
                let p = power()
                return !shouldDefer() && p.onAC && !p.lowPowerMode && !p.isHot && idle() >= settings.minimumIdle
            }, onEvent: onEvent)
        }
        // A server the night shift started for itself goes away with it, unless Ask used it since.
        if !wasRunning, LlamaServer.shared.isRunning, !(LlamaServer.shared.lastInteractiveUse.map { $0 >= startedAt } ?? false) {
            LlamaServer.shared.stop()
        }
        onOutcome(outcome)
        return outcome
    }

    /// Runs `body` with the Mac kept from sleeping on its own and the system told it is background work.
    static func whileAwake<T>(_ body: () async -> T) async -> T {
        let token = ProcessInfo.processInfo.beginActivity(options: [.background, .idleSystemSleepDisabled], reason: "Flamingo night shift")
        var assertion = IOPMAssertionID(0)
        let created = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                  IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                  "Flamingo night shift" as CFString, &assertion) == kIOReturnSuccess
        defer {
            if created { IOPMAssertionRelease(assertion) }
            ProcessInfo.processInfo.endActivity(token)
        }
        return await body()
    }
}

/// `NSBackgroundActivityScheduler.shouldDefer` is safe to read from any thread.
private final class Deferral: @unchecked Sendable {
    let scheduler: NSBackgroundActivityScheduler
    init(_ scheduler: NSBackgroundActivityScheduler) { self.scheduler = scheduler }
    var shouldDefer: Bool { scheduler.shouldDefer }
}
