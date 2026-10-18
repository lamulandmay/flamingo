import AppKit
import XCTest
@testable import Flamingo

/// The decisions behind two-finger swipes, fed the event and callback sequences a trackpad and
/// AppKit's `trackSwipeEvent` produce (the callback order was read off a real tracking session:
/// the lift's phase, then the settle with no phase, then `isComplete` with no phase).
final class SwipeGateTests: XCTestCase {
    private let open = SwipeGate.Context(canBack: true, canForward: true)

    private func event(_ phase: SwipeGate.Phase, _ dx: CGFloat, _ dy: CGFloat = 0, momentum: Bool = false, precise: Bool = true) -> SwipeGate.Event {
        SwipeGate.Event(phase: phase, momentum: momentum, dx: dx, dy: dy, precise: precise)
    }

    private func run(_ events: [SwipeGate.Event], context: SwipeGate.Context? = nil) -> [SwipeGate.Decision] {
        var gate = SwipeGate()
        let c = context ?? open
        return events.map { gate.decide($0) { c } }
    }

    func testAFastSidewaysStartStartsAtOnce() {
        XCTAssertEqual(run([event(.mayBegin, 0), event(.began, 14)]), [.pass("fingers down"), .start(back: true)])
    }

    func testASmallSidewaysStartIsHeldUntilItHasTravelled() {
        let d = run([event(.began, 4), event(.changed, 4), event(.changed, 5)])
        XCTAssertEqual(d, [.hold, .hold, .start(back: true)])
    }

    func testABeginningWithoutMovementWaitsForTheFirstMovement() {
        let d = run([event(.began, 0), event(.changed, -6, 1), event(.changed, -7, 0)])
        XCTAssertEqual(d, [.pass("no movement yet"), .hold, .start(back: false)])
    }

    func testAVerticalStartStaysAScrollEvenIfItTurnsSideways() {
        let d = run([event(.began, 1, 6), event(.changed, 30, 0), event(.changed, 30, 0)])
        XCTAssertEqual(d, [.pass("vertical"), .pass("scrolling"), .pass("scrolling")])
    }

    func testAHeldGestureThatTurnsVerticalIsLetGo() {
        let d = run([event(.began, 5, 1), event(.changed, 2, 4), event(.changed, 20, 0)])
        XCTAssertEqual(d, [.hold, .pass("turned vertical"), .pass("scrolling")])
    }

    func testAHeldGestureThatTurnsAroundIsLetGo() {
        let d = run([event(.began, 5), event(.changed, -9)])
        XCTAssertEqual(d, [.hold, .pass("turned around")])
    }

    func testOnlyDirectionsWithHistorySwipe() {
        let backOnly = SwipeGate.Context(canBack: true, canForward: false)
        XCTAssertEqual(run([event(.began, -20)], context: backOnly), [.pass("nothing forward")])
        XCTAssertEqual(run([event(.began, 20)], context: backOnly), [.start(back: true)])
        let forwardOnly = SwipeGate.Context(canBack: false, canForward: true)
        XCTAssertEqual(run([event(.began, 20)], context: forwardOnly), [.pass("nothing back")])
        XCTAssertEqual(run([event(.began, -20)], context: forwardOnly), [.start(back: false)])
    }

    func testTheGraphKeepsItsTwoFingerPan() {
        var c = open
        c.pans = true
        XCTAssertEqual(run([event(.began, 20), event(.changed, 20)], context: c), [.pass("the view pans"), .pass("scrolling")])
    }

    func testASidewaysScrollerKeepsTheGestureUntilItRestsAtThatEdge() {
        var scrolled = open
        scrolled.pinnedLeft = false
        scrolled.pinnedRight = true
        XCTAssertEqual(run([event(.began, 20)], context: scrolled), [.pass("scroller not at its edge")], "back pulls it left; it isn't there yet")
        XCTAssertEqual(run([event(.began, -20)], context: scrolled), [.start(back: false)], "forward: it already rests at the right")
    }

    func testMomentumNeverStartsASwipe() {
        let d = run([event(.none, 30, momentum: true), event(.none, 30, momentum: true)])
        XCTAssertEqual(d, [.pass("momentum"), .pass("momentum")])
    }

    func testAMouseWheelNeverSwipes() {
        XCTAssertEqual(run([event(.began, 30, precise: false), event(.changed, 30)]), [.pass("not a trackpad"), .pass("scrolling")])
        XCTAssertEqual(run([event(.none, 30)]), [.pass("not a gesture")])
    }

    func testLiftingWhileHeldLetsGoAndTheNextGestureStartsFresh() {
        var gate = SwipeGate()
        XCTAssertEqual(gate.decide(event(.began, 4)) { open }, .hold)
        XCTAssertEqual(gate.decide(event(.ended, 0)) { open }, .pass("lifted before it travelled far enough"))
        XCTAssertEqual(gate.state, .idle)
        XCTAssertEqual(gate.decide(event(.changed, 30)) { open }, .pass("no gesture began here"))
        XCTAssertEqual(gate.decide(event(.began, 13)) { open }, .start(back: true))
    }

    func testWhatIsUnderThePointerIsOnlyAskedOnceTheDirectionIsKnown() {
        var gate = SwipeGate()
        var asked = 0
        _ = gate.decide(event(.began, 0)) { asked += 1; return open }
        _ = gate.decide(event(.changed, 0, 5)) { asked += 1; return open }
        XCTAssertEqual(asked, 0, "zero, then vertical: nothing to ask")
        _ = gate.decide(event(.began, 5)) { asked += 1; return open }
        _ = gate.decide(event(.changed, 5)) { asked += 1; return open }
        XCTAssertEqual(asked, 1)
    }

    func testPhasesMapFromAppKit() {
        XCTAssertEqual(SwipeGate.Phase(.mayBegin), .mayBegin)
        XCTAssertEqual(SwipeGate.Phase(.began), .began)
        XCTAssertEqual(SwipeGate.Phase(.changed), .changed)
        XCTAssertEqual(SwipeGate.Phase(.stationary), .changed)
        XCTAssertEqual(SwipeGate.Phase(.ended), .ended)
        XCTAssertEqual(SwipeGate.Phase(.cancelled), .cancelled)
        XCTAssertEqual(SwipeGate.Phase([]), .none)
    }
}

final class SwipeProgressTests: XCTestCase {
    private typealias Step = (amount: CGFloat, phase: SwipeGate.Phase, complete: Bool)

    private func run(back: Bool = true, _ steps: [Step]) -> (outputs: [SwipeProgress.Output], progress: SwipeProgress) {
        var p = SwipeProgress(back: back)
        var out: [SwipeProgress.Output] = []
        for s in steps { out += p.update(amount: s.amount, phase: s.phase, complete: s.complete) }
        return (out, p)
    }

    /// The shape AppKit reports: fingers down, the lift, the settle and `isComplete`, the last
    /// two with no phase. The old handler only committed on `.ended` *and* complete, which
    /// never comes together, so no swipe ever went through.
    func testASwipeCommitsWhenTheFingersLift() {
        let (out, p) = run([(0.01, .began, false), (0.4, .changed, false), (0.8, .changed, false), (1.04, .changed, false),
                            (1.04, .ended, false), (1.02, .none, false), (1.0, .none, true)])
        XCTAssertEqual(out, [.haptic, .commit])
        XCTAssertTrue(p.finished)
    }

    /// Waiting for AppKit's settle cost a quarter second on every swipe: the lift decides.
    func testTheLiftDecidesWithoutWaitingForTheSettle() {
        var p = SwipeProgress(back: true)
        XCTAssertEqual(p.update(amount: 0.5, phase: .changed, complete: false), [])
        XCTAssertEqual(p.update(amount: 0.5, phase: .ended, complete: false), [.commit])
        XCTAssertTrue(p.finished, "so AppKit's tracking can stop")
        XCTAssertEqual(p.update(amount: 0.8, phase: .none, complete: false), [], "the settle changes nothing")
        var q = SwipeProgress(back: true)
        XCTAssertEqual(q.update(amount: 0.2, phase: .cancelled, complete: false), [.cancel])
        XCTAssertTrue(q.finished)
    }

    func testACancelledSwipeDoesNotCommit() {
        let (out, _) = run([(0.01, .began, false), (0.4, .changed, false), (0.4, .cancelled, false),
                            (0.2, .none, false), (0, .none, true)])
        XCTAssertEqual(out, [.cancel])
    }

    func testAQuickFlickCommitsWithoutReachingTheThreshold() {
        // Velocity: AppKit says ended at 0.3 and animates the rest of the way itself.
        let (out, _) = run([(0.1, .began, false), (0.3, .changed, false), (0.3, .ended, false),
                            (0.7, .none, false), (1.0, .none, true)])
        XCTAssertEqual(out, [.commit], "no tap once the fingers are off the pad")
    }

    func testTheTapComesOncePerCrossingWhileTheFingersAreDown() {
        let (out, _) = run([(0.9, .changed, false), (1.0, .changed, false), (0.95, .changed, false), (1.1, .changed, false),
                            (0.8, .changed, false), (1.02, .changed, false)])
        XCTAssertEqual(out, [.haptic, .haptic], "re-armed only below 0.85")
    }

    func testForwardSwipesCountTheOtherWay() {
        let (out, p) = run(back: false, [(-0.5, .changed, false), (-1.01, .changed, false), (-1.01, .ended, false), (-1, .none, true)])
        XCTAssertEqual(out, [.haptic, .commit])
        XCTAssertEqual(p.progress, 1.01, accuracy: 0.0001, "where the fingers lifted; the settle after is ignored")
        XCTAssertEqual(run(back: false, [(0.5, .changed, false), (1.2, .changed, false)]).outputs, [], "the wrong way never taps")
    }

    func testWithNoLiftPhaseWhereTheAmountSettledDecides() {
        XCTAssertEqual(run([(0.6, .changed, false), (1, .none, true)]).outputs, [.commit])
        XCTAssertEqual(run([(0.6, .changed, false), (0, .none, true)]).outputs, [.cancel])
    }

    func testNothingAfterItFinishes() {
        var p = SwipeProgress(back: true)
        XCTAssertEqual(p.update(amount: 1, phase: .ended, complete: false), [.commit])
        XCTAssertEqual(p.update(amount: 1, phase: .none, complete: true), [])
        var q = SwipeProgress(back: true)
        XCTAssertEqual(q.update(amount: 0.7, phase: .changed, complete: false), [])
        XCTAssertEqual(q.update(amount: 1, phase: .none, complete: true), [.commit])
        XCTAssertEqual(q.update(amount: 1, phase: .none, complete: true), [])
    }

    func testAbandoningKeepsWhatTheLiftDecided() {
        var lifted = SwipeProgress(back: true)
        _ = lifted.update(amount: 0.9, phase: .ended, complete: false)
        XCTAssertEqual(lifted.abandon(), .commit)
        var cancelled = SwipeProgress(back: true)
        _ = cancelled.update(amount: 0.2, phase: .cancelled, complete: false)
        XCTAssertEqual(cancelled.abandon(), .cancel)
        var down = SwipeProgress(back: true)
        _ = down.update(amount: 1.1, phase: .changed, complete: false)
        XCTAssertEqual(down.abandon(), .cancel, "still on the pad: nothing was decided")
    }
}
