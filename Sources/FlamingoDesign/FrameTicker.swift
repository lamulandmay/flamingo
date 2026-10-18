import AppKit
import QuartzCore

/// Calls `tick` once per frame of the display a window or view is on: 120 times a second on
/// a ProMotion panel, in step with what it draws. The display link exists only between
/// `start` and `stop`, so nothing wakes the app while nothing moves. For work that has to
/// follow the screen (a pointer, a hand-driven animation); a fixed-rate `Timer` drifts
/// against the display and runs at 60 on a 120 Hz panel.
@MainActor
public final class FrameTicker: NSObject {
    /// Up to the panel's top rate; never asks for fewer than 60 frames a second.
    public static let fullRate = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)

    private var link: CADisplayLink?
    private let tick: @MainActor (CADisplayLink) -> Void

    public init(_ tick: @escaping @MainActor (CADisplayLink) -> Void) {
        self.tick = tick
    }

    public var isRunning: Bool { link != nil }

    /// Ticks on the display `window` is on, following it to another one. No-op if running.
    public func start(on window: NSWindow) {
        guard link == nil else { return }
        install(window.displayLink(target: self, selector: #selector(frame(_:))))
    }

    /// Ticks on the display `view`'s window is on. No-op if running.
    public func start(on view: NSView) {
        guard link == nil else { return }
        install(view.displayLink(target: self, selector: #selector(frame(_:))))
    }

    /// Releases the link (which holds the ticker), so call it when the motion ends.
    public func stop() {
        link?.invalidate()
        link = nil
    }

    private func install(_ link: CADisplayLink) {
        link.preferredFrameRateRange = Self.fullRate
        // Common modes: frames keep coming while a menu tracks or a scroll is live.
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func frame(_ link: CADisplayLink) { tick(link) }
}
