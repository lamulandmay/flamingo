import XCTest
@testable import Flamingo

final class RadialHoldMachineTests: XCTestCase {
    typealias M = RadialHoldMachine
    private let both: M.Modifiers = [.command, .option]

    /// A machine that has seen ⌘ then ⌥ and been ticked open with `count` files.
    private func opened(count: Int = 8, at t: TimeInterval = 0) -> M {
        var m = M()
        _ = m.handle(.flags([.command], buttonsDown: false, eligible: true), now: t)
        _ = m.handle(.flags(both, buttonsDown: false, eligible: true), now: t)
        _ = m.handle(.tick(itemCount: count), now: t + 0.3)
        return m
    }

    private func offset(_ degrees: Double, _ distance: Double = 80) -> CGVector {
        let r = degrees * .pi / 180
        return CGVector(dx: distance * sin(r), dy: -distance * cos(r))
    }

    private func highlight(_ m: inout M, _ degrees: Double, distance: Double = 80) -> Int? {
        _ = m.handle(.pointer(offset(degrees, distance)), now: 1)
        return m.highlighted
    }

    func testArmsOnlyOnExactCommandOptionReachedFromFewer() {
        var m = M()
        XCTAssertEqual(m.handle(.flags([.command], buttonsDown: false, eligible: true), now: 0).effects, [])
        let r = m.handle(.flags(both, buttonsDown: false, eligible: true), now: 0.1)
        XCTAssertEqual(r.effects, [.schedule(0.30)])
        XCTAssertTrue(r.passThrough, "flagsChanged is never consumed")
        XCTAssertEqual(m.phase, .armed)

        // ⌘⌥⇧ → ⌘⌥ doesn't count.
        var n = M()
        _ = n.handle(.flags([.command, .option, .shift], buttonsDown: false, eligible: true), now: 0)
        XCTAssertEqual(n.handle(.flags(both, buttonsDown: false, eligible: true), now: 0.1).effects, [])
        XCTAssertEqual(n.phase, .idle)

        // ⌘⌥⌃ is not exactly ⌘⌥.
        var o = M()
        XCTAssertEqual(o.handle(.flags([.command, .option, .control], buttonsDown: false, eligible: true), now: 0).effects, [])
    }

    func testNeverArmsWithAMouseButtonDownOrWhenIneligible() {
        var m = M()
        _ = m.handle(.flags([.command], buttonsDown: true, eligible: true), now: 0)
        XCTAssertEqual(m.handle(.flags(both, buttonsDown: true, eligible: true), now: 0.1).effects, [])
        var n = M()
        _ = n.handle(.flags([.command], buttonsDown: false, eligible: false), now: 0)
        XCTAssertEqual(n.handle(.flags(both, buttonsDown: false, eligible: false), now: 0.1).effects, [])
        XCTAssertEqual(n.phase, .idle)
    }

    func testKeyMouseScrollAndFlagsCancelWhileArmedAndPassThrough() {
        let cases: [(M.Input, String)] = [
            (.keyDown(34), "key"), (.keyDown(53), "key"), (.mouseDown, "mouse"), (.scroll, "scroll"),
            (.flags([.command, .option, .shift], buttonsDown: false, eligible: true), "flags"),
            (.flags([.command], buttonsDown: false, eligible: true), "flags"),
        ]
        for (input, reason) in cases {
            var m = M()
            _ = m.handle(.flags([.command], buttonsDown: false, eligible: true), now: 0)
            _ = m.handle(.flags(both, buttonsDown: false, eligible: true), now: 0)
            let r = m.handle(input, now: 0.1)
            XCTAssertEqual(r.effects, [.disarm(reason: reason)])
            XCTAssertTrue(r.passThrough, "\(input) must reach the app")
            XCTAssertEqual(m.phase, .idle)
            XCTAssertEqual(m.handle(.tick(itemCount: 8), now: 0.3).effects, [], "a stale timer does nothing")
        }
    }

    func testTickAfterHoldDelayOpens() {
        var m = M()
        _ = m.handle(.flags([.command], buttonsDown: false, eligible: true), now: 0)
        _ = m.handle(.flags(both, buttonsDown: false, eligible: true), now: 0)
        let r = m.handle(.tick(itemCount: 8), now: 0.3)
        XCTAssertEqual(r.effects, [.present])
        XCTAssertEqual(m.phase, .open)
        XCTAssertEqual(m.slotCount, 8)
    }

    func testTickWithNoFilesOrTooEarlyDoesNotOpen() {
        var m = M()
        _ = m.handle(.flags([.command], buttonsDown: false, eligible: true), now: 0)
        _ = m.handle(.flags(both, buttonsDown: false, eligible: true), now: 0)
        XCTAssertEqual(m.handle(.tick(itemCount: 0), now: 0.3).effects, [.disarm(reason: "empty")])
        XCTAssertEqual(m.phase, .idle)
        var n = M()
        _ = n.handle(.flags([.command], buttonsDown: false, eligible: true), now: 0)
        _ = n.handle(.flags(both, buttonsDown: false, eligible: true), now: 0)
        XCTAssertEqual(n.handle(.tick(itemCount: 3), now: 0.1).effects, [.disarm(reason: "flags")])
    }

    func testEightSlotsClockwiseFromTwelve() {
        var m = opened(count: 8)
        for slot in 0..<8 { XCTAssertEqual(highlight(&m, Double(slot) * 45), slot, "slot \(slot)") }
        XCTAssertEqual(highlight(&m, 350), 0, "just left of 12 o'clock is still slot 0")
        XCTAssertEqual(highlight(&m, 100), 2)
    }

    func testFourCompassSlotsWhenFourOrFewerFiles() {
        var m = opened(count: 4)
        XCTAssertEqual(m.slotCount, 4)
        XCTAssertEqual(highlight(&m, 0), 0)
        XCTAssertEqual(highlight(&m, 80), 1)
        XCTAssertEqual(highlight(&m, 200), 2)
        XCTAssertEqual(highlight(&m, 300), 3)
        // With two files, the empty compass slots highlight nothing.
        var two = opened(count: 2)
        XCTAssertEqual(two.slotCount, 4)
        XCTAssertEqual(highlight(&two, 0), 0)
        XCTAssertEqual(highlight(&two, 90), 1)
        XCTAssertNil(highlight(&two, 180))
    }

    func testEmptySlotsInEightSlotModeHighlightNothing() {
        var m = opened(count: 5)
        XCTAssertEqual(m.slotCount, 8)
        XCTAssertEqual(highlight(&m, 180), 4)
        XCTAssertNil(highlight(&m, 270))
    }

    func testDeadZone() {
        var m = opened()
        XCTAssertEqual(highlight(&m, 90), 2)
        XCTAssertNil(highlight(&m, 90, distance: 27))
        XCTAssertEqual(highlight(&m, 90, distance: 29), 2)
        XCTAssertNil(highlight(&m, 0, distance: 0))
    }

    func testHysteresisHoldsAtSlotEdges() {
        var m = opened()
        XCTAssertEqual(highlight(&m, 10), 0)
        // The edge between 0 and 1 is 22.5 degrees: held up to 4 degrees past it.
        XCTAssertEqual(highlight(&m, 22.5 + 3), 0)
        XCTAssertEqual(highlight(&m, 22.5 + 5), 1)
        XCTAssertEqual(highlight(&m, 22.5 - 3), 1)
        XCTAssertEqual(highlight(&m, 22.5 - 5), 0)
        // And across 12 o'clock.
        XCTAssertEqual(highlight(&m, 360 - 22.5 + 3), 0)
        XCTAssertEqual(highlight(&m, 360 - 22.5 - 5), 7)
    }

    func testPointerEmitsHighlightEffectsOnlyOnChange() {
        var m = opened()
        XCTAssertEqual(m.handle(.pointer(offset(90)), now: 1).effects, [.highlight(2)])
        XCTAssertEqual(m.handle(.pointer(offset(92)), now: 1).effects, [])
        XCTAssertEqual(m.handle(.pointer(offset(90, 5)), now: 1).effects, [.highlight(nil)])
    }

    func testReleasingInASlotCommitsAndInTheDeadZoneCloses() {
        for released: M.Modifiers in [[.option], [.command], []] {
            var m = opened()
            _ = m.handle(.pointer(offset(135)), now: 1)
            let r = m.handle(.flags(released, buttonsDown: false, eligible: true), now: 2)
            XCTAssertEqual(r.effects, [.commit(3)])
            XCTAssertTrue(r.passThrough)
            XCTAssertEqual(m.phase, .idle)
        }
        var m = opened()
        XCTAssertEqual(m.handle(.flags([.option], buttonsDown: false, eligible: true), now: 2).effects,
                       [.dismiss(animated: true, reason: "released")])
    }

    func testAddingAModifierWhileOpenKeepsTheRingOpen() {
        var m = opened()
        XCTAssertEqual(m.handle(.flags([.command, .option, .shift], buttonsDown: false, eligible: true), now: 1).effects, [])
        XCTAssertEqual(m.phase, .open)
    }

    func testEscapeIsConsumedAndOtherKeysCloseAndPassThrough() {
        var m = opened()
        var r = m.handle(.keyDown(53), now: 1)
        XCTAssertEqual(r.effects, [.dismiss(animated: true, reason: "escape")])
        XCTAssertFalse(r.passThrough)
        XCTAssertEqual(m.phase, .idle)

        m = opened()
        r = m.handle(.keyDown(34), now: 1)
        XCTAssertEqual(r.effects, [.dismiss(animated: false, reason: "key")])
        XCTAssertTrue(r.passThrough)
    }

    func testMouseDownWhileOpenClosesAndPassesThrough() {
        var m = opened()
        _ = m.handle(.pointer(offset(0)), now: 1)
        let r = m.handle(.mouseDown, now: 1)
        XCTAssertEqual(r.effects, [.dismiss(animated: true, reason: "mouse")])
        XCTAssertTrue(r.passThrough)
        // Letting go afterwards opens nothing.
        XCTAssertEqual(m.handle(.flags([], buttonsDown: false, eligible: true), now: 2).effects, [])
    }

    func testResignClosesWithoutAnimationAndScrollWhileOpenIsIgnored() {
        var m = opened()
        XCTAssertEqual(m.handle(.scroll, now: 1).effects, [])
        XCTAssertEqual(m.phase, .open)
        XCTAssertEqual(m.handle(.resign, now: 1).effects, [.dismiss(animated: false, reason: "resign")])
        XCTAssertEqual(m.phase, .idle)
    }

    func testAfterEscapeTheNextPressStartsOver() {
        var m = opened()
        _ = m.handle(.keyDown(53), now: 1)
        _ = m.handle(.flags([.option], buttonsDown: false, eligible: true), now: 2)
        XCTAssertEqual(m.handle(.flags(both, buttonsDown: false, eligible: true), now: 3).effects, [.schedule(0.30)])
    }
}
