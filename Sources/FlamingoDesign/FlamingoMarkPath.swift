import CoreGraphics

/// The Flamingo mark as plain CoreGraphics so `Resources/Assets/make-icon.swift` can
/// compile this file alongside itself and draw the exact same geometry as the app.
///
/// A flamingo standing on one leg, facing right: a tapered S-curved neck, the bent beak
/// with its dark tip, an egg-shaped body, one straight leg and one folded into a "4".
public enum FlamingoMarkPath {
    /// The whole mark, one solid silhouette, centered in `rect` and as large as fits.
    /// `flipped: true` for y-up contexts (raw CoreGraphics).
    public static func path(in rect: CGRect, flipped: Bool) -> CGPath {
        fit(silhouette, in: rect, flipped: flipped)
    }

    /// The bird without the beak tip, for two-tone rendering. Same placement as `path`.
    public static func bird(in rect: CGRect, flipped: Bool) -> CGPath {
        fit(silhouette.subtracting(beakTip), in: rect, flipped: flipped)
    }

    /// Just the dark tip of the beak. Same placement as `path`.
    public static func tip(in rect: CGRect, flipped: Bool) -> CGPath {
        fit(silhouette.intersection(beakTip), in: rect, flipped: flipped)
    }

    // MARK: Geometry, in a 100×100 design box, y down

    static let legWidth: CGFloat = 2.6

    static let silhouette: CGPath = {
        var shape = body
        shape = shape.union(neck)
        shape = shape.union(head)
        shape = shape.union(beak)
        shape = shape.union(legs.copy(strokingWithWidth: legWidth, lineCap: .round, lineJoin: .round, miterLimit: 4))
        return shape
    }()

    static var body: CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 58, y: 48.4))
        // chest, wrapping the base of the neck
        p.addCurve(to: CGPoint(x: 68, y: 66), control1: CGPoint(x: 71.6, y: 47.2), control2: CGPoint(x: 75.6, y: 58))
        // belly, running out into a short drooping tail
        p.addCurve(to: CGPoint(x: 22.5, y: 66.6), control1: CGPoint(x: 60, y: 73.6), control2: CGPoint(x: 38, y: 76))
        // back, up to the shoulder
        p.addCurve(to: CGPoint(x: 58, y: 48.4), control1: CGPoint(x: 31, y: 55), control2: CGPoint(x: 45, y: 47.4))
        p.closeSubpath()
        return p
    }

    /// Thick where it leaves the chest, slender under the head.
    static var neck: CGPath {
        taper([
            (CGPoint(x: 64, y: 58), CGPoint(x: 69.5, y: 45), CGPoint(x: 50, y: 44), CGPoint(x: 50, y: 32)),
            (CGPoint(x: 50, y: 32), CGPoint(x: 50, y: 22), CGPoint(x: 55, y: 16), CGPoint(x: 59.5, y: 14)),
        ], from: 7.6, to: 4.4)
    }

    static var head: CGPath {
        CGPath(ellipseIn: CGRect(x: 54.5, y: 6.5, width: 11, height: 11), transform: nil)
    }

    static var beak: CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 59, y: 6.7))
        // upper mandible, nearly straight
        p.addCurve(to: CGPoint(x: 71, y: 9.6), control1: CGPoint(x: 63.5, y: 6.1), control2: CGPoint(x: 68, y: 6.9))
        // the bend, down to the tip
        p.addCurve(to: CGPoint(x: 73.4, y: 22), control1: CGPoint(x: 74.6, y: 12.6), control2: CGPoint(x: 75.2, y: 18.4))
        // inside of the tip, back up to the bend
        p.addCurve(to: CGPoint(x: 70.2, y: 15.4), control1: CGPoint(x: 71.8, y: 19.8), control2: CGPoint(x: 71.2, y: 16.8))
        // underside, back to the throat
        p.addCurve(to: CGPoint(x: 61, y: 17.4), control1: CGPoint(x: 67.6, y: 14), control2: CGPoint(x: 64, y: 16.6))
        p.closeSubpath()
        return p
    }

    /// Everything of the beak past the bend.
    static var beakTip: CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 71.6, y: 6))
        p.addLine(to: CGPoint(x: 82, y: 12))
        p.addLine(to: CGPoint(x: 82, y: 30))
        p.addLine(to: CGPoint(x: 66, y: 30))
        p.addLine(to: CGPoint(x: 69.4, y: 15))
        p.closeSubpath()
        return p
    }

    static var legs: CGPath {
        let p = CGMutablePath()
        // standing leg
        p.move(to: CGPoint(x: 48, y: 70))
        p.addLine(to: CGPoint(x: 48, y: 95))
        // folded leg: down and forward to the joint, back to the standing leg
        p.move(to: CGPoint(x: 52, y: 70))
        p.addLine(to: CGPoint(x: 59, y: 80))
        p.addLine(to: CGPoint(x: 48, y: 84))
        return p
    }

    // MARK: Helpers

    typealias Cubic = (CGPoint, CGPoint, CGPoint, CGPoint)

    /// A filled outline around a chain of cubics whose width goes linearly from `w0` to `w1`.
    static func taper(_ segments: [Cubic], from w0: CGFloat, to w1: CGFloat) -> CGPath {
        let steps = 48
        var center: [(CGPoint, CGPoint)] = []   // point, unit tangent
        for (i, c) in segments.enumerated() {
            for k in (i == 0 ? 0 : 1)...steps {
                let t = CGFloat(k) / CGFloat(steps)
                center.append((cubic(c, t), unit(cubicTangent(c, t))))
            }
        }
        var left: [CGPoint] = [], right: [CGPoint] = []
        for (i, (pt, tan)) in center.enumerated() {
            let w = (w0 + (w1 - w0) * CGFloat(i) / CGFloat(center.count - 1)) / 2
            let n = CGPoint(x: -tan.y, y: tan.x)
            left.append(CGPoint(x: pt.x + n.x * w, y: pt.y + n.y * w))
            right.append(CGPoint(x: pt.x - n.x * w, y: pt.y - n.y * w))
        }
        let p = CGMutablePath()
        p.addLines(between: left + right.reversed())
        p.closeSubpath()
        // Round both ends so the joins into body and head stay smooth.
        p.addEllipse(in: CGRect(x: center[0].0.x - w0 / 2, y: center[0].0.y - w0 / 2, width: w0, height: w0))
        let e = center[center.count - 1].0
        p.addEllipse(in: CGRect(x: e.x - w1 / 2, y: e.y - w1 / 2, width: w1, height: w1))
        return p.normalized()
    }

    static func cubic(_ c: Cubic, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, d = 3 * u * t * t, e = t * t * t
        return CGPoint(x: a * c.0.x + b * c.1.x + d * c.2.x + e * c.3.x,
                       y: a * c.0.y + b * c.1.y + d * c.2.y + e * c.3.y)
    }

    static func cubicTangent(_ c: Cubic, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = 3 * u * u, b = 6 * u * t, d = 3 * t * t
        return CGPoint(x: a * (c.1.x - c.0.x) + b * (c.2.x - c.1.x) + d * (c.3.x - c.2.x),
                       y: a * (c.1.y - c.0.y) + b * (c.2.y - c.1.y) + d * (c.3.y - c.2.y))
    }

    static func unit(_ v: CGPoint) -> CGPoint {
        let l = max((v.x * v.x + v.y * v.y).squareRoot(), 0.0001)
        return CGPoint(x: v.x / l, y: v.y / l)
    }

    /// Scale the silhouette's bounds to fit `rect`, centered. Parts placed with the same transform.
    static func fit(_ p: CGPath, in rect: CGRect, flipped: Bool) -> CGPath {
        let bb = silhouette.boundingBoxOfPath
        let s = min(rect.width / bb.width, rect.height / bb.height)
        let ox = rect.midX - bb.midX * s
        var t: CGAffineTransform
        if flipped {
            t = CGAffineTransform(translationX: ox, y: rect.midY + bb.midY * s).scaledBy(x: s, y: -s)
        } else {
            t = CGAffineTransform(translationX: ox, y: rect.midY - bb.midY * s).scaledBy(x: s, y: s)
        }
        return p.copy(using: &t) ?? p
    }
}
