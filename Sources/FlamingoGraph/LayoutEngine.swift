import Foundation
import CoreGraphics

/// Snapshot published by the engine for the main thread.
struct LayoutSnapshot: Sendable {
    var positions: [CGPoint]
    var alpha: Double
    /// False once settled and the worker has stopped (or before `start`, or after `stop`).
    var isRunning: Bool
    /// Increments every time new positions are published (ticks, settles, drags).
    var generation: Int
}

/// Runs a `ForceSimulation` on a background thread and publishes snapshots. Thread-safe;
/// every method may be called from the main thread.
///
/// The worker owns the simulation and never holds the snapshot lock during a tick: it ticks on
/// its own buffers, then publishes under the lock. Requests from the main thread (drag, pin,
/// reheat) are queued and applied at the start of the next tick; drags also patch the
/// published snapshot immediately so the node follows the pointer with no lag.
///
/// The worker thread retains only an internal core, never the engine, so dropping the last
/// reference to the engine stops the worker (see `deinit`).
final class LayoutEngine: @unchecked Sendable {
    private let core: LayoutWorkerCore

    /// - Parameters:
    ///   - alpha: starting temperature. Below `parameters.alphaMin` the engine starts settled
    ///     and `start()` does nothing until something reheats it.
    ///   - maxTicksPerSecond: pacing ceiling so small graphs bloom visibly instead of snapping.
    ///     0 or less runs flat out.
    init(topology: GraphTopology, positions: [CGPoint], pinned: Set<Int>, alpha: Double,
         parameters: ForceSimulation.Parameters = ForceSimulation.Parameters(),
         maxTicksPerSecond: Double = 120) {
        let sim = ForceSimulation(topology: topology, positions: positions, pinned: pinned, parameters: parameters)
        sim.alpha = alpha.isFinite ? max(0, alpha) : 1
        core = LayoutWorkerCore(sim: sim, pinned: sim.fixed,
                                interval: maxTicksPerSecond > 0 ? 1 / maxTicksPerSecond : 0)
    }

    deinit { core.stop() }

    /// Idempotent. If alpha < alphaMin and nothing is dragging or queued, does nothing.
    func start() { core.start() }
    /// Stops ticking promptly. Never blocks on the worker. Safe to call repeatedly and from
    /// the owner's deinit. `start()` resumes from where it stopped.
    func stop() { core.stop() }
    /// Cheap, lock-protected copy. Call it every display frame.
    func snapshot() -> LayoutSnapshot { core.snapshot() }
    var pinned: Set<Int> { core.pinnedNodes }

    /// d3 drag start: pins `i` at its current (published) position, alphaTarget 0.3, restarts.
    func beginDrag(_ i: Int) { core.beginDrag(i) }
    /// Moves the pinned node. Visible in the very next `snapshot()`.
    func drag(_ i: Int, to p: CGPoint) { core.drag(i, to: p) }
    /// alphaTarget back to 0 once no drag is active. The node stays pinned.
    func endDrag(_ i: Int) { core.endDrag(i) }
    /// Releases `i` and reheats to at least 0.1 so its neighbors relax.
    func unpin(_ i: Int) { core.unpin(i) }
    /// alpha = max(current, alpha); restarts.
    func reheat(_ alpha: Double) { core.reheat(alpha) }

    /// Called on the worker thread each time the simulation settles and the worker stops (not
    /// after `stop()`). Capture the owner weakly: the engine holds this closure.
    var onSettle: (@Sendable (_ positions: [CGPoint], _ pinned: Set<Int>) -> Void)? {
        get { core.settleHandler }
        set { core.settleHandler = newValue }
    }

    /// Worker threads currently alive across all engines. For tests.
    static var liveWorkerCount: Int { LayoutWorkerCore.liveWorkers.value }
}

/// Everything the worker thread needs, so the thread never retains the `LayoutEngine`.
private final class LayoutWorkerCore: @unchecked Sendable {
    enum Request {
        case fix(Int, CGPoint)
        case release(Int)
        case alphaTarget(Double)
        case reheat(Double)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func add(_ d: Int) { lock.lock(); count += d; lock.unlock() }
    }
    static let liveWorkers = Counter()

    // Guarded by `cond`.
    private let cond = NSCondition()
    private var published: LayoutSnapshot
    private var pinned: Set<Int>
    private var requests: [Request] = []
    /// Positions requested by drags the worker has not applied yet; laid over every publish.
    private var overrides: [Int: CGPoint] = [:]
    private var dragging: Set<Int> = []
    /// A worker exists and has not been told to stop.
    private var active = false
    /// Bumped by `start` and `stop`; a worker whose epoch is stale exits.
    private var epoch = 0
    private var onSettle: (@Sendable ([CGPoint], Set<Int>) -> Void)?

    // Owned by whichever worker holds `simLock`. Only workers take it, so the main thread
    // never waits on a tick.
    private let sim: ForceSimulation
    private let simLock = NSLock()
    private let interval: Double
    private let alphaMin: Double
    private let count: Int

    init(sim: ForceSimulation, pinned: Set<Int>, interval: Double) {
        self.sim = sim
        self.pinned = pinned
        self.interval = interval
        alphaMin = sim.alphaMin
        count = sim.count
        published = LayoutSnapshot(positions: sim.positions, alpha: sim.alpha, isRunning: false, generation: 0)
    }

    var settleHandler: (@Sendable ([CGPoint], Set<Int>) -> Void)? {
        get { cond.lock(); defer { cond.unlock() }; return onSettle }
        set { cond.lock(); onSettle = newValue; cond.unlock() }
    }

    var pinnedNodes: Set<Int> {
        cond.lock(); defer { cond.unlock() }
        return pinned
    }

    func snapshot() -> LayoutSnapshot {
        cond.lock(); defer { cond.unlock() }
        return published
    }

    // MARK: Main-thread requests

    func start() {
        cond.lock()
        guard !active else { cond.unlock(); return }
        if requests.isEmpty && dragging.isEmpty && published.alpha < alphaMin {
            cond.unlock()
            return
        }
        active = true
        epoch &+= 1
        let mine = epoch
        published.isRunning = true
        cond.unlock()

        let thread = Thread { [self] in
            Self.liveWorkers.add(1)
            run(epoch: mine)
            Self.liveWorkers.add(-1)
        }
        thread.name = "Flamingo.GraphLayout"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop() {
        cond.lock()
        if active {
            active = false
            epoch &+= 1
            published.isRunning = false
        }
        cond.broadcast()
        cond.unlock()
    }

    func beginDrag(_ i: Int) {
        cond.lock()
        guard i >= 0, i < count else { cond.unlock(); return }
        let p = published.positions[i]
        pinned.insert(i)
        dragging.insert(i)
        overrides[i] = p
        requests.append(.fix(i, p))
        requests.append(.alphaTarget(0.3))
        cond.unlock()
        start()
    }

    func drag(_ i: Int, to p: CGPoint) {
        guard p.x.isFinite, p.y.isFinite else { return }
        cond.lock()
        guard i >= 0, i < count else { cond.unlock(); return }
        published.positions[i] = p
        published.generation += 1
        pinned.insert(i)
        overrides[i] = p
        if case .fix(let j, _)? = requests.last, j == i {
            requests[requests.count - 1] = .fix(i, p)
        } else {
            requests.append(.fix(i, p))
        }
        cond.unlock()
        start()
    }

    func endDrag(_ i: Int) {
        cond.lock()
        guard dragging.remove(i) != nil else { cond.unlock(); return }
        if dragging.isEmpty { requests.append(.alphaTarget(0)) }
        cond.unlock()
    }

    func unpin(_ i: Int) {
        cond.lock()
        guard i >= 0, i < count else { cond.unlock(); return }
        pinned.remove(i)
        overrides.removeValue(forKey: i)
        if dragging.remove(i) != nil, dragging.isEmpty { requests.append(.alphaTarget(0)) }
        requests.append(.release(i))
        requests.append(.reheat(0.1))
        cond.unlock()
        start()
    }

    func reheat(_ alpha: Double) {
        guard alpha.isFinite else { return }
        cond.lock()
        requests.append(.reheat(alpha))
        cond.unlock()
        start()
    }

    // MARK: Worker

    private func run(epoch mine: Int) {
        simLock.lock()
        defer { simLock.unlock() }
        // Absolute schedule, so wake-up latency does not accumulate into a slower bloom.
        var nextTick = ProcessInfo.processInfo.systemUptime
        while true {
            cond.lock()
            guard epoch == mine else { cond.unlock(); return }
            let batch = requests
            requests.removeAll(keepingCapacity: true)
            overrides.removeAll(keepingCapacity: true)
            cond.unlock()

            for request in batch {
                switch request {
                case let .fix(i, p): sim.setFixed(i, at: p)
                case let .release(i): sim.setFixed(i, at: nil)
                case let .alphaTarget(t): sim.alphaTarget = t
                case let .reheat(a): sim.alpha = max(sim.alpha, a)
                }
            }

            if sim.isSettled {
                let positions = sim.positions
                cond.lock()
                guard epoch == mine else { cond.unlock(); return }
                if !requests.isEmpty { cond.unlock(); continue }
                active = false
                published.positions = positions
                published.alpha = sim.alpha
                published.isRunning = false
                published.generation += 1
                let handler = onSettle, pins = pinned
                cond.unlock()
                handler?(positions, pins)
                return
            }

            sim.tick()
            var positions = sim.positions
            let alpha = sim.alpha

            cond.lock()
            guard epoch == mine else { cond.unlock(); return }
            for (i, p) in overrides { positions[i] = p }
            published.positions = positions
            published.alpha = alpha
            published.generation += 1
            if interval > 0 {
                nextTick += interval
                var now = ProcessInfo.processInfo.systemUptime
                // Ticks slower than the pace: run flat out, and never burst to catch up.
                if nextTick < now { nextTick = now }
                while epoch == mine && now < nextTick {
                    _ = cond.wait(until: Date(timeIntervalSinceNow: nextTick - now))
                    now = ProcessInfo.processInfo.systemUptime
                }
            }
            cond.unlock()
        }
    }
}
