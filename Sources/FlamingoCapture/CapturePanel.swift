import AppKit
import SwiftUI
import FlamingoDesign

/// Borderless, non-activating panel. It takes keyboard focus without activating
/// Flamingo, so a capture over Keynote leaves Keynote frontmost.
final class CapturePanelWindow: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: CommentPanel.width, height: 64),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc that reaches the window (e.g. focus left the text view) still dismisses.
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Sidebar material, rounded, with a hairline edge. Hosts SwiftUI content.
final class CapturePanelChrome: NSView {
    let effect = NSVisualEffectView()
    private let border = HairlineBorderView()
    static let radius = Theme.Radius.l

    override init(frame: NSRect) {
        super.init(frame: frame)
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.mask(radius: Self.radius)
        effect.autoresizingMask = [.width, .height]
        effect.frame = bounds
        addSubview(effect)
        border.radius = Self.radius
        border.autoresizingMask = [.width, .height]
        border.frame = bounds
        addSubview(border)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setContent(_ view: NSView) {
        effect.subviews.forEach { $0.removeFromSuperview() }
        view.frame = effect.bounds
        view.autoresizingMask = [.width, .height]
        effect.addSubview(view)
        border.removeFromSuperview()
        addSubview(border)
    }

    static func mask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private final class HairlineBorderView: NSView {
    var radius: CGFloat = 0
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let scale = window?.backingScaleFactor ?? 2
        let w = 1 / scale
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: w / 2, dy: w / 2), xRadius: radius, yRadius: radius)
        path.lineWidth = w
        NSColor(Theme.Color.hairline).setStroke()
        path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func viewDidChangeBackingProperties() { needsDisplay = true }
}

/// Presents `CommentPanel` in `CapturePanelWindow`: centered over a frame, grows downward
/// with the text, fades in and out.
@MainActor
final class CapturePanelHost {
    let window = CapturePanelWindow()
    private let chrome = CapturePanelChrome()
    private var hosting: NSHostingView<CommentPanel>?
    private var dismissing = false

    static let fade: TimeInterval = 0.15

    init() {
        chrome.frame = window.contentLayoutRect
        window.contentView = chrome
    }

    var isVisible: Bool { window.isVisible && !dismissing }

    /// `over` is the frame to center on, in screen coordinates.
    func present(_ panel: CommentPanel, over frame: NSRect, level: NSWindow.Level) {
        var panel = panel
        panel.onHeightChange = { [weak self] h in self?.resize(to: h) }
        let hosting = NSHostingView(rootView: panel)
        hosting.sizingOptions = []
        self.hosting = hosting
        chrome.setContent(hosting)

        let height = max(hosting.fittingSize.height, 1)
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        var origin = NSPoint(x: frame.midX - CommentPanel.width / 2, y: frame.midY - height / 2)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - CommentPanel.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - height)
        }
        window.level = level
        window.setFrame(NSRect(origin: origin, size: NSSize(width: CommentPanel.width, height: height)), display: true)

        dismissing = false
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fade
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    /// Swaps in a panel with fresh inputs (e.g. completion candidates) without losing typed text.
    func update(_ panel: CommentPanel) {
        guard let hosting, !dismissing else { return }
        var panel = panel
        panel.onHeightChange = { [weak self] h in self?.resize(to: h) }
        hosting.rootView = panel
    }

    func dismiss(then completion: (() -> Void)? = nil) {
        guard window.isVisible, !dismissing else { completion?(); return }
        dismissing = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fade
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.dismissing else { return }
                self.window.orderOut(nil)
                self.chrome.effect.subviews.forEach { $0.removeFromSuperview() }
                self.hosting = nil
                self.dismissing = false
                completion?()
            }
        })
    }

    /// Keeps the top edge fixed so the panel grows downward as lines are added.
    private func resize(to height: CGFloat) {
        let h = ceil(height)
        guard h > 0, abs(window.frame.height - h) > 0.5 else { return }
        var f = window.frame
        f.origin.y += f.height - h
        f.size.height = h
        if let visible = window.screen?.visibleFrame, f.minY < visible.minY {
            f.origin.y = visible.minY
        }
        window.setFrame(f, display: true)
        window.invalidateShadow()
    }
}
