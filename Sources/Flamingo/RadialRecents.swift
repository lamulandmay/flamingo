import AppKit
import SwiftUI
import FlamingoCore
import FlamingoDesign

// MARK: - State machine

/// Hold ⌘⌥ for a ring of recent files. This is the whole decision logic as a pure struct of
/// inputs and effects, so it can be unit-tested without a window. `RadialRecentsController`
/// feeds it AppKit events and carries out the effects.
///
/// Idle → armed when the modifiers become exactly ⌘⌥ from fewer. Armed → open when the hold
/// delay passes with ⌘⌥ still down. Anything else while armed cancels and the event goes on
/// to the app, so ⌥⌘H/N/I/L/1/3/→ keep working. Open: the pointer picks a slot, releasing ⌘
/// or ⌥ commits it (or closes, in the dead zone), Esc closes and is consumed, other keys and
/// clicks close and pass through.
struct RadialHoldMachine {
    struct Modifiers: OptionSet, Equatable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1), option = Modifiers(rawValue: 2)
        static let shift = Modifiers(rawValue: 4), control = Modifiers(rawValue: 8)
    }

    enum Input {
        /// `eligible`: the controller's check that a ring may open now (main window key, no
        /// sheet or modal, a vault open, no marked text).
        case flags(Modifiers, buttonsDown: Bool, eligible: Bool)
        case keyDown(UInt16)
        case mouseDown
        case scroll
        /// The hold timer fired, with the number of files the ring would show.
        case tick(itemCount: Int)
        /// Pointer offset since the ring opened, in points; +x right, +y down.
        case pointer(CGVector)
        case resign
    }

    enum Effect: Equatable {
        case schedule(TimeInterval)
        case disarm(reason: String)
        case present
        case highlight(Int?)
        case commit(Int)
        case dismiss(animated: Bool, reason: String)
    }

    enum Phase: Equatable { case idle, armed, open }

    static let escape: UInt16 = 53
    static let deadZone: CGFloat = 28
    static let hysteresis: Double = 4

    var holdDelay: TimeInterval = 0.30
    private(set) var phase: Phase = .idle
    private(set) var modifiers: Modifiers = []
    private(set) var highlighted: Int?
    /// 4 or 8, fixed when the ring opens.
    private(set) var slotCount = 8
    private(set) var itemCount = 0
    private var armedAt: TimeInterval = 0
    private var slot: Int?          // the geometric slot, even when it holds no file

    /// Degrees per slot.
    var step: Double { 360 / Double(slotCount) }

    mutating func handle(_ input: Input, now: TimeInterval) -> (effects: [Effect], passThrough: Bool) {
        var effects: [Effect] = []
        switch input {
        case let .flags(flags, buttonsDown, eligible):
            let before = modifiers
            modifiers = flags
            switch phase {
            case .idle:
                // Exactly ⌘⌥, reached by adding to what was held: ⌘⌥⇧ → ⌘⌥ doesn't count.
                if flags == [.command, .option], before != flags, before.isSubset(of: flags), eligible, !buttonsDown {
                    phase = .armed; armedAt = now
                    effects.append(.schedule(holdDelay))
                }
            case .armed:
                if flags != before { phase = .idle; effects.append(.disarm(reason: "flags")) }
            case .open:
                if !flags.contains(.command) || !flags.contains(.option) {
                    phase = .idle
                    if let h = highlighted { effects.append(.commit(h)) }
                    else { effects.append(.dismiss(animated: true, reason: "released")) }
                    reset()
                }
            }
            return (effects, true)

        case let .keyDown(code):
            switch phase {
            case .idle: return ([], true)
            case .armed:
                phase = .idle
                return ([.disarm(reason: "key")], true)
            case .open:
                phase = .idle; reset()
                if code == Self.escape { return ([.dismiss(animated: true, reason: "escape")], false) }
                return ([.dismiss(animated: false, reason: "key")], true)
            }

        case .mouseDown:
            switch phase {
            case .idle: break
            case .armed: phase = .idle; effects.append(.disarm(reason: "mouse"))
            case .open: phase = .idle; reset(); effects.append(.dismiss(animated: true, reason: "mouse"))
            }
            return (effects, true)

        case .scroll:
            // Only before the ring opens: a scroll in progress is a different gesture.
            if phase == .armed { phase = .idle; effects.append(.disarm(reason: "scroll")) }
            return (effects, true)

        case let .tick(count):
            guard phase == .armed else { return ([], true) }
            guard modifiers == [.command, .option], now - armedAt >= holdDelay - 0.01, count > 0 else {
                phase = .idle
                return ([.disarm(reason: count > 0 ? "flags" : "empty")], true)
            }
            phase = .open
            itemCount = count
            slotCount = count <= 4 ? 4 : 8
            highlighted = nil; slot = nil
            return ([.present], true)

        case let .pointer(offset):
            guard phase == .open else { return ([], true) }
            let next = nextSlot(for: offset)
            slot = next
            let shown = next.flatMap { $0 < itemCount ? $0 : nil }
            if shown != highlighted {
                highlighted = shown
                effects.append(.highlight(shown))
            }
            return (effects, true)

        case .resign:
            let was = phase
            phase = .idle; reset()
            switch was {
            case .open: effects.append(.dismiss(animated: false, reason: "resign"))
            case .armed: effects.append(.disarm(reason: "resign"))
            case .idle: break
            }
            return (effects, true)
        }
    }

    private mutating func reset() { highlighted = nil; slot = nil; itemCount = 0 }

    /// The slot under an offset from the ring's centre: nil in the dead zone. Slot `i` is
    /// centred `i * step` degrees clockwise of 12 o'clock. The slot already chosen is kept
    /// until the pointer is `hysteresis` degrees past its edge.
    private func nextSlot(for offset: CGVector) -> Int? {
        guard hypot(offset.dx, offset.dy) >= Self.deadZone else { return nil }
        var degrees = atan2(Double(offset.dx), Double(-offset.dy)) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        let fresh = Int(((degrees + step / 2) / step).rounded(.down)) % slotCount
        guard let current = slot, current != fresh else { return fresh }
        var away = abs(degrees - Double(current) * step)
        if away > 180 { away = 360 - away }
        return away <= step / 2 + Self.hysteresis ? current : fresh
    }
}

// MARK: - Published state for the overlay

/// What the ring draws. Only `RadialRecentsView` observes it, so a pointer move redraws
/// nothing else.
@MainActor
final class RadialMenuModel: ObservableObject {
    struct Entry: Identifiable, Equatable {
        var item: RecentItem
        var thoughts: Int
        var id: String { item.id }
    }

    @Published private(set) var isOpen = false
    /// Kept after closing so the fade-out still has something to draw.
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var highlight: Int?
    /// The ring's centre in window content coordinates (y down), already kept inside the window.
    @Published private(set) var center: CGPoint = .zero
    @Published private(set) var slotCount = 8

    /// `FLAMINGO_SLOWMO=6` plays the fades six times slower, for screenshots.
    static let slowdown = max(1, Double(ProcessInfo.processInfo.environment["FLAMINGO_SLOWMO"] ?? "") ?? 1)
    static var fade: Animation { Theme.Motion.fast.speed(1 / slowdown) }

    func present(_ entries: [Entry], slotCount: Int, at center: CGPoint) {
        self.entries = entries
        self.slotCount = slotCount
        self.center = center
        highlight = nil
        withAnimation(Self.fade) { isOpen = true }
    }

    func setHighlight(_ index: Int?) {
        withAnimation(Self.fade) { highlight = index }
    }

    /// `animated: false` removes the ring at once (a key is on its way to the app).
    func close(animated: Bool) {
        if animated { withAnimation(Self.fade) { isOpen = false } }
        else {
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { isOpen = false }
        }
    }
}

// MARK: - Controller

/// Watches ⌘⌥ inside Flamingo only (a local monitor), so no Input Monitoring permission is
/// needed, and drives `RadialHoldMachine`. It never consumes `flagsChanged`, so the graph's
/// ⌥ handling still sees them.
@MainActor
final class RadialRecentsController {
    static weak var shared: RadialRecentsController?

    private unowned let state: AppState
    private weak var window: NSWindow?
    private var machine = RadialHoldMachine()

    /// Settings ▸ General moved the slider.
    func reloadHoldDelay() { machine.holdDelay = Defaults.radialHoldDelay }
    private var monitor: Any?
    private var holdTimer: Timer?
    private var pollTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// The files of the open ring, frozen when it opened.
    private var ring: [RecentItem] = []
    /// Where the pointer was when the ring opened, in window coordinates (y up).
    private var anchorPoint: CGPoint = .zero

    // QA: synthesized events never reach a local monitor, and the QA app is never key.
    private(set) var qaKeyWindowOverride = false
    private var qaPointer: CGVector?
    private var qaOrigin: CGPoint?

    init(state: AppState, window: NSWindow) {
        self.state = state
        self.window = window
        reloadHoldDelay()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown,
                                                              .otherMouseDown, .scrollWheel]) { [weak self] event in
            let consume = MainActor.assumeIsolated { self?.ingest(event) ?? false }
            return consume ? nil : event
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resign() }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resign() }
        })
        RadialRecentsController.shared = self
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// True when the event was handled and must not reach the app.
    private func ingest(_ event: NSEvent) -> Bool {
        switch event.type {
        case .flagsChanged: return run(.flags(Self.modifiers(of: event.modifierFlags), buttonsDown: NSEvent.pressedMouseButtons != 0, eligible: eligible()))
        case .keyDown: return run(.keyDown(event.keyCode))
        case .scrollWheel: return run(.scroll)
        default: return run(.mouseDown)
        }
    }

    private static func modifiers(of flags: NSEvent.ModifierFlags) -> RadialHoldMachine.Modifiers {
        var m: RadialHoldMachine.Modifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        return m   // caps lock and fn are ignored
    }

    /// Whether a ring may start: the main window is key (or QA says so), nothing is on top
    /// of it (no sheet, no morning inbox), a vault is open, and no input method is composing text.
    private func eligible() -> Bool {
        guard let window, state.vault != nil, window.isKeyWindow || qaKeyWindowOverride,
              window.attachedSheet == nil, NSApp.modalWindow == nil, !state.briefing.isPresented else { return false }
        if let client = window.firstResponder as? NSTextInputClient, client.hasMarkedText() { return false }
        return true
    }

    /// Feeds the machine and carries out what it asks. Returns true to consume the event.
    @discardableResult
    private func run(_ input: RadialHoldMachine.Input) -> Bool {
        let result = machine.handle(input, now: ProcessInfo.processInfo.systemUptime)
        for effect in result.effects { perform(effect) }
        return !result.passThrough
    }

    private func perform(_ effect: RadialHoldMachine.Effect) {
        switch effect {
        case .schedule(let delay):
            Log.debug("radial: arm")
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.holdElapsed() }
            }
        case .disarm(let reason):
            holdTimer?.invalidate(); holdTimer = nil
            Log.debug("radial: cancel \(reason)")
        case .present:
            present()
        case .highlight(let index):
            state.radial.setHighlight(index)
            if let index, ring.indices.contains(index) {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                Log.debug("radial: highlight \(index) \(ring[index].id)")
            } else {
                Log.debug("radial: highlight none")
            }
        case .commit(let index):
            stopPolling()
            state.radial.close(animated: true)
            guard ring.indices.contains(index) else { return }
            let item = ring[index]
            Log.debug("radial: commit \(item.id)")
            guard state.vault?.exists(item.file) == true else {
                state.recents.refreshSoon(after: 0)
                return
            }
            state.reveal(item.file, anchor: item.lastAnchor)
        case .dismiss(let animated, let reason):
            stopPolling()
            state.radial.close(animated: animated)
            Log.debug("radial: cancel \(reason)")
        }
    }

    private func holdElapsed() {
        holdTimer = nil
        ring = state.recents.ring(excluding: state.activePane.file)
        run(.tick(itemCount: ring.count))
    }

    private func present() {
        guard let window, let content = window.contentView else { return }
        let bounds = content.bounds
        let pointer = qaOrigin ?? window.mouseLocationOutsideOfEventStream
        anchorPoint = pointer
        if qaPointer != nil { qaPointer = .zero }
        let half = RadialRecentsView.plate / 2 + 8
        // Window coordinates are y up; the overlay is y down.
        let x = bounds.width > 2 * half ? min(max(pointer.x, half), bounds.width - half) : bounds.width / 2
        let flippedY = bounds.height - pointer.y
        let y = bounds.height > 2 * half ? min(max(flippedY, half), bounds.height - half) : bounds.height / 2
        let entries = ring.map { RadialMenuModel.Entry(item: $0, thoughts: state.commentCounts[$0.file] ?? 0) }
        state.radial.present(entries, slotCount: machine.slotCount, at: CGPoint(x: x, y: y))
        Log.debug("radial: open n=\(ring.count)")
        startPolling()
    }

    private func resign() {
        guard machine.phase != .idle else { return }
        run(.resign)
    }

    // MARK: Pointer

    private func startPolling() {
        stopPolling()
        pollTimer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
        poll()
    }

    private func stopPolling() { pollTimer?.invalidate(); pollTimer = nil }

    /// The pointer's movement since the ring opened, not its distance from the drawn centre,
    /// which may have been shifted to fit the window.
    private func poll() {
        guard machine.phase == .open else { return }
        if let qaPointer { run(.pointer(qaPointer)); return }
        guard let window else { return }
        let p = window.mouseLocationOutsideOfEventStream
        run(.pointer(CGVector(dx: p.x - anchorPoint.x, dy: anchorPoint.y - p.y)))
    }

    // MARK: QA

    /// `flags cmd opt` / `flags none`.
    func qaIngest(flags: NSEvent.ModifierFlags) {
        qaKeyWindowOverride = true
        let mods = Self.modifiers(of: flags)
        Log.debug("radial: qa flags \(mods.rawValue)")
        run(.flags(mods, buttonsDown: false, eligible: eligible()))
    }

    /// Offers a synthesized keyDown first. True when the ring consumed it (Esc).
    func qaIngest(keyCode: UInt16) -> Bool { run(.keyDown(keyCode)) }

    /// `radial <deg> [dist]` (clockwise from 12 o'clock) or, with `nil`, `radial center`. Once
    /// used, the pointer is the fake one until the app restarts; each new ring starts at the centre.
    func qaPointer(degrees: Double?, distance: Double = 80) {
        guard let degrees else { qaPointer = .zero; poll(); return }
        let r = degrees * .pi / 180
        qaPointer = CGVector(dx: distance * sin(r), dy: -distance * cos(r))
        poll()
    }

    /// `radial origin <x> <y>`: where the ring opens, in window content coordinates (y down).
    func qaOrigin(x: Double, y: Double) {
        guard let height = window?.contentView?.bounds.height else { return }
        qaOrigin = CGPoint(x: x, y: height - y)
        if qaPointer == nil { qaPointer = .zero }   // a fixed origin means a fixed pointer
    }

    func qaReset() { qaKeyWindowOverride = false; qaPointer = nil; qaOrigin = nil }
}
