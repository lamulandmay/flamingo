import AppKit

/// Floating panels arrive the way Spotlight's does: they fade in while their content grows
/// from 97% about its centre on a spring with a touch of overshoot. Leaving, they ease back
/// to 98% while the caller fades them. Reduce Motion keeps the fade and drops the growth.
@MainActor
public enum PanelMotion {
    /// Fades `window` in from transparent and grows its content into place.
    public static func arrive(_ window: NSWindow, fade: TimeInterval = Theme.Motion.fastSeconds) {
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = fade
            ctx.timingFunction = Theme.Motion.curve
            window.animator().alphaValue = 1
        }
        scale(window, from: 0.97, to: 1, bounce: 0.18)
    }

    /// The content's half of leaving: call alongside the caller's own fade out.
    public static func leave(_ window: NSWindow) {
        scale(window, from: 1, to: 0.98, bounce: 0)
    }

    private static func scale(_ window: NSWindow, from: CGFloat, to: CGFloat, bounce: CGFloat) {
        guard let view = window.contentView else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let b = view.bounds
        func centred(_ s: CGFloat) -> CATransform3D {
            var t = CATransform3DMakeTranslation(b.midX, b.midY, 0)
            t = CATransform3DScale(t, s, s, 1)
            return CATransform3DTranslate(t, -b.midX, -b.midY, 0)
        }
        guard !Theme.Motion.reduced else { layer.transform = CATransform3DIdentity; return }
        let anim = Theme.Motion.spring("transform", bounce: bounce, duration: 0.32)
        anim.fromValue = NSValue(caTransform3D: centred(from))
        anim.toValue = NSValue(caTransform3D: centred(to))
        // Rest at identity once arrived, so later layout never inherits a scale.
        layer.transform = to == 1 ? CATransform3DIdentity : centred(to)
        layer.add(anim, forKey: "flamingo.panel")
    }
}
