import XCTest
import CoreGraphics
import FlamingoDesign

/// The continuous-curvature corner every rounded shape uses (`FlamingoDesign/Squircle.swift`).
/// Here because this target already links FlamingoDesign.
final class SquircleTests: XCTestCase {
    private struct Cubic { var p0, p1, p2, p3: CGPoint }

    private func elements(_ path: CGPath) -> (cubics: [Cubic], lines: Int, moves: Int) {
        var cubics: [Cubic] = [], lines = 0, moves = 0, current = CGPoint.zero
        path.applyWithBlock { e in
            let pts = e.pointee.points
            switch e.pointee.type {
            case .moveToPoint: current = pts[0]; moves += 1
            case .addLineToPoint: current = pts[0]; lines += 1
            case .addCurveToPoint:
                cubics.append(Cubic(p0: current, p1: pts[0], p2: pts[1], p3: pts[2])); current = pts[2]
            default: break
            }
        }
        return (cubics, lines, moves)
    }

    private func point(_ c: Cubic, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, d = 3 * u * t * t, e = t * t * t
        return CGPoint(x: a * c.p0.x + b * c.p1.x + d * c.p2.x + e * c.p3.x, y: a * c.p0.y + b * c.p1.y + d * c.p2.y + e * c.p3.y)
    }

    private func curvature(_ c: Cubic, _ t: CGFloat) -> CGFloat {
        let u = 1 - t
        let dx = 3 * u * u * (c.p1.x - c.p0.x) + 6 * u * t * (c.p2.x - c.p1.x) + 3 * t * t * (c.p3.x - c.p2.x)
        let dy = 3 * u * u * (c.p1.y - c.p0.y) + 6 * u * t * (c.p2.y - c.p1.y) + 3 * t * t * (c.p3.y - c.p2.y)
        let ddx = 6 * u * (c.p2.x - 2 * c.p1.x + c.p0.x) + 6 * t * (c.p3.x - 2 * c.p2.x + c.p1.x)
        let ddy = 6 * u * (c.p2.y - 2 * c.p1.y + c.p0.y) + 6 * t * (c.p3.y - 2 * c.p2.y + c.p1.y)
        return abs(dx * ddy - dy * ddx) / pow(dx * dx + dy * dy, 1.5)
    }

    func testCornersAreTwoCubicsWithZeroCurvatureAtTheEdgesAndG2AtTheApex() {
        let rect = CGRect(x: 10, y: 20, width: 300, height: 200), r: CGFloat = 40
        let (cubics, lines, moves) = elements(SquircleGeometry.path(in: rect, radius: r))
        XCTAssertEqual(moves, 1); XCTAssertEqual(lines, 4); XCTAssertEqual(cubics.count, 8, "two cubics per corner, no arcs")
        // Top-right corner: arrives on the top edge.
        let first = cubics[0], second = cubics[1]
        XCTAssertEqual(first.p0.x, rect.maxX - SquircleGeometry.extent * r, accuracy: 1e-9, "leaves the edge at 1.528 R")
        for p in [first.p0, first.p1, first.p2] { XCTAssertEqual(p.y, rect.minY, accuracy: 1e-9) }
        XCTAssertEqual(curvature(first, 0), 0, accuracy: 1e-9, "flat where it meets the edge")
        // Apex on the diagonal, tangent at 45°, where a circular corner of the same radius passes.
        XCTAssertEqual(rect.maxX - first.p3.x, first.p3.y - rect.minY, accuracy: 1e-9)
        XCTAssertEqual(rect.maxX - first.p3.x, r * (1 - 1 / 2.squareRoot()), accuracy: 1e-9)
        XCTAssertEqual(abs(first.p3.x - first.p2.x), abs(first.p3.y - first.p2.y), accuracy: 1e-9)
        XCTAssertEqual(curvature(first, 1), curvature(second, 0), accuracy: 1e-9, "curvature continuous at the apex")
        XCTAssertEqual(curvature(second, 1), 0, accuracy: 1e-9)
        // Curvature only rises from the edge to the apex.
        var last: CGFloat = -1
        for i in 0...40 { let k = curvature(first, CGFloat(i) / 40); XCTAssertGreaterThanOrEqual(k, last - 1e-9); last = k }
    }

    func testNestedShapesAreTrueOffsets() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 260), r: CGFloat = 60, d: CGFloat = 18
        let outer = elements(SquircleGeometry.path(in: rect, radius: r)).cubics
        let inner = elements(SquircleGeometry.path(in: rect, radius: r, offset: d)).cubics
        let outerSamples = outer.flatMap { c in (0...200).map { point(c, CGFloat($0) / 200) } }
        for c in inner {
            for i in 0...20 {
                let p = point(c, CGFloat(i) / 20)
                let gap = outerSamples.map { hypot($0.x - p.x, $0.y - p.y) }.min() ?? 0
                XCTAssertEqual(gap, d, accuracy: 0.02 * r, "uniform gap along edges and across the corner")
            }
        }
        // Still flat where the inner corner meets its edge, still 45° on the shared diagonal.
        XCTAssertEqual(inner[0].p1.y, d, accuracy: 1e-9); XCTAssertEqual(inner[0].p2.y, d, accuracy: 1e-9)
        XCTAssertEqual(rect.maxX - inner[0].p3.x, inner[0].p3.y, accuracy: 1e-9)
        // A concentric child laid out with that padding draws the same curve in its own frame.
        let child = ConcentricSquircle(parentRadius: r, padding: d).path(in: rect.insetBy(dx: d, dy: d)).cgPath
        let a = elements(child).cubics[0], b = inner[0]
        XCTAssertEqual(a.p3.x, b.p3.x, accuracy: 1e-9); XCTAssertEqual(a.p3.y, b.p3.y, accuracy: 1e-9)
    }

    func testDegenerateSizesStayValid() {
        let rect = CGRect(x: 0, y: 0, width: 40, height: 20)
        XCTAssertEqual(SquircleGeometry.effectiveRadius(100, in: rect), 20 / (2 * SquircleGeometry.extent), accuracy: 1e-9)
        XCTAssertEqual(elements(SquircleGeometry.path(in: rect, radius: 4, offset: 6)).cubics.count, 0, "past the radius the corner is sharp")
        XCTAssertTrue(SquircleGeometry.path(in: rect, radius: 4, offset: 10).isEmpty)
        XCTAssertTrue(SquircleGeometry.path(in: .zero, radius: 4).isEmpty)
    }
}
