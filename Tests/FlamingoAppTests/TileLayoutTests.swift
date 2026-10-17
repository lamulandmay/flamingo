import XCTest
@testable import Flamingo

final class TileLayoutTests: XCTestCase {
    private let size = CGSize(width: 1000, height: 600)

    private func frames(_ layout: TileLayout, _ size: CGSize? = nil) -> [CGRect] {
        layout.frames(in: size ?? self.size, .defaults(for: layout))
    }

    func testEveryLayoutHasItsCountOfTilesInsideTheArea() {
        for layout in TileLayout.allCases {
            let rects = frames(layout)
            XCTAssertEqual(rects.count, layout.count, "\(layout)")
            for r in rects {
                XCTAssertGreaterThan(r.width, 0); XCTAssertGreaterThan(r.height, 0)
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(r), "\(layout) \(r)")
            }
        }
    }

    func testTilesNeverOverlapAndFillTheAreaLeavingOnlyHairlineGaps() {
        for layout in TileLayout.allCases {
            let rects = frames(layout)
            for (i, a) in rects.enumerated() {
                for b in rects[(i + 1)...] { XCTAssertTrue(a.intersection(b).isNull || a.intersection(b).isEmpty, "\(layout) \(a) \(b)") }
            }
            let covered = rects.reduce(0) { $0 + $1.width * $1.height }
            // What is not tile is gap lines: (columns - 1) tall ones and (rows - 1) wide ones, minus nothing twice.
            let gaps = layout.dividers(in: size, .defaults(for: layout)).reduce(0) { $0 + $1.rect.width * $1.rect.height }
            XCTAssertEqual(covered + gaps, size.width * size.height, accuracy: 1, "\(layout)")
        }
    }

    func testNeighbouringTilesAreExactlyOnePointApart() {
        let halves = frames(.halves)
        XCTAssertEqual(halves[1].minX - halves[0].maxX, 1)
        let thirds = frames(.thirds)
        XCTAssertEqual(thirds[1].minX - thirds[0].maxX, 1); XCTAssertEqual(thirds[2].minX - thirds[1].maxX, 1)
        let stack = frames(.mainPlusStack)
        XCTAssertEqual(stack[1].minX - stack[0].maxX, 1); XCTAssertEqual(stack[2].minY - stack[1].maxY, 1)
        XCTAssertEqual(stack[0].height, 600); XCTAssertEqual(stack[1].minX, stack[2].minX)
        let grid = frames(.grid)
        XCTAssertEqual(grid[1].minX - grid[0].maxX, 1); XCTAssertEqual(grid[2].minY - grid[0].maxY, 1)
        XCTAssertEqual(grid[3].minX, grid[1].minX); XCTAssertEqual(grid[3].minY, grid[2].minY)
    }

    func testDividersSitInTheGaps() {
        for layout in TileLayout.allCases {
            let rects = frames(layout)
            for d in layout.dividers(in: size, .defaults(for: layout)) {
                XCTAssertTrue(d.rect.width == 1 || d.rect.height == 1)
                for r in rects { XCTAssertTrue(r.intersection(d.rect).isNull || r.intersection(d.rect).isEmpty, "\(layout) \(d)") }
            }
        }
        XCTAssertTrue(TileLayout.single.dividers(in: size, .defaults(for: .single)).isEmpty)
        XCTAssertEqual(TileLayout.thirds.dividers(in: size, .defaults(for: .thirds)).count, 2)
        XCTAssertEqual(TileLayout.grid.dividers(in: size, .defaults(for: .grid)).count, 2)
    }

    func testFractionsMoveTheLine() {
        var f = TileFractions.defaults(for: .halves)
        f.columns = [0.3]
        let r = TileLayout.halves.frames(in: size, f)
        XCTAssertEqual(r[0].width, (0.3 * 999).rounded())
        XCTAssertEqual(r[0].width + 1 + r[1].width, 1000)
    }

    func testClampingKeepsTilesAtTheirMinimumSizes() {
        var f = TileFractions.defaults(for: .halves)
        f.columns = [0.05]
        let c = f.clamped(.halves, size: size)
        XCTAssertGreaterThanOrEqual(c.columns[0] * 999, 220)
        f.columns = [0.99]
        XCTAssertLessThanOrEqual(f.clamped(.halves, size: size).columns[0] * 999, 999 - 220)
        var grid = TileFractions.defaults(for: .grid)
        grid.rows = [0.9]
        XCTAssertLessThanOrEqual(grid.clamped(.grid, size: size).rows[0] * 599, 599 - 160)
        var thirds = TileFractions.defaults(for: .thirds)
        thirds.columns = [0.1, 0.2]
        let t = thirds.clamped(.thirds, size: size).columns
        XCTAssertGreaterThanOrEqual(t[0] * 998, 220); XCTAssertGreaterThanOrEqual((t[1] - t[0]) * 998, 220); XCTAssertGreaterThanOrEqual((1 - t[1]) * 998, 220)
    }

    func testANarrowWidthFallsBackToEqualShares() {
        var f = TileFractions.defaults(for: .thirds)
        f.columns = [0.2, 0.9]
        let c = f.clamped(.thirds, size: CGSize(width: 500, height: 600))
        XCTAssertEqual(c.columns[0], 1.0 / 3, accuracy: 1e-9); XCTAssertEqual(c.columns[1], 2.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(TileFractions(columns: [], rows: []).clamped(.halves, size: size).columns, [0.5], "missing values repair to equal shares")
    }

    func testCollapseMap() {
        XCTAssertEqual(TileLayout.grid.collapsed, .mainPlusStack)
        XCTAssertEqual(TileLayout.mainPlusStack.collapsed, .halves)
        XCTAssertEqual(TileLayout.thirds.collapsed, .halves)
        XCTAssertEqual(TileLayout.halves.collapsed, .single)
        XCTAssertEqual(TileLayout.single.collapsed, .single)
    }

    func testGrowingKeepsVisiblePanesAndRevealsTheNextOnes() {
        let single = TileArrangement()
        let (halves, r1) = single.resized(to: .halves, keeping: .primary)
        XCTAssertEqual(halves.visible, [.primary, .secondary]); XCTAssertEqual(r1, [.secondary])
        let (grid, r2) = halves.resized(to: .grid, keeping: .secondary)
        XCTAssertEqual(grid.visible, [.primary, .secondary, .third, .fourth]); XCTAssertEqual(r2, [.third, .fourth])
        let (sameCount, r3) = (try! XCTUnwrap(TileArrangement(kind: .thirds).resized(to: .mainPlusStack, keeping: .primary) as (TileArrangement, [DocumentPaneID])?))
        XCTAssertEqual(sameCount.visible, [.primary, .secondary, .third]); XCTAssertTrue(r3.isEmpty)
    }

    func testShrinkingKeepsTheClickedPaneAndTheEarlierOnes() {
        let grid = TileArrangement(kind: .grid)
        let (halves, revealed) = grid.resized(to: .halves, keeping: .fourth)
        XCTAssertEqual(halves.visible, [.primary, .fourth], "grid [P,S,T,F] shrunk to halves from F")
        XCTAssertTrue(revealed.isEmpty)
        XCTAssertEqual(Set(halves.order), Set(DocumentPaneID.allCases)); XCTAssertEqual(halves.order.count, 4)
        XCTAssertEqual(grid.resized(to: .single, keeping: .third).0.visible, [.third])
        XCTAssertEqual(grid.resized(to: .thirds, keeping: .secondary).0.visible, [.primary, .secondary, .third])
        XCTAssertEqual(TileArrangement(kind: .thirds, order: [.third, .primary, .fourth, .secondary]).resized(to: .halves, keeping: .fourth).0.visible, [.third, .fourth])
    }

    func testHiddenPanesComeBackInTheirSlots() {
        let (single, _) = TileArrangement(kind: .halves).resized(to: .single, keeping: .primary)
        XCTAssertEqual(single.visible, [.primary])
        XCTAssertEqual(single.resized(to: .halves, keeping: .primary).0.visible, [.primary, .secondary])
    }

    func testClosingCollapsesAndPicksTheSuccessor() throws {
        let thirds = TileArrangement(kind: .thirds)
        let middle = try XCTUnwrap(thirds.closing(.secondary))
        XCTAssertEqual(middle.0.kind, .halves); XCTAssertEqual(middle.0.visible, [.primary, .third]); XCTAssertEqual(middle.successor, .primary)
        XCTAssertEqual(middle.0.order.last, .secondary)
        let first = try XCTUnwrap(thirds.closing(.primary))
        XCTAssertEqual(first.0.visible, [.secondary, .third]); XCTAssertEqual(first.successor, .secondary, "the new first slot when the first closes")
        let last = try XCTUnwrap(thirds.closing(.third))
        XCTAssertEqual(last.successor, .secondary)
        let grid = try XCTUnwrap(TileArrangement(kind: .grid).closing(.fourth))
        XCTAssertEqual(grid.0.kind, .mainPlusStack); XCTAssertEqual(grid.0.visible, [.primary, .secondary, .third])
        XCTAssertEqual(try XCTUnwrap(TileArrangement(kind: .halves).closing(.secondary)).0.kind, .single)
        XCTAssertNil(TileArrangement().closing(.primary))
        XCTAssertNil(thirds.closing(.fourth), "a hidden pane has nothing to close")
    }

    func testNeighbourCyclingWraps() {
        let thirds = TileArrangement(kind: .thirds)
        XCTAssertEqual(thirds.neighbor(of: .primary, step: 1), .secondary)
        XCTAssertEqual(thirds.neighbor(of: .third, step: 1), .primary)
        XCTAssertEqual(thirds.neighbor(of: .primary, step: -1), .third)
        XCTAssertEqual(thirds.neighbor(of: .secondary, step: -2), .third)
        XCTAssertEqual(thirds.neighbor(of: .secondary, step: -4), .primary)
        XCTAssertEqual(TileArrangement().neighbor(of: .primary, step: 1), .primary)
    }

    func testRepairedArrangementIsAlwaysAPermutation() {
        let broken = TileArrangement(kind: .halves, order: [.third, .third, .primary])
        XCTAssertEqual(broken.repaired().order, [.third, .primary, .secondary, .fourth])
        XCTAssertEqual(TileArrangement(kind: .grid, order: []).repaired().order, DocumentPaneID.allCases)
    }

    func testArrangementRoundTripsThroughJSON() throws {
        let a = TileArrangement(kind: .mainPlusStack, order: [.third, .primary, .fourth, .secondary])
        XCTAssertEqual(try JSONDecoder().decode(TileArrangement.self, from: JSONEncoder().encode(a)), a)
    }
}
