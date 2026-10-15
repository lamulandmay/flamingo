import AppKit
import SwiftUI
import FlamingoDesign

/// Two-finger swipes go back and forward through history, tracked like Safari: the content
/// follows the fingers a little, an edge chevron fills in, and letting go past the threshold
/// commits with a haptic tap. Three-finger swipes (when macOS is set that way) commit at once.
/// Horizontal scrollers and the graph canvas keep their own scroll gestures.
@MainActor
final class SwipeNavigator {
    private unowned let state: AppState
    private weak var window: NSWindow?
    private var monitor: Any?
    private var tracking = false

    init(state: AppState, window: NSWindow) {
        self.state = state
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? event }
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    private func handle(_ e: NSEvent) -> NSEvent? {
        guard let window, e.window === window else { return e }
        if e.type == .swipe {
            if e.deltaX > 0, state.canGoBack { commit(back: true) }
            else if e.deltaX < 0, state.canGoForward { commit(back: false) }
            return nil
        }
        guard NSEvent.isSwipeTrackingFromScrollEventsEnabled, !tracking, e.phase == .began,
              abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY),
              !ownsHorizontalScrolling(at: e.locationInWindow, in: window) else { return e }
        let canBack = state.canGoBack, canForward = state.canGoForward
        guard canBack || canForward else { return e }
        tracking = true
        e.trackSwipeEvent(options: [.lockDirection],
                          dampenAmountThresholdMin: canForward ? -1 : 0,
                          max: canBack ? 1 : 0) { [weak self] amount, phase, complete, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch phase {
                case .ended, .cancelled:
                    self.tracking = false
                    if complete, phase == .ended { self.commit(back: amount > 0) }
                    withAnimation(Theme.Motion.normal) { self.state.swipeAmount = 0 }
                default:
                    self.state.swipeAmount = amount
                }
            }
        }
        return nil
    }

    private func commit(back: Bool) {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        if back { state.goBack() } else { state.goForward() }
    }

    /// True when the view under the pointer scrolls sideways itself (a wide timeline, the graph).
    private func ownsHorizontalScrolling(at point: NSPoint, in window: NSWindow) -> Bool {
        var view = window.contentView?.hitTest(point)
        while let v = view {
            if String(describing: type(of: v)).hasPrefix("GraphInput") { return true }
            if let scroll = v as? NSScrollView, let doc = scroll.documentView,
               doc.frame.width > scroll.contentSize.width + 1 { return true }
            view = v.superview
        }
        return false
    }
}

/// The edge indicator while swiping: a small disc with a chevron that slides in and fills
/// with accent once the swipe will commit.
struct SwipeChevron: View {
    var amount: CGFloat
    var back: Bool

    var body: some View {
        let active = back ? amount > 0 : amount < 0
        let m = min(1, abs(amount))
        let ready = m >= 0.999
        ZStack {
            Circle().fill(Theme.Color.bgRaised)
            Circle().strokeBorder(Theme.Color.hairline, lineWidth: 1)
            Image(systemName: back ? "chevron.left" : "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ready ? Theme.Color.accent : Theme.Color.textSecondary)
        }
        .frame(width: 30, height: 30)
        .scaleEffect(0.7 + 0.3 * m)
        .opacity(active ? Double(m) : 0)
        .offset(x: (back ? 1 : -1) * (m * 36 - 20))
        .animation(Theme.Motion.fast, value: ready)
        .allowsHitTesting(false)
    }
}
