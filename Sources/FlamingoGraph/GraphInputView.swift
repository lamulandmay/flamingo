import AppKit
import QuartzCore
import SwiftUI

/// Transparent AppKit layer laid over the graph `Canvas` (`.overlay(GraphInputLayer(target:))`).
/// SwiftUI gestures can't see scroll wheels or trackpad phases on macOS, so pointer, scroll,
/// pinch and key events land here and are turned into `GraphInteractionTarget` calls by
/// `GraphGestureRecognizer`. Flipped, so its coordinates are the canvas's.
final class GraphInputNSView: NSView {
    /// Held weakly; the model owns the view's lifetime, not the other way round.
    weak var target: GraphInteractionTarget? {
        didSet {
            guard target !== oldValue else { return }
            recognizer.reset()
            recognizer.target = target
            guard window != nil else { return }
            target?.inputViewAttached(self)
            reportSize(force: true)
            refreshHover()
        }
    }

    let recognizer = GraphGestureRecognizer()
    /// The main graph takes the keys as it appears, so arrows work at once. A small graph
    /// beside other work (the inspector's local graph) takes them only when clicked.
    var claimsFocusOnAppear = true
    private var trackingArea: NSTrackingArea?
    private var reportedSize: CGSize?
    private var animationLink: CADisplayLink?
    private var closedHandShown = false

    init(target: GraphInteractionTarget?) {
        super.init(frame: .zero)
        self.target = target
        recognizer.target = target
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Graph")
        recognizer.onPanningChanged = { [weak self] panning in self?.showClosedHand(panning) }
        recognizer.onAnimationStarted = { [weak self] in self?.startAnimationFrames() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    /// Transparent views report true by default, which lets a background drag under a
    /// transparent titlebar move the window instead of panning.
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Window and size

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        stopAnimationFrames()
        recognizer.reset()
        showClosedHand(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        recognizer.animatesKeyboardZoom = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        target?.inputViewAttached(self)
        reportSize(force: true)
        // SwiftUI inserts the view mid-update; take focus on the next turn so arrows work as
        // soon as the graph shows.
        guard claimsFocusOnAppear else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportSize(force: false)
    }

    override func layout() {
        super.layout()
        reportSize(force: false)
    }

    private func reportSize(force: Bool) {
        let size = bounds.size
        recognizer.viewSize = size
        guard window != nil, size.width > 0, size.height > 0 else { return }
        guard force || size != reportedSize else { return }
        reportedSize = size
        target?.viewResized(to: size)
    }

    // MARK: Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // .inVisibleRect follows the visible rect by itself; one area for the view's life.
        guard trackingArea == nil else { return }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    /// Re-evaluates hover at the current pointer location. Call after the nodes under a
    /// still pointer changed (new topology, layout jump).
    func refreshHover() {
        guard let window else { return }
        recognizer.invalidateHover()
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(p) { recognizer.mouseMoved(to: p) } else { recognizer.mouseExited() }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if !recognizer.mouseDown(at: location(of: event), clickCount: event.clickCount,
                                 modifiers: event.modifierFlags) {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        recognizer.mouseDragged(to: location(of: event))
    }

    override func mouseUp(with event: NSEvent) {
        recognizer.mouseUp(at: location(of: event))
    }

    override func mouseMoved(with event: NSEvent) {
        recognizer.mouseMoved(to: location(of: event))
    }

    override func mouseEntered(with event: NSEvent) {
        recognizer.mouseMoved(to: location(of: event))
    }

    override func mouseExited(with event: NSEvent) {
        recognizer.mouseExited()
    }

    override func scrollWheel(with event: NSEvent) {
        recognizer.scroll(GraphScrollInput(
            location: location(of: event),
            delta: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
            precise: event.hasPreciseScrollingDeltas,
            modifiers: event.modifierFlags,
            phase: event.phase,
            momentumPhase: event.momentumPhase,
            invertedFromDevice: event.isDirectionInvertedFromDevice))
    }

    override func magnify(with event: NSEvent) {
        recognizer.magnify(at: location(of: event), by: event.magnification)
    }

    override func smartMagnify(with event: NSEvent) {
        recognizer.smartMagnify()
    }

    /// Right-click or ⌃-click: what can be done with the node under the pointer, or with the view.
    override func menu(for event: NSEvent) -> NSMenu? {
        recognizer.target?.contextMenu(at: location(of: event))
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func showClosedHand(_ show: Bool) {
        guard show != closedHandShown else { return }
        closedHandShown = show
        if show { NSCursor.closedHand.push() } else { NSCursor.pop() }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if !recognizer.keyDown(GraphKeyInput(event)) {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit offers key equivalents to every view in the window; only act with focus.
        if event.type == .keyDown, window?.firstResponder === self,
           recognizer.keyEquivalent(GraphKeyInput(event)) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        recognizer.escape()
    }

    // MARK: Keyboard zoom frames

    private func startAnimationFrames() {
        guard animationLink == nil else { return }
        guard window != nil else {
            recognizer.finishAnimation()
            return
        }
        let link = displayLink(target: self, selector: #selector(animationFrame(_:)))
        link.add(to: .main, forMode: .common)
        animationLink = link
    }

    @objc private func animationFrame(_ link: CADisplayLink) {
        if !recognizer.stepAnimation() { stopAnimationFrames() }
    }

    private func stopAnimationFrames() {
        animationLink?.invalidate()
        animationLink = nil
    }
}

extension GraphKeyInput {
    init(_ event: NSEvent) {
        self.init(keyCode: event.keyCode,
                  characters: event.characters ?? "",
                  charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                  modifiers: event.modifierFlags,
                  isRepeat: event.isARepeat)
    }
}

/// The input layer as a SwiftUI view. Put it in an `.overlay` on the graph canvas, under
/// anything that should receive its own clicks (the filter field).
struct GraphInputLayer: NSViewRepresentable {
    let target: GraphInteractionTarget
    var claimsFocus = true

    init(target: GraphInteractionTarget, claimsFocus: Bool = true) {
        self.target = target
        self.claimsFocus = claimsFocus
    }

    func makeNSView(context: Context) -> GraphInputNSView {
        let view = GraphInputNSView(target: target)
        view.claimsFocusOnAppear = claimsFocus
        return view
    }

    func updateNSView(_ view: GraphInputNSView, context: Context) {
        view.target = target
    }
}
