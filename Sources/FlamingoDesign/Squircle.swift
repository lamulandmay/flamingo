import SwiftUI
import AppKit

// MARK: - Geometry

/// Continuous-curvature rounded rectangles ("squircles"), built only from straight lines and
/// cubic Béziers. No circular arcs: an arc meets a straight edge with a jump in curvature,
/// and that jump is the visible kink in an ordinary rounded rectangle.
///
/// Each corner of radius `R` is two mirrored cubics. The first leaves the straight edge at
/// `1.528 R` from the corner's vertex with its first three control points on the edge line,
/// so curvature (and d²y/dx²) is exactly 0 where it joins the edge. It ends on the corner's
/// diagonal, tangent at 45°, at the same apex a circular corner of radius `R` would pass
/// through, so token radii keep their apparent size. The second cubic is its reflection
/// across the diagonal, so tangent and curvature agree at the apex (G2). Curvature rises
/// monotonically from 0 at the edge to its peak, `1.36 / R`, exactly at the apex.
///
/// Nested shapes are offsets, not shrunken copies: `offset` moves every edge and every
/// control polygon leg inward along its normal by the same distance (Tiller–Hanson), so the
/// gap is the same along the edges and across the diagonal, and the inner corner keeps zero
/// curvature at its edges and its tangent at 45° on the shared diagonal.
public enum SquircleGeometry {
    /// Where a corner leaves its straight edges, in radii from the vertex.
    public static let extent: CGFloat = 1.528
    /// The 45° apex's distance from the vertex along each edge, in radii: `1 − 1/√2`,
    /// where a circular corner of the same radius passes.
    public static let apex: CGFloat = 1 - 1 / 2.squareRoot()
    /// The inner control point on each edge, in radii. Between 1.071 and 1.387 curvature
    /// rises all the way to the apex (below, it peaks early and falls; above, it bulges);
    /// 1.08 is the softest apex inside that range.
    public static let handle: CGFloat = 1.08

    /// The largest radius `rect` can carry with straight edges left over on every side.
    public static func effectiveRadius(_ radius: CGFloat, in rect: CGRect) -> CGFloat {
        max(0, min(radius, min(rect.width, rect.height) / (2 * extent)))
    }

    /// The squircle of `radius` in `rect`, offset inward by `offset` along its normals
    /// (negative grows outward). Clockwise in a y-down space, starting on the top edge.
    public static func path(in rect: CGRect, radius: CGFloat, offset d: CGFloat = 0) -> CGPath {
        let path = CGMutablePath()
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0, radius.isFinite, d.isFinite,
              2 * d < min(rect.width, rect.height) else { return path }
        let r = effectiveRadius(radius, in: rect)
        // At an offset of one radius the inner corner has tightened to a point; beyond it
        // the nested shape is a plain rectangle.
        guard r > 0.01, d < r else {
            path.addRect(rect.insetBy(dx: d, dy: d))
            return path
        }
        let a = extent * r, s = apex * r, h = handle * r
        // Offsets of the three control-polygon legs, solved for these legs' directions:
        // along the edge the control points shift by `d`; the 45° leg meets the shifted
        // edge `d(√2 − 1)` further out; the apex moves `d/√2` along each axis.
        let tangent = 2 * s + d * (2.squareRoot() - 1)
        let tip = s + d / 2.squareRoot()

        // Each corner: vertex, unit vector along the edge we arrive on (pointing away from
        // the vertex), unit vector along the edge we leave on. The inside is toward u + w.
        let corners: [(v: CGPoint, u: CGVector, w: CGVector)] = [
            (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1)),
            (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0)),
            (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1)),
            (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0)),
        ]
        func point(_ c: (v: CGPoint, u: CGVector, w: CGVector), _ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(x: c.v.x + c.u.dx * along + c.w.dx * across, y: c.v.y + c.u.dy * along + c.w.dy * across)
        }
        // Start where the top-left corner hands over to the top edge.
        let last = corners[3]
        path.move(to: point(last, d, a))
        for c in corners {
            path.addLine(to: point(c, a, d))
            path.addCurve(to: point(c, tip, tip), control1: point(c, h, d), control2: point(c, tangent, d))
            path.addCurve(to: point(c, d, a), control1: point(c, d, tangent), control2: point(c, d, h))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - SwiftUI shapes

/// A rounded rectangle with continuous curvature. Use it for every rounded container in
/// place of `RoundedRectangle`. `inset(by:)` is a true normal offset, so `strokeBorder`
/// and nested fills stay concentric.
public struct Squircle: InsettableShape {
    public var radius: CGFloat
    var offset: CGFloat = 0

    public init(radius: CGFloat) { self.radius = radius }

    public func path(in rect: CGRect) -> Path {
        Path(SquircleGeometry.path(in: rect, radius: radius, offset: offset))
    }

    public func inset(by amount: CGFloat) -> Squircle {
        var shape = self; shape.offset += amount; return shape
    }
}

/// A shape laid out `padding` inside a parent squircle of `parentRadius`, drawn in its own
/// frame. Its corners are the parent's corners offset along their normals by `padding`, so
/// the gap between them is uniform along the edges and across the diagonal. A negative
/// padding gives a ring the same distance outside a child (a focus ring).
public struct ConcentricSquircle: InsettableShape {
    public var parentRadius: CGFloat
    public var padding: CGFloat
    var extra: CGFloat = 0

    public init(parentRadius: CGFloat, padding: CGFloat) {
        self.parentRadius = parentRadius; self.padding = padding
    }

    public func path(in rect: CGRect) -> Path {
        let parent = rect.insetBy(dx: -padding, dy: -padding)
        return Path(SquircleGeometry.path(in: parent, radius: parentRadius, offset: padding + extra))
    }

    public func inset(by amount: CGFloat) -> ConcentricSquircle {
        var shape = self; shape.extra += amount; return shape
    }
}

// MARK: - AppKit

extension NSBezierPath {
    /// The continuous-curvature rounded rectangle, for AppKit drawing.
    public convenience init(squircleIn rect: NSRect, radius: CGFloat, offset: CGFloat = 0) {
        self.init(cgPath: SquircleGeometry.path(in: rect, radius: radius, offset: offset))
    }
}

extension CALayer {
    /// Clips this layer to a squircle and, with `border`, strokes one inside its edge. Call
    /// again when the layer's bounds change.
    public func applySquircle(radius: CGFloat, border: NSColor? = nil, borderWidth: CGFloat = 1) {
        let mask = (self.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.frame = bounds
        mask.path = SquircleGeometry.path(in: bounds, radius: radius)
        self.mask = mask
        cornerRadius = 0
        self.borderWidth = 0
        let name = "flamingo.squircle.border"
        let stroke = sublayers?.first { $0.name == name } as? CAShapeLayer ?? {
            let layer = CAShapeLayer(); layer.name = name; addSublayer(layer); return layer
        }()
        stroke.isHidden = border == nil
        stroke.frame = bounds
        stroke.path = SquircleGeometry.path(in: bounds, radius: radius, offset: borderWidth / 2)
        stroke.fillColor = nil
        stroke.strokeColor = border?.cgColor
        stroke.lineWidth = borderWidth
    }
}
