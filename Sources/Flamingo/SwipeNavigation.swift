import AppKit
import SwiftUI
import FlamingoDesign

// MARK: - Deciding to swipe

/// Whether a two-finger sideways scroll becomes a back or forward swipe, decided the way
/// Safari decides (WebKit's pending swipe tracker), as a value so it can be tested without a
/// trackpad. A gesture whose first movement is sideways is held back while it travels a few
/// points, then becomes a swipe; one that starts or turns vertical is left to scroll. A
/// sideways scroller under the pointer keeps the gesture unless it already rests at the edge
/// the swipe would pull it past. Momentum never starts a swipe.
struct SwipeGate: Equatable {
    enum Phase: Equatable {
        case none, mayBegin, began, changed, ended, cancelled

        init(_ phase: NSEvent.Phase) {
            if phase.contains(.mayBegin) { self = .mayBegin }
            else if phase.contains(.began) { self = .began }
            else if phase.contains(.ended) { self = .ended }
            else if phase.contains(.cancelled) { self = .cancelled }
            else if phase.contains(.changed) || phase.contains(.stationary) { self = .changed }
            else { self = .none }
        }
    }

    /// One scroll-wheel event, as far as swiping cares.
    struct Event {
        var phase: Phase
        var momentum = false
        /// `scrollingDeltaX`: positive while the fingers move right, which goes back.
        var dx: CGFloat
        var dy: CGFloat
        var precise = true
    }

    /// What allows a sideways gesture to become a swipe. Read once its direction is known.
    struct Context: Equatable {
        var canBack: Bool
        var canForward: Bool
        /// Over a view that pans with two fingers itself (the graph).
        var pans = false
        /// The innermost sideways scroller under the pointer rests at its left / right edge.
        /// True when there is none.
        var pinnedLeft = true
        var pinnedRight = true
    }

    enum Decision: Equatable {
        /// Leave the event to the views; the reason is for the log.
        case pass(String)
        /// Keep it from the views while deciding.
        case hold
        /// Track a swipe from this event.
        case start(back: Bool)
    }

    enum State: Equatable {
        case idle
        /// The gesture began without moving; the next movement decides.
        case undecided(CGSize)
        /// Sideways so far, held back until it has travelled `distance`.
        case holding(back: Bool, CGSize)
        /// A scroll, not a swipe, until the fingers lift.
        case scrolling
    }

    /// Sideways travel, in points, before a held gesture becomes a swipe (WebKit uses 15).
    static let distance: CGFloat = 12
    /// A held gesture becomes a scroll once its vertical travel reaches this share of its
    /// sideways travel (WebKit's ratio).
    static let verticalRatio: CGFloat = 0.5

    private(set) var state: State = .idle

    mutating func reset() { state = .idle }

    mutating func decide(_ e: Event, context: () -> Context) -> Decision {
        if e.momentum { return .pass("momentum") }
        let delta = CGSize(width: e.dx, height: e.dy)
        switch e.phase {
        case .none:
            state = .idle
            return .pass("not a gesture")
        case .mayBegin:
            state = .idle
            return .pass("fingers down")
        case .ended, .cancelled:
            let was = state
            state = .idle
            if case .holding = was { return .pass("lifted before it travelled far enough") }
            return .pass("lifted")
        case .began:
            state = .idle
            guard e.precise else { state = .scrolling; return .pass("not a trackpad") }
            return weigh(delta, context)
        case .changed:
            switch state {
            case .idle: return .pass("no gesture began here")
            case .scrolling: return .pass("scrolling")
            case .undecided(let sum): return weigh(sum + delta, context)
            case .holding(let back, let sum):
                let total = sum + delta
                if abs(total.height) >= abs(total.width) * Self.verticalRatio { state = .scrolling; return .pass("turned vertical") }
                if (total.width > 0) != back { state = .scrolling; return .pass("turned around") }
                if abs(total.width) >= Self.distance { state = .idle; return .start(back: back) }
                state = .holding(back: back, total)
                return .hold
            }
        }
    }

    /// The first movement: sideways, in a direction history and the scroller allow, or not.
    private mutating func weigh(_ total: CGSize, _ context: () -> Context) -> Decision {
        if abs(total.width) < 0.5, abs(total.height) < 0.5 { state = .undecided(total); return .pass("no movement yet") }
        guard abs(total.width) > abs(total.height) else { state = .scrolling; return .pass("vertical") }
        let back = total.width > 0
        let c = context()
        if c.pans { state = .scrolling; return .pass("the view pans") }
        guard back ? c.canBack : c.canForward else { state = .scrolling; return .pass(back ? "nothing back" : "nothing forward") }
        guard back ? c.pinnedLeft : c.pinnedRight else { state = .scrolling; return .pass("scroller not at its edge") }
        if abs(total.width) >= Self.distance { state = .idle; return .start(back: back) }
        state = .holding(back: back, total)
        return .hold
    }
}

private func + (a: CGSize, b: CGSize) -> CGSize { CGSize(width: a.width + b.width, height: a.height + b.height) }

// MARK: - Following a swipe

/// AppKit's swipe tracking callbacks (`trackSwipeEvent`) read the way Safari reads them:
/// `.ended` means the fingers lifted and the swipe goes through, `.cancelled` that it won't.
/// AppKit then animates the amount home (±1 or 0) and says `isComplete` last, often in a
/// callback with no phase, which is where the swipe commits or doesn't. While the fingers are
/// down (`.began`, `.changed`), crossing `ready` taps once (re-armed below `rearm`).
struct SwipeProgress: Equatable {
    enum Output: Equatable { case haptic, commit, cancel }

    /// The amount, in the swipe's direction, at which the chevron turns accent and the pad taps.
    static let ready: CGFloat = 1
    static let rearm: CGFloat = 0.85

    let back: Bool
    private(set) var amount: CGFloat = 0
    private(set) var ended = false
    private(set) var cancelled = false
    private(set) var finished = false
    private var armed = true

    init(back: Bool) { self.back = back }

    /// The amount in the swipe's own direction: 1 is a full swipe, back or forward.
    var progress: CGFloat { back ? amount : -amount }
    var lifted: Bool { ended || cancelled }

    mutating func update(amount: CGFloat, phase: SwipeGate.Phase, complete: Bool) -> [Output] {
        guard !finished else { return [] }
        self.amount = amount
        if phase == .ended { ended = true }
        if phase == .cancelled { cancelled = true }
        var out: [Output] = []
        // Only callbacks the fingers drive tap; the settle after a lift comes with no phase.
        if !lifted, phase == .began || phase == .changed {
            if armed, progress >= Self.ready { armed = false; out.append(.haptic) }
            else if !armed, progress < Self.rearm { armed = true }
        }
        if complete {
            finished = true
            // Without either phase, where the amount settled says which it was.
            let commits = cancelled ? false : ended || progress >= 0.5
            out.append(commits ? .commit : .cancel)
        }
        return out
    }

    /// Ends it now, as if `isComplete` had come: for when AppKit goes quiet.
    mutating func abandon() -> Output {
        finished = true
        return ended && !cancelled ? .commit : .cancel
    }
}

// MARK: - The navigator

/// Two-finger swipes go back and forward through history, tracked like Safari: the content
/// follows the fingers, rubber-banding past a full swipe; an edge chevron fills in and turns
/// accent with one tap of the trackpad when letting go will commit; after a commit the new
/// place eases in from the side it was on. Three-finger swipes (when macOS is set that way)
/// commit at once. Sideways scrollers keep the gesture until they rest at the edge; the graph
/// keeps it always. With FLAMINGO_DEBUG every decision is logged as `swipe:`.
@MainActor
final class SwipeNavigator {
    /// The window's navigator, for the QA hook.
    private(set) static weak var shared: SwipeNavigator?

    private unowned let state: AppState
    private weak var window: NSWindow?
    private var monitor: Any?
    private var gate = SwipeGate()
    private var progress: SwipeProgress?
    /// Which swipe AppKit's callbacks belong to; a late callback from an old one is ignored.
    private var swipeID = 0
    /// Scroll events that reached the monitor while AppKit was tracking a swipe.
    private var eventsWhileTracking = 0
    private var watchdog: DispatchWorkItem?
    private var lastReason = ""
    /// A swipe's leftover momentum, kept from the place it lands on until fingers touch again.
    private var swallowingMomentum = false
    /// `FLAMINGO_SLOWMO=6` plays the arrival six times slower, for screenshots.
    private static let slowdown = max(1, Double(ProcessInfo.processInfo.environment["FLAMINGO_SLOWMO"] ?? "") ?? 1)

    /// AppKit calls back every frame while tracking; this long without a call means it stopped.
    static let quietLimit: TimeInterval = 1.5

    init(state: AppState, window: NSWindow) {
        self.state = state
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
            let forward = MainActor.assumeIsolated { self.map { $0.handle(event) } ?? true }
            return forward ? event : nil
        }
        Self.shared = self
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    /// `false` swallows the event.
    private func handle(_ e: NSEvent) -> Bool {
        guard let window else { return true }
        if e.type == .swipe {
            guard e.window === window else { return true }
            let back = e.deltaX > 0
            Log.debug("swipe: three-finger \(back ? "back" : "forward") canBack=\(state.canGoBack) canForward=\(state.canGoForward)")
            if back ? state.canGoBack : state.canGoForward {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
                commit(back: back)
            }
            return false
        }
        let location: NSPoint
        if e.window === window {
            location = e.locationInWindow
        } else if e.window == nil, Log.enabled, window.frame.contains(e.locationInWindow) {
            // QA posts gestures to the pid, and AppKit gives those no window.
            location = window.convertPoint(fromScreen: e.locationInWindow)
        } else {
            return true
        }
        return !route(e, at: location, in: window)
    }

    /// `true` when the event is the navigator's.
    private func route(_ e: NSEvent, at location: NSPoint, in window: NSWindow) -> Bool {
        let phase = SwipeGate.Phase(e.phase)
        if progress != nil {
            // AppKit is following a swipe. Some of its events reach AppKit before this monitor,
            // some only after it, on their way to the window: swallowed here, those never reach
            // the tracker and the swipe stalls (seen in QA). So they go on, as Safari lets them.
            eventsWhileTracking += 1
            return false
        }
        if phase == .mayBegin || phase == .began { swallowingMomentum = false }
        if swallowingMomentum, !e.momentumPhase.isEmpty { return true }
        guard NSEvent.isSwipeTrackingFromScrollEventsEnabled else {
            if phase == .began { Log.debug("swipe: off (System Settings: swipe between pages)") }
            gate.reset()
            return false
        }
        let event = SwipeGate.Event(phase: phase, momentum: !e.momentumPhase.isEmpty, dx: e.scrollingDeltaX,
                                    dy: e.scrollingDeltaY, precise: e.hasPreciseScrollingDeltas)
        let before = gate.state
        var seen: SwipeGate.Context?
        let decision = gate.decide(event) {
            let c = self.context(at: location, in: window)
            seen = c
            return c
        }
        log(event, before: before, decision: decision, context: seen)
        switch decision {
        case .pass: return false
        case .hold: return true
        case .start(let back): start(e, back: back); return true
        }
    }

    private func log(_ e: SwipeGate.Event, before: SwipeGate.State, decision: SwipeGate.Decision, context: SwipeGate.Context?) {
        guard Log.enabled else { return }
        let reason: String
        switch decision {
        case .pass(let why): reason = why
        case .hold: reason = "hold"
        case .start(let back): reason = back ? "start back" : "start forward"
        }
        // Every phase change and every new verdict; not each frame of a scroll.
        let quiet = e.phase == .changed && reason == lastReason && before == gate.state && reason != "hold"
        lastReason = reason
        if quiet || e.momentum { return }
        let edges = context.map { " canBack=\($0.canBack) canForward=\($0.canForward) pans=\($0.pans) pinned=\($0.pinnedLeft ? "L" : "")\($0.pinnedRight ? "R" : "")" } ?? ""
        Log.debug("swipe: \(e.phase) dx=\(e.dx) dy=\(e.dy) precise=\(e.precise) → \(reason)\(edges)")
    }

    /// History, and whether what is under the pointer keeps sideways scrolls for itself.
    private func context(at point: NSPoint, in window: NSWindow) -> SwipeGate.Context {
        var c = SwipeGate.Context(canBack: state.canGoBack, canForward: state.canGoForward)
        var view = window.contentView?.hitTest(point)
        while let v = view {
            if String(describing: type(of: v)).hasPrefix("GraphInput") { c.pans = true; break }
            if let scroll = v as? NSScrollView, let edges = Self.sidewaysEdges(of: scroll) {
                c.pinnedLeft = edges.left
                c.pinnedRight = edges.right
                break
            }
            view = v.superview
        }
        return c
    }

    /// For a scroll view wider inside than out: whether it rests at its left and right edges.
    /// `nil` when it can't scroll sideways.
    static func sidewaysEdges(of scroll: NSScrollView) -> (left: Bool, right: Bool)? {
        guard let doc = scroll.documentView else { return nil }
        let clip = scroll.contentView.bounds, frame = doc.frame, insets = scroll.contentInsets
        guard frame.width + insets.left + insets.right > clip.width + 1 else { return nil }
        return (clip.minX <= frame.minX - insets.left + 1, clip.maxX >= frame.maxX + insets.right - 1)
    }

    private func start(_ e: NSEvent, back: Bool) {
        swipeID &+= 1
        let id = swipeID
        progress = SwipeProgress(back: back)
        eventsWhileTracking = 0
        swallowingMomentum = true
        let canBack = state.canGoBack, canForward = state.canGoForward
        Log.debug("swipe: tracking \(back ? "back" : "forward") #\(id)")
        armWatchdog()
        // Past a full swipe the amount rubber-bands; towards no history it can't go at all.
        e.trackSwipeEvent(options: [.lockDirection], dampenAmountThresholdMin: canForward ? -1 : 0,
                          max: canBack ? 1 : 0) { [weak self] amount, phase, complete, _ in
            MainActor.assumeIsolated { self?.tracked(id, amount, SwipeGate.Phase(phase), complete) }
        }
    }

    private func tracked(_ id: Int, _ amount: CGFloat, _ phase: SwipeGate.Phase, _ complete: Bool) {
        guard id == swipeID, var p = progress else { return }
        let outputs = p.update(amount: amount, phase: phase, complete: complete)
        progress = p
        Log.debug(String(format: "swipe: #%d amount=%.3f %@%@", id, amount, "\(phase)", complete ? " complete" : ""))
        if !complete { armWatchdog() }
        state.swipeAmount = amount
        for output in outputs { perform(output, back: p.back) }
    }

    private func perform(_ output: SwipeProgress.Output, back: Bool) {
        switch output {
        case .haptic:
            // The moment the chevron turns accent, while the fingers are still on the pad.
            Log.debug("swipe: ready, tap")
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
        case .commit:
            finish()
            Log.debug("swipe: commit \(back ? "back" : "forward")\(eventsWhileTracking > 0 ? " (\(eventsWhileTracking) events reached the monitor while tracking)" : "")")
            commit(back: back)
        case .cancel:
            finish()
            Log.debug("swipe: cancelled\(eventsWhileTracking > 0 ? " (\(eventsWhileTracking) events reached the monitor while tracking)" : "")")
            state.swipeAmount = 0
        }
    }

    private func finish() {
        watchdog?.cancel()
        watchdog = nil
        progress = nil
    }

    /// If AppKit stops calling back, the swipe ends where it stood rather than leaving swipes off.
    private func armWatchdog() {
        watchdog?.cancel()
        let id = swipeID
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, id == self.swipeID, var p = self.progress else { return }
                let output = p.abandon()
                self.progress = p
                Log.debug("swipe: #\(id) AppKit went quiet (lifted=\(p.lifted)); ending it")
                self.perform(output, back: p.back)
            }
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quietLimit, execute: work)
    }

    /// Back or forward, and the place it lands on eases in from the side it was on.
    private func commit(back: Bool) {
        if back { state.goBack() } else { state.goForward() }
        let layout = state.layout
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            layout.swipeAmount = 0
            layout.swipeArrival = back ? -1 : 1
        }
        // A frame later, so the starting side is drawn before it eases home.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) {
            withAnimation(Theme.Motion.normal.speed(1 / Self.slowdown)) { layout.swipeArrival = 0 }
        }
    }

    // MARK: QA

    /// Plays AppKit's side of a swipe without a trackpad: `amounts` while the fingers are down,
    /// then (unless `lift` is nil) the lift and the settle home, as `trackSwipeEvent` reports them.
    func qaSimulate(back: Bool, amounts: [CGFloat], lift: SwipeGate.Phase?) {
        swipeID &+= 1
        let id = swipeID
        progress = SwipeProgress(back: back)
        eventsWhileTracking = 0
        Log.debug("swipe: simulated \(back ? "back" : "forward") #\(id)")
        let sign: CGFloat = back ? 1 : -1
        var steps: [(CGFloat, SwipeGate.Phase, Bool)] = amounts.map { (sign * $0, .changed, false) }
        if let lift { steps += qaSettle(from: amounts.last ?? 0, sign: sign, lift: lift) }
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) / 60) { [weak self] in
                self?.tracked(id, step.0, step.1, step.2)
                // Fingers held for a screenshot: nothing will call back until `qaLift`.
                if lift == nil, i == steps.count - 1 { self?.watchdog?.cancel() }
            }
        }
    }

    /// Lifts a simulated swipe that `qaSimulate` left with the fingers down.
    func qaLift(_ phase: SwipeGate.Phase) {
        guard let p = progress else { return Log.debug("swipe: nothing to lift") }
        let id = swipeID
        let steps = qaSettle(from: p.progress, sign: p.back ? 1 : -1, lift: phase)
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) / 60) { [weak self] in
                self?.tracked(id, step.0, step.1, step.2)
            }
        }
    }

    /// What AppKit reports after the fingers lift: the lift's phase, the amount easing to ±1 or
    /// 0, and `isComplete` in a callback with no phase.
    private func qaSettle(from start: CGFloat, sign: CGFloat, lift: SwipeGate.Phase) -> [(CGFloat, SwipeGate.Phase, Bool)] {
        let target: CGFloat = lift == .ended ? 1 : 0
        let n = 8
        var out: [(CGFloat, SwipeGate.Phase, Bool)] = [(sign * start, lift, false)]
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n), eased = 1 - (1 - t) * (1 - t)
            out.append((sign * (start + (target - start) * eased), i == n ? .none : lift, i == n))
        }
        return out
    }
}

// MARK: - What the content does

/// The content while swiping: it follows the fingers (a quarter of its width at a full swipe,
/// rubber-banding past that) and fades a little as it leaves; after a commit the new place
/// eases in from the side it was on. The chevrons ride the edges.
struct SwipeFollow: ViewModifier {
    @ObservedObject var layout: PanelLayout

    nonisolated static func travel(_ width: CGFloat) -> CGFloat { min(240, max(80, width * 0.25)) }

    func body(content: Content) -> some View {
        let amount = layout.swipeAmount, arrival = layout.swipeArrival
        content
            .visualEffect { view, proxy in
                let travel = SwipeFollow.travel(proxy.size.width)
                return view.offset(x: amount * travel + arrival * travel * 0.5)
            }
            .opacity(1 - 0.2 * Double(min(1, abs(amount))) - 0.5 * Double(abs(arrival)))
            .overlay(alignment: .leading) { SwipeChevron(amount: amount, back: true) }
            .overlay(alignment: .trailing) { SwipeChevron(amount: amount, back: false) }
    }
}

/// The edge indicator while swiping: a small disc with a chevron that slides in and turns
/// accent once letting go will commit.
struct SwipeChevron: View {
    var amount: CGFloat
    var back: Bool

    var body: some View {
        let toward = back ? amount : -amount
        let m = min(1, max(0, toward))
        let ready = toward >= SwipeProgress.ready
        ZStack {
            Circle().fill(Theme.Color.bgRaised)
            Circle().strokeBorder(ready ? Theme.Color.accent : Theme.Color.hairline, lineWidth: 1)
            Image(systemName: back ? "chevron.left" : "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ready ? Theme.Color.accent : Theme.Color.textSecondary)
        }
        .frame(width: 30, height: 30)
        .scaleEffect(0.7 + 0.3 * m)
        .opacity(Double(m))
        .offset(x: (back ? 1 : -1) * (m * 36 - 20))
        .animation(Theme.Motion.fast, value: ready)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
