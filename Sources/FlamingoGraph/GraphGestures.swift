import Foundation
import CoreGraphics
import AppKit
import FlamingoDesign

// The decisions behind the graph's pointer, trackpad and keyboard input. `GraphInputNSView`
// converts NSEvents into these calls; everything here works on plain values so it can be
// tested without a window. All points are in the canvas's space: origin top-left, y down.

/// One scroll-wheel event, already converted to view coordinates.
struct GraphScrollInput {
    var location: CGPoint
    /// `scrollingDeltaX/Y`: points when `precise`, lines otherwise. Positive y = content moves
    /// down (what NSScrollView does with the same event).
    var delta: CGSize
    /// `hasPreciseScrollingDeltas`: trackpad or Magic Mouse.
    var precise: Bool
    var modifiers: NSEvent.ModifierFlags = []
    var phase: NSEvent.Phase = []
    var momentumPhase: NSEvent.Phase = []
    /// `isDirectionInvertedFromDevice` (natural scrolling). Only used to make wheel zoom follow
    /// the physical direction: away from you zooms in, whatever the scrolling preference.
    var invertedFromDevice = false
}

/// One key event.
struct GraphKeyInput {
    var keyCode: UInt16
    var characters: String
    var charactersIgnoringModifiers: String
    var modifiers: NSEvent.ModifierFlags = []
    var isRepeat = false
}

/// Virtual key codes (layout independent) the graph handles by position rather than character.
enum GraphKeyCode {
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let space: UInt16 = 49
    static let escape: UInt16 = 53
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
}

@MainActor
final class GraphGestureRecognizer {
    /// Pointer travel before a press becomes a drag.
    static let dragThreshold: CGFloat = 3
    /// ln(zoom factor) per wheel line (≈12% per notch) and per precise point.
    static let lineZoomRate: CGFloat = 0.12
    static let preciseZoomRate: CGFloat = 0.01
    /// Caps one scroll event's zoom step (accelerated wheels report 10+ lines at once).
    static let maxScrollZoomStep: CGFloat = 0.5
    static let keyboardZoomStep: CGFloat = 1.25
    static let keyboardZoomDuration: TimeInterval = Theme.Motion.fastSeconds
    /// Quiet time after the last scroll/pinch before hover is re-evaluated under the pointer.
    static let hoverSettleDelay: TimeInterval = 0.12
    /// Long enough for the model's fit animation to finish.
    static let fitSettleDelay: TimeInterval = Theme.Motion.normalSeconds + 0.05

    weak var target: GraphInteractionTarget?
    /// The view's bounds size; camera anchors and hit bounds use it.
    var viewSize: CGSize = .zero

    // MARK: Hooks (injectable for tests)

    /// Runs `work` after `delay` seconds on the main actor. Scheduled work is never cancelled;
    /// it checks a generation token instead.
    var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void = GraphGestureRecognizer.mainQueueAfter
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var doubleClickInterval: () -> TimeInterval = { NSEvent.doubleClickInterval }
    /// Off under Reduce Motion: keyboard zoom then jumps.
    var animatesKeyboardZoom = true
    /// true when a background drag starts panning, false when it ends. The view shows the
    /// closed-hand cursor in between.
    var onPanningChanged: (Bool) -> Void = { _ in }
    /// A keyboard zoom animation started: call `stepAnimation()` every display frame until it
    /// returns false.
    var onAnimationStarted: () -> Void = {}

    // MARK: State

    private enum Press {
        case idle
        /// Mouse is down and hasn't moved past the threshold.
        case pressed(start: CGPoint, node: Int?, grab: CGSize, clickCount: Int, isDouble: Bool)
        case draggingNode(node: Int, grab: CGSize)
        case panning(last: CGPoint)
        /// ⌥-drag from a node: drawing a connection.
        case linking(node: Int)
    }

    private struct LastClick { var node: Int? }
    private struct PendingClick { var node: Int; var token: Int }
    private struct ZoomAnimation { var from: CGFloat; var to: CGFloat; var start: TimeInterval }

    private var press = Press.idle
    private var pressAdditive = false
    /// ⌥ was down on the press: a drag from a node draws a connection instead of moving it.
    private var pressLinks = false
    /// Last value sent to `target.hover`.
    private(set) var hovered: Int?
    /// Last known pointer location; nil once it leaves the view.
    private(set) var pointer: CGPoint?
    private var lastClick: LastClick?
    private var pendingClick: PendingClick?
    private var clickToken = 0
    private var hoverToken = 0
    /// Pan or zoom, decided when a phased scroll gesture begins and kept through its momentum.
    private var scrollZoomLatch: Bool?
    private var zoomAnimation: ZoomAnimation?

    init(target: GraphInteractionTarget? = nil) {
        self.target = target
    }

    var isPanning: Bool { if case .panning = press { true } else { false } }
    var draggedNode: Int? { if case let .draggingNode(node, _) = press { node } else { nil } }
    var isAnimating: Bool { zoomAnimation != nil }
    var hasPendingClick: Bool { pendingClick != nil }

    // MARK: Mouse

    /// Left mouse down. Returns false for presses the graph leaves alone (⌃-click is a
    /// secondary click on macOS); pass those to `super`.
    @discardableResult
    func mouseDown(at p: CGPoint, clickCount: Int, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard !modifiers.contains(.control) else { return false }
        finishPress(at: p)   // a lost mouseUp (modal, window switch) must not leave a drag open
        pressAdditive = modifiers.contains(.command)
        pressLinks = modifiers.contains(.option)
        pointer = p
        guard let target else { return true }
        let node = target.node(atScreen: p)
        let isDouble = clickCount == 2 && lastClick.map { $0.node == node } == true

        if let pending = pendingClick {
            pendingClick = nil
            // The second press of a double-click on a pinned node cancels its deferred open.
            // Any other press means the first click was a real single click: deliver it now.
            if !(isDouble && pending.node == node) { target.click(pending.node) }
        }

        var grab = CGSize.zero
        if let node {
            let world = target.worldPosition(of: node)
            let cursor = target.camera.toWorld(p, size: viewSize)
            grab = CGSize(width: world.x - cursor.x, height: world.y - cursor.y)
        }
        press = .pressed(start: p, node: node, grab: grab, clickCount: clickCount, isDouble: isDouble)
        return true
    }

    func mouseDragged(to p: CGPoint) {
        pointer = p
        guard let target else { return }
        switch press {
        case .idle:
            return
        case let .pressed(start, node, grab, _, _):
            guard hypot(p.x - start.x, p.y - start.y) > Self.dragThreshold else { return }
            lastClick = nil
            if let node, pressLinks {
                press = .linking(node: node)
                target.beginLink(from: node, to: p)
                target.updateLink(to: p, over: target.node(atScreen: p))
            } else if let node {
                press = .draggingNode(node: node, grab: grab)
                setHover(node)
                target.beginNodeDrag(node)
                target.dragNode(node, toWorld: world(p, offset: grab))
            } else {
                // Start from the press point so the content tracks the pointer exactly,
                // including the threshold distance.
                press = .panning(last: start)
                onPanningChanged(true)
                cancelZoomAnimation()
                target.userMovedCamera()
                pan(to: p)
            }
        case let .draggingNode(node, grab):
            target.dragNode(node, toWorld: world(p, offset: grab))
        case .panning:
            pan(to: p)
        case .linking:
            target.updateLink(to: p, over: target.node(atScreen: p))
        }
    }

    func mouseUp(at p: CGPoint) {
        pointer = p
        let state = press
        press = .idle
        switch state {
        case .idle:
            return
        case let .pressed(_, node, _, clickCount, isDouble):
            lastClick = LastClick(node: node)
            guard let target else { return }
            if isDouble && !pressAdditive {
                if let node { target.activate(node) } else { fitAll() }
            } else if clickCount <= 2, let node {
                // clickCount 2 that isn't a double on the same thing (the second press
                // landed elsewhere) counts as a single click. Triple clicks do nothing.
                // Selecting is harmless before a possible second click, so never defer.
                target.click(node, additive: pressAdditive)
            }
        case let .draggingNode(node, _):
            target?.endNodeDrag(node)
            refreshHover(at: p)
        case .panning:
            onPanningChanged(false)
            refreshHover(at: p)
        case let .linking(node):
            target?.endLink(from: node, onto: target?.node(atScreen: p))
            refreshHover(at: p)
        }
    }

    func mouseMoved(to p: CGPoint) {
        pointer = p
        guard case .idle = press else { return }
        refreshHover(at: p)
    }

    func mouseExited() {
        pointer = nil
        // A drag keeps its hover even when the pointer leaves; mouseUp re-evaluates.
        guard case .idle = press else { return }
        setHover(nil)
    }

    /// Re-evaluates hover at `p` (or the last known pointer). Use after the graph under the
    /// pointer changed without the pointer moving, e.g. a new topology.
    func refreshHover(at p: CGPoint? = nil) {
        guard let target, case .idle = press else { return }
        let p = p ?? pointer
        setHover(p.flatMap { contains($0) ? target.node(atScreen: $0) : nil })
    }

    /// Forgets the cached hover so the next refresh always reports. Call when node indices
    /// changed meaning.
    func invalidateHover() {
        hovered = nil
    }

    // MARK: Scroll and pinch

    func scroll(_ s: GraphScrollInput) {
        pointer = s.location
        guard let target else { return }
        cancelZoomAnimation()

        let wantsZoom = !s.precise || !s.modifiers.intersection([.command, .option]).isEmpty
        let zooms: Bool
        if s.phase.isEmpty && s.momentumPhase.isEmpty {
            // Wheel mice and legacy devices: no gesture, decide per event.
            zooms = wantsZoom
            scrollZoomLatch = nil
        } else if s.phase.contains(.began) || s.phase.contains(.mayBegin) || scrollZoomLatch == nil {
            zooms = wantsZoom
            scrollZoomLatch = wantsZoom
        } else {
            // Releasing ⌘ mid-gesture (or during momentum) doesn't flip zoom into pan.
            zooms = scrollZoomLatch ?? wantsZoom
        }

        if zooms {
            let physical = s.invertedFromDevice ? -s.delta.height : s.delta.height
            let rate = s.precise ? Self.preciseZoomRate : Self.lineZoomRate
            let step = min(max(physical * rate, -Self.maxScrollZoomStep), Self.maxScrollZoomStep)
            guard step != 0, step.isFinite else { return }
            target.userMovedCamera()
            target.camera.zoom(by: exp(step), around: s.location, size: viewSize)
        } else {
            guard s.delta.width != 0 || s.delta.height != 0 else { return }
            target.userMovedCamera()
            target.camera.pan(by: s.delta)
        }
        settleHover(after: Self.hoverSettleDelay)
    }

    /// Trackpad pinch: `event.magnification`.
    func magnify(at p: CGPoint, by magnification: CGFloat) {
        pointer = p
        guard let target, magnification != 0, magnification.isFinite, 1 + magnification > 0 else { return }
        cancelZoomAnimation()
        target.userMovedCamera()
        target.camera.zoom(by: 1 + magnification, around: p, size: viewSize)
        settleHover(after: Self.hoverSettleDelay)
    }

    /// Two-finger double tap.
    func smartMagnify() {
        fitAll()
    }

    // MARK: Keyboard

    /// keyDown. Returns false when the key isn't the graph's; pass it to `super`.
    func keyDown(_ key: GraphKeyInput) -> Bool {
        guard let target else { return false }
        let mods = key.modifiers.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) || mods.contains(.control) { return false }
        switch key.keyCode {
        case GraphKeyCode.left: target.moveSelection(.left); return true
        case GraphKeyCode.right: target.moveSelection(.right); return true
        case GraphKeyCode.up: target.moveSelection(.up); return true
        case GraphKeyCode.down: target.moveSelection(.down); return true
        case GraphKeyCode.returnKey, GraphKeyCode.keypadEnter:
            if !key.isRepeat { target.openSelection() }
            return true
        case GraphKeyCode.space:
            if !key.isRepeat { target.clearSelection() }
            return true
        case GraphKeyCode.escape:
            if !key.isRepeat { target.escape() }
            return true
        default:
            guard Self.isPrintable(key.characters) else { return false }
            target.type(key.characters)
            return true
        }
    }

    /// performKeyEquivalent while the view is first responder. ⌘= / ⌘+ zoom in, ⌘- zoom out,
    /// ⌘0 fits. Returns true only when handled.
    func keyEquivalent(_ key: GraphKeyInput) -> Bool {
        guard target != nil else { return false }
        let mods = key.modifiers.intersection([.command, .control, .option])
        guard mods == .command else { return false }
        switch key.charactersIgnoringModifiers {
        case "=", "+": zoomByKeyboard(Self.keyboardZoomStep)
        case "-": zoomByKeyboard(1 / Self.keyboardZoomStep)
        case "0": fitAll()
        default: return false
        }
        return true
    }

    /// Esc, from keyDown or `cancelOperation(_:)`.
    func escape() {
        if case let .linking(node) = press {
            press = .idle
            target?.endLink(from: node, onto: nil)
            return
        }
        target?.escape()
    }

    /// Letters, digits, punctuation, symbols and space. Not control characters, not the
    /// private-use function-key range (arrows, F-keys, Home/End), not empty dead keys.
    static func isPrintable(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.unicodeScalars.allSatisfy { u in
            switch u.properties.generalCategory {
            case .control, .format, .privateUse, .surrogate, .unassigned,
                 .lineSeparator, .paragraphSeparator:
                return false
            default:
                return true
            }
        }
    }

    // MARK: Keyboard zoom animation

    /// Zooms around the view center by `factor`, eased over `keyboardZoomDuration`. Repeated
    /// presses compound onto the running animation's goal.
    func zoomByKeyboard(_ factor: CGFloat) {
        guard let target, factor.isFinite, factor > 0 else { return }
        target.userMovedCamera()
        let base = zoomAnimation?.to ?? target.camera.zoom
        let goal = Self.clampZoom(base * factor)
        guard animatesKeyboardZoom else {
            zoomAnimation = nil
            setZoomAroundCenter(goal)
            settleHover(after: 0)
            return
        }
        let wasAnimating = zoomAnimation != nil
        zoomAnimation = ZoomAnimation(from: target.camera.zoom, to: goal, start: now())
        if !wasAnimating { onAnimationStarted() }
    }

    /// Advances the keyboard zoom one frame. Returns true while more frames are needed.
    @discardableResult
    func stepAnimation() -> Bool {
        guard let a = zoomAnimation, target != nil else {
            zoomAnimation = nil
            return false
        }
        let t = min(max((now() - a.start) / Self.keyboardZoomDuration, 0), 1)
        let eased = 1 - pow(1 - t, 3)   // cubic ease-out
        setZoomAroundCenter(exp(log(a.from) + (log(a.to) - log(a.from)) * CGFloat(eased)))
        guard t >= 1 else { return true }
        zoomAnimation = nil
        refreshHover()
        return false
    }

    /// Jumps a running keyboard zoom to its goal (e.g. when no display link is available).
    func finishAnimation() {
        guard let a = zoomAnimation else { return }
        zoomAnimation = nil
        setZoomAroundCenter(a.to)
        refreshHover()
    }

    // MARK: Lifecycle

    /// Drops all in-flight state: the view left its window or the target changed. Balances an
    /// open node drag and pan so the model and cursor aren't left mid-gesture.
    func reset() {
        switch press {
        case let .draggingNode(node, _): target?.endNodeDrag(node)
        case .panning: onPanningChanged(false)
        default: break
        }
        press = .idle
        pendingClick = nil
        clickToken &+= 1
        hoverToken &+= 1
        lastClick = nil
        scrollZoomLatch = nil
        zoomAnimation = nil
        hovered = nil
        pointer = nil
    }

    // MARK: Private

    private func finishPress(at p: CGPoint) {
        switch press {
        case .idle, .pressed: press = .idle
        case .draggingNode, .panning: mouseUp(at: p)
        case let .linking(node):
            // A lost mouseUp cancels the line rather than connecting wherever it was.
            press = .idle
            target?.endLink(from: node, onto: nil)
        }
    }

    private func fitAll() {
        cancelZoomAnimation()
        target?.fitAll()
        settleHover(after: Self.fitSettleDelay)
    }

    private func pan(to p: CGPoint) {
        guard case let .panning(last) = press, let target else { return }
        press = .panning(last: p)
        let delta = CGSize(width: p.x - last.x, height: p.y - last.y)
        guard delta != .zero else { return }
        target.camera.pan(by: delta)
    }

    private func world(_ p: CGPoint, offset: CGSize) -> CGPoint {
        let w = target?.camera.toWorld(p, size: viewSize) ?? p
        return CGPoint(x: w.x + offset.width, y: w.y + offset.height)
    }

    private func contains(_ p: CGPoint) -> Bool {
        p.x >= 0 && p.y >= 0 && p.x <= viewSize.width && p.y <= viewSize.height
    }

    private func setHover(_ node: Int?) {
        guard node != hovered else { return }
        hovered = node
        target?.hover(node)
    }

    private func deferClick(_ node: Int) {
        clickToken &+= 1
        let token = clickToken
        pendingClick = PendingClick(node: node, token: token)
        schedule(doubleClickInterval()) { [weak self] in
            guard let self, let pending = self.pendingClick, pending.token == token else { return }
            self.pendingClick = nil
            self.target?.click(pending.node)
        }
    }

    /// Re-evaluates hover once the camera has been still for `delay`.
    private func settleHover(after delay: TimeInterval) {
        hoverToken &+= 1
        let token = hoverToken
        schedule(delay) { [weak self] in
            guard let self, self.hoverToken == token else { return }
            self.refreshHover()
        }
    }

    private func cancelZoomAnimation() {
        zoomAnimation = nil
    }

    private func setZoomAroundCenter(_ zoom: CGFloat) {
        guard let target, target.camera.zoom > 0 else { return }
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        target.camera.zoom(by: Self.clampZoom(zoom) / target.camera.zoom, around: center, size: viewSize)
    }

    private static func clampZoom(_ z: CGFloat) -> CGFloat {
        min(max(z, GraphCamera.zoomRange.lowerBound), GraphCamera.zoomRange.upperBound)
    }

    private static func mainQueueAfter(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0)) {
            MainActor.assumeIsolated { work() }
        }
    }
}
