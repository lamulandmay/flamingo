// Shared by Capybara and Flamingo. Capybara's Sources/CapybaraLink is the original; Flamingo's
// Sources/FlamingoLink/Shared is a copy (scripts/sync-link.sh). Change it here, then sync.

import AppKit

/// Turns the link's phases into the icon's story, frame by frame: the Dock icon, the small mark
/// in the title bar and the larger one that appears while connecting all show the same frame.
///
/// The story is timed from the link's own moments (`since` and `touchdown`), not from when
/// this object happened to hear about them, so two Macs play it in step.
@MainActor
public final class LinkAnimator {
    public let side: LinkMarkSide
    /// Called with every frame while something moves, and once when it comes to rest.
    public var observers: [(LinkScene) -> Void] = []
    /// Off: the Dock keeps the app's own icon (the animation still plays in the window).
    public var animatesDock = true

    public private(set) var scene: LinkScene
    private var phase: LinkNode.Phase = .absent
    private var since: Date?
    private var touchdown: Date?
    /// A departure under way: when it began and what it starts from.
    private var leaving: (at: Date, fromPhase: Double?, reverseApproach: Double?)?
    private var timer: Timer?
    private var lastDock: Date = .distantPast
    private var dockScene: LinkScene?

    public init(side: LinkMarkSide) {
        self.side = side
        scene = .alone(side)
    }

    /// Call with the paired Mac that matters (`LinkNode.primary`) whenever the node changes.
    public func update(_ status: LinkNode.Status?) {
        let newPhase = status?.phase ?? .absent
        let now = Date()
        if newPhase == .absent, phase != .absent {
            // What it was doing decides how it leaves: from the back, from the air, or by
            // turning round mid-approach.
            switch currentScene(at: now) {
            case .approach(_, let t): leaving = (now, nil, t)
            case .hover(let p): leaving = (now, p, nil)
            case .landing(let t, let p) where t < LinkMark.touchdown: leaving = (now, p, nil)
            case .alone: leaving = nil
            default: leaving = (now, nil, nil)
            }
        }
        if newPhase != .absent { leaving = nil }
        phase = newPhase
        since = status?.since
        touchdown = status?.touchdown
        if phase == .connected, touchdown == nil { touchdown = now.addingTimeInterval(-LinkMark.landingDuration) }
        render()
    }

    /// The scene at `now` for the current phase and moments.
    public func currentScene(at now: Date = Date()) -> LinkScene {
        if let l = leaving {
            if let t0 = l.reverseApproach {
                // Back the way it came, as fast as it was going.
                let t = t0 - now.timeIntervalSince(l.at) / LinkMark.approachDuration
                return t <= 0 ? .alone(side) : .approach(side, t: t)
            }
            let t = now.timeIntervalSince(l.at) / LinkMark.departDuration
            return t >= 1 ? .alone(side) : .departing(side, t: max(0, t), fromPhase: l.fromPhase)
        }
        switch phase {
        case .absent:
            return .alone(side)
        case .connected where touchdown.map({ now.timeIntervalSince($0) >= (1 - LinkMark.touchdown) * LinkMark.landingDuration }) ?? true:
            return .together
        default:
            guard let since else { return .alone(side) }
            let approachEnd = since.addingTimeInterval(LinkMark.approachDuration)
            func hoverPhase(_ at: Date) -> Double {
                let p = max(0, at.timeIntervalSince(approachEnd)) / LinkMark.hoverPeriod
                return p - p.rounded(.down)
            }
            if let touchdown {
                let landStart = touchdown.addingTimeInterval(-LinkMark.touchdown * LinkMark.landingDuration)
                if now >= landStart {
                    let t = now.timeIntervalSince(landStart) / LinkMark.landingDuration
                    return t >= 1 ? .together : .landing(t: t, fromPhase: hoverPhase(landStart))
                }
            }
            if now < approachEnd { return .approach(side, t: max(0, now.timeIntervalSince(since) / LinkMark.approachDuration)) }
            return .hover(phase: hoverPhase(now))
        }
    }

    private var isResting: Bool {
        switch scene {
        case .alone, .together: return leaving == nil
        default: return false
        }
    }

    private func render() {
        scene = currentScene()
        if scene == .alone(side) { leaving = nil }
        for o in observers { o(scene) }
        setDock(scene)
        if isResting {
            timer?.invalidate(); timer = nil
        } else if timer == nil {
            // 60 a second for the window; the Dock takes every other one.
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.render() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func setDock(_ scene: LinkScene) {
        guard animatesDock else {
            if dockScene != nil { NSApp.applicationIconImage = nil; dockScene = nil }
            return
        }
        guard scene != dockScene else { return }
        let resting: Bool
        switch scene { case .alone, .together: resting = true; default: resting = false }
        if !resting, Date().timeIntervalSince(lastDock) < 1.0 / 31 { return }
        lastDock = Date()
        dockScene = scene
        if scene == .alone(side) {
            // The app's own icon from its bundle, exactly.
            NSApp.applicationIconImage = nil
            return
        }
        // Moving frames at 256 px keep each one cheap; the still one is drawn sharp.
        let pixels = resting ? 1024 : 256
        if let image = LinkMark.icon(scene, pixels: pixels) {
            NSApp.applicationIconImage = NSImage(cgImage: image, size: NSSize(width: 512, height: 512))
        }
    }
}

/// The animation in a view: the small mark in the title bar, or the larger one while connecting.
public final class LinkMarkView: NSView {
    public var scene: LinkScene = .alone(.capybara) { didSet { if scene != oldValue { needsDisplay = true } } }
    /// Clicked: the app opens its link settings.
    public var onClick: (() -> Void)?

    public override var isFlipped: Bool { false }
    public override var wantsUpdateLayer: Bool { false }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        LinkMark.drawIcon(scene, in: ctx, rect: bounds)
    }

    public override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The larger animation that appears at the top of the window while the Macs connect and fades
/// once the flamingo has settled. Not shown for a departure: the icons tell that quietly.
@MainActor
public final class LinkStage {
    private var panel: NSPanel?
    private let view = LinkMarkView(frame: NSRect(x: 0, y: 0, width: 132, height: 132))
    private weak var window: NSWindow?
    private var hideWork: DispatchWorkItem?
    private var showing = false

    public init(window: NSWindow) { self.window = window }

    public func show(_ scene: LinkScene) {
        view.scene = scene
        switch scene {
        case .approach, .hover, .landing:
            hideWork?.cancel(); hideWork = nil
            if !showing { present() }
        case .together:
            if showing, hideWork == nil {
                let work = DispatchWorkItem { [weak self] in self?.dismiss() }
                hideWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
            }
        case .alone, .departing:
            if showing { dismiss() }
        }
    }

    private func present() {
        guard let window, window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible) else { return }
        let size: CGFloat = 132
        let p = panel ?? {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.isReleasedWhenClosed = false
            p.level = .floating
            p.collectionBehavior = [.transient, .ignoresCycle]
            p.contentView = view
            return p
        }()
        panel = p
        let f = window.frame
        p.setFrame(NSRect(x: f.midX - size / 2, y: f.maxY - size - 56, width: size, height: size), display: false)
        p.alphaValue = 0
        window.addChildWindow(p, ordered: .above)
        showing = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }
    }

    private func dismiss() {
        hideWork = nil
        guard let p = panel, showing else { return }
        showing = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak p] in
            MainActor.assumeIsolated {
                guard let self, let p, !self.showing else { return }
                p.parent?.removeChildWindow(p)
                p.orderOut(nil)
            }
        })
    }
}
