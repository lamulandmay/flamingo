import XCTest
import AppKit
@testable import FlamingoGraph

@MainActor
private final class RecordingTarget: GraphInteractionTarget {
    enum Call: Equatable {
        case hover(Int?), click(Int), begin(Int), drag(Int, CGPoint), end(Int), unpin(Int)
        case fitAll, moved, select(GraphDirection), open, type(String), escape
    }

    var camera = GraphCamera()
    var positions: [CGPoint]
    var pinned: Set<Int> = []
    var calls: [Call] = []

    init(positions: [CGPoint]) { self.positions = positions }

    func inputViewAttached(_ view: NSView) {}
    func viewResized(to size: CGSize) {}
    func node(atScreen p: CGPoint) -> Int? {
        let size = GestureTests.size
        return positions.indices.last { i in
            let s = camera.toScreen(positions[i], size: size)
            return hypot(s.x - p.x, s.y - p.y) <= 8
        }
    }
    func worldPosition(of node: Int) -> CGPoint { positions[node] }
    func isPinned(_ node: Int) -> Bool { pinned.contains(node) }
    func hover(_ node: Int?) { calls.append(.hover(node)) }
    func click(_ node: Int) { calls.append(.click(node)) }
    func beginNodeDrag(_ node: Int) { calls.append(.begin(node)) }
    func dragNode(_ node: Int, toWorld p: CGPoint) { calls.append(.drag(node, p)) }
    func endNodeDrag(_ node: Int) { calls.append(.end(node)) }
    func unpin(_ node: Int) { calls.append(.unpin(node)) }
    func fitAll() { calls.append(.fitAll) }
    func userMovedCamera() { calls.append(.moved) }
    func moveSelection(_ direction: GraphDirection) { calls.append(.select(direction)) }
    func openSelection() { calls.append(.open) }
    func type(_ text: String) { calls.append(.type(text)) }
    func escape() { calls.append(.escape) }

    /// Calls without hover noise.
    var actions: [Call] { calls.filter { if case .hover = $0 { false } else { true } } }
    func count(_ call: Call) -> Int { calls.filter { $0 == call }.count }
}

@MainActor
final class GestureTests: XCTestCase {
    static let size = CGSize(width: 400, height: 300)

    private var target: RecordingTarget!
    private var recognizer: GraphGestureRecognizer!
    private var scheduled: [(delay: TimeInterval, work: @MainActor () -> Void)] = []
    private var clock: TimeInterval = 100
    private var animationStarts = 0
    private var panning: [Bool] = []

    /// Node 0 sits at the view center, node 1 at world (50, 0) → screen (250, 150).
    private let center = CGPoint(x: 200, y: 150)
    private let other = CGPoint(x: 250, y: 150)
    private let empty = CGPoint(x: 100, y: 60)

    override func setUp() async throws {
        target = RecordingTarget(positions: [.zero, CGPoint(x: 50, y: 0)])
        recognizer = GraphGestureRecognizer(target: target)
        recognizer.viewSize = Self.size
        scheduled = []
        clock = 100
        animationStarts = 0
        panning = []
        recognizer.schedule = { [unowned self] delay, work in self.scheduled.append((delay, work)) }
        recognizer.now = { [unowned self] in self.clock }
        recognizer.doubleClickInterval = { 0.4 }
        recognizer.onAnimationStarted = { [unowned self] in self.animationStarts += 1 }
        recognizer.onPanningChanged = { [unowned self] in self.panning.append($0) }
    }

    private func click(_ p: CGPoint, count: Int = 1) {
        recognizer.mouseDown(at: p, clickCount: count)
        recognizer.mouseUp(at: p)
    }

    private func runScheduled(delay: TimeInterval) {
        let due = scheduled.filter { $0.delay == delay }
        scheduled.removeAll { $0.delay == delay }
        due.forEach { $0.work() }
    }

    private func assertEqual(_ a: CGPoint, _ b: CGPoint, accuracy: CGFloat = 1e-9,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    }

    private func key(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = [],
                     repeat isRepeat: Bool = false) -> GraphKeyInput {
        GraphKeyInput(keyCode: code, characters: chars, charactersIgnoringModifiers: chars,
                      modifiers: mods, isRepeat: isRepeat)
    }

    // MARK: Clicks

    func testClickUnpinnedNodeOpensImmediately() {
        click(center)
        XCTAssertEqual(target.actions, [.click(0)])
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testClickPinnedNodeIsDeferredThenFires() {
        target.pinned = [0]
        click(center)
        XCTAssertEqual(target.actions, [])
        XCTAssertEqual(scheduled.map(\.delay), [0.4])
        runScheduled(delay: 0.4)
        XCTAssertEqual(target.actions, [.click(0)])
    }

    func testDoubleClickPinnedNodeUnpinsWithoutOpening() {
        target.pinned = [0]
        click(center, count: 1)
        click(center, count: 2)
        XCTAssertEqual(target.actions, [.unpin(0)])
        runScheduled(delay: 0.4)   // the deferred click was cancelled
        XCTAssertEqual(target.actions, [.unpin(0)])
    }

    func testDoubleClickUnpinnedNodeOnlyOpensOnce() {
        click(center, count: 1)
        click(center, count: 2)
        XCTAssertEqual(target.actions, [.click(0)])
    }

    func testPressElsewhereDeliversPendingPinnedClick() {
        target.pinned = [0]
        click(center)
        click(other)
        XCTAssertEqual(target.actions, [.click(0), .click(1)])
        runScheduled(delay: 0.4)
        XCTAssertEqual(target.actions, [.click(0), .click(1)])
    }

    func testDoubleClickBackgroundFits() {
        click(empty, count: 1)
        XCTAssertEqual(target.actions, [])
        click(empty, count: 2)
        XCTAssertEqual(target.actions, [.fitAll])
    }

    func testSubThresholdJitterIsAClick() {
        recognizer.mouseDown(at: center, clickCount: 1)
        recognizer.mouseDragged(to: CGPoint(x: 201, y: 151))
        recognizer.mouseDragged(to: CGPoint(x: 202, y: 152))
        recognizer.mouseUp(at: CGPoint(x: 202, y: 152))
        XCTAssertEqual(target.actions, [.click(0)])
        XCTAssertEqual(target.camera, GraphCamera())
    }

    func testControlClickIsLeftAlone() {
        XCTAssertFalse(recognizer.mouseDown(at: center, clickCount: 1, modifiers: .control))
        recognizer.mouseUp(at: center)
        XCTAssertEqual(target.actions, [])
    }

    // MARK: Drags

    func testNodeDragKeepsGrabOffsetAndDoesNotClick() {
        target.camera = GraphCamera(center: .zero, zoom: 2)
        // Node 1 at world (50, 0) → screen (300, 150). Grab it 3pt right, 2pt down of center.
        let down = CGPoint(x: 303, y: 152)
        recognizer.mouseDown(at: down, clickCount: 1)
        recognizer.mouseDragged(to: CGPoint(x: 305, y: 152))          // 2pt: not yet
        XCTAssertEqual(target.actions, [])
        recognizer.mouseDragged(to: CGPoint(x: 343, y: 172))          // +40, +20 screen
        recognizer.mouseDragged(to: CGPoint(x: 363, y: 152))
        recognizer.mouseUp(at: CGPoint(x: 363, y: 152))

        XCTAssertEqual(target.actions.first, .begin(1))
        XCTAssertEqual(target.actions.last, .end(1))
        let drags = target.actions.compactMap { call -> CGPoint? in
            if case let .drag(1, p) = call { p } else { nil }
        }
        XCTAssertEqual(drags.count, 2)
        assertEqual(drags[0], CGPoint(x: 70, y: 10))   // node moved by (40, 20) / zoom 2
        assertEqual(drags[1], CGPoint(x: 80, y: 0))
        XCTAssertFalse(target.calls.contains(.click(1)))
        XCTAssertFalse(target.calls.contains(.moved))
        XCTAssertEqual(target.camera.center, .zero)
    }

    func testNodeDragKeepsHoverOnDraggedNode() {
        recognizer.mouseMoved(to: center)
        XCTAssertEqual(target.calls, [.hover(0)])
        recognizer.mouseDown(at: center, clickCount: 1)
        recognizer.mouseDragged(to: CGPoint(x: 220, y: 150))
        recognizer.mouseExited()
        recognizer.mouseDragged(to: CGPoint(x: 500, y: 150))
        XCTAssertEqual(target.calls.filter { if case .hover = $0 { true } else { false } }, [.hover(0)])
        recognizer.mouseUp(at: CGPoint(x: 500, y: 150))   // outside the view
        XCTAssertEqual(target.calls.last, .hover(nil))
    }

    func testBackgroundDragPansByExactDelta() {
        target.camera = GraphCamera(center: CGPoint(x: 10, y: 20), zoom: 2)
        recognizer.mouseDown(at: empty, clickCount: 1)
        recognizer.mouseDragged(to: CGPoint(x: 102, y: 60))           // under threshold
        XCTAssertEqual(target.camera.center, CGPoint(x: 10, y: 20))
        recognizer.mouseDragged(to: CGPoint(x: 110, y: 66))
        recognizer.mouseDragged(to: CGPoint(x: 140, y: 90))
        recognizer.mouseUp(at: CGPoint(x: 140, y: 90))

        // Pointer moved (40, 30) in total; at zoom 2 the camera moves (-20, -15) world units.
        assertEqual(target.camera.center, CGPoint(x: -10, y: 5))
        XCTAssertEqual(target.count(.moved), 1)
        XCTAssertEqual(target.actions, [.moved])
        XCTAssertEqual(panning, [true, false])
    }

    func testBackgroundDragKeepsWorldPointUnderPointer() {
        target.camera = GraphCamera(center: CGPoint(x: 3, y: -7), zoom: 0.7)
        let grabbed = target.camera.toWorld(empty, size: Self.size)
        recognizer.mouseDown(at: empty, clickCount: 1)
        let end = CGPoint(x: 260, y: 10)
        recognizer.mouseDragged(to: CGPoint(x: 180, y: 40))
        recognizer.mouseDragged(to: end)
        assertEqual(target.camera.toWorld(end, size: Self.size), grabbed, accuracy: 1e-9)
    }

    func testNoHoverChangesWhilePanningThenReevaluates() {
        recognizer.mouseDown(at: empty, clickCount: 1)
        recognizer.mouseDragged(to: CGPoint(x: 150, y: 60))
        recognizer.mouseMoved(to: other)        // can't happen mid-drag, but must be ignored
        recognizer.mouseExited()
        XCTAssertEqual(target.calls, [.moved])
        // The layout slides node 1 under the pointer while the pan is in flight.
        let release = CGPoint(x: 180, y: 80)
        recognizer.mouseDragged(to: release)
        target.positions[1] = target.camera.toWorld(release, size: Self.size)
        recognizer.mouseUp(at: release)
        XCTAssertEqual(target.calls, [.moved, .hover(1)])
    }

    // MARK: Scroll and pinch

    func testPreciseScrollPans() {
        target.camera = GraphCamera(center: .zero, zoom: 2)
        recognizer.scroll(GraphScrollInput(location: center, delta: CGSize(width: 10, height: -30),
                                           precise: true, phase: .began))
        // Content follows the fingers: +10 right, -30 up on screen.
        assertEqual(target.camera.center, CGPoint(x: -5, y: 15))
        XCTAssertEqual(target.camera.zoom, 2)
        recognizer.scroll(GraphScrollInput(location: center, delta: CGSize(width: 4, height: 0),
                                           precise: true, momentumPhase: .changed))
        assertEqual(target.camera.center, CGPoint(x: -7, y: 15))
        XCTAssertEqual(target.count(.moved), 2)
    }

    func testZeroDeltaScrollDoesNothing() {
        recognizer.scroll(GraphScrollInput(location: center, delta: .zero, precise: true, phase: .began))
        XCTAssertEqual(target.calls, [])
    }

    func testWheelZoomsAroundCursor() {
        target.camera = GraphCamera(center: CGPoint(x: 5, y: 5), zoom: 1)
        let cursor = CGPoint(x: 320, y: 40)
        let anchor = target.camera.toWorld(cursor, size: Self.size)
        recognizer.scroll(GraphScrollInput(location: cursor, delta: CGSize(width: 0, height: 1), precise: false))
        XCTAssertEqual(target.camera.zoom, exp(GraphGestureRecognizer.lineZoomRate), accuracy: 1e-9)
        assertEqual(target.camera.toWorld(cursor, size: Self.size), anchor, accuracy: 1e-9)
        recognizer.scroll(GraphScrollInput(location: cursor, delta: CGSize(width: 0, height: -2), precise: false))
        XCTAssertLessThan(target.camera.zoom, 1)
        assertEqual(target.camera.toWorld(cursor, size: Self.size), anchor, accuracy: 1e-9)
        XCTAssertEqual(target.count(.moved), 2)
    }

    func testWheelZoomFollowsPhysicalDirectionUnderNaturalScrolling() {
        // Natural scrolling flips the sign AppKit reports; rolling away still zooms in.
        recognizer.scroll(GraphScrollInput(location: center, delta: CGSize(width: 0, height: -1),
                                           precise: false, invertedFromDevice: true))
        XCTAssertGreaterThan(target.camera.zoom, 1)
    }

    func testAcceleratedWheelStepIsCapped() {
        recognizer.scroll(GraphScrollInput(location: center, delta: CGSize(width: 0, height: 40), precise: false))
        XCTAssertEqual(target.camera.zoom, exp(GraphGestureRecognizer.maxScrollZoomStep), accuracy: 1e-9)
    }

    func testCommandOrOptionPreciseScrollZooms() {
        let cursor = CGPoint(x: 60, y: 250)
        let anchor = target.camera.toWorld(cursor, size: Self.size)
        recognizer.scroll(GraphScrollInput(location: cursor, delta: CGSize(width: 0, height: 20),
                                           precise: true, modifiers: .command, phase: .began))
        XCTAssertEqual(target.camera.zoom, exp(20 * GraphGestureRecognizer.preciseZoomRate), accuracy: 1e-9)
        assertEqual(target.camera.toWorld(cursor, size: Self.size), anchor, accuracy: 1e-9)

        let zoomed = target.camera.zoom
        recognizer.scroll(GraphScrollInput(location: cursor, delta: CGSize(width: 0, height: -20),
                                           precise: true, modifiers: .option, phase: .began))
        XCTAssertEqual(target.camera.zoom, zoomed * exp(-0.2), accuracy: 1e-9)
    }

    func testScrollModeIsLatchedForTheGesture() {
        recognizer.scroll(GraphScrollInput(location: center, delta: CGSize(width: 0, height: 10),
                                           precise: true, modifiers: .command, phase: .began))
        let z = target.camera.zoom
        // ⌘ released mid-gesture and through momentum: still zooming, never panning.
        recognizer.scroll(GraphScrollInput(location: center, delta: CGSize(width: 0, height: 10),
                                           precise: true, phase: .changed))
        recognizer.scroll(GraphScrollInput(location: center, delta: CGSize(width: 0, height: 10),
                                           precise: true, momentumPhase: .changed))
        XCTAssertEqual(target.camera.zoom, z * exp(0.2), accuracy: 1e-9)
        XCTAssertEqual(target.camera.center, .zero)
        // A new gesture without ⌘ pans.
        recognizer.scroll(GraphScrollInput(location: center, delta: CGSize(width: 0, height: 10),
                                           precise: true, phase: .began))
        XCTAssertEqual(target.camera.zoom, z * exp(0.2), accuracy: 1e-9)
        XCTAssertNotEqual(target.camera.center, .zero)
    }

    func testMagnifyZoomsAroundCursor() {
        let cursor = CGPoint(x: 90, y: 200)
        let anchor = target.camera.toWorld(cursor, size: Self.size)
        recognizer.magnify(at: cursor, by: 0.5)
        XCTAssertEqual(target.camera.zoom, 1.5, accuracy: 1e-9)
        assertEqual(target.camera.toWorld(cursor, size: Self.size), anchor, accuracy: 1e-9)
        XCTAssertEqual(target.actions, [.moved])
    }

    func testSmartMagnifyFits() {
        recognizer.smartMagnify()
        XCTAssertEqual(target.actions, [.fitAll])
    }

    func testHoverSettlesAfterScroll() {
        target.camera = GraphCamera(center: CGPoint(x: 50, y: 0), zoom: 1)   // node 1 at center
        recognizer.mouseMoved(to: center)
        XCTAssertEqual(target.calls, [.hover(1)])
        // Pan 50pt right: node 0 slides under the pointer.
        recognizer.scroll(GraphScrollInput(location: center, delta: CGSize(width: 50, height: 0),
                                           precise: true, phase: .began))
        XCTAssertEqual(target.calls.last, .moved)        // no hover change mid-gesture
        runScheduled(delay: GraphGestureRecognizer.hoverSettleDelay)
        XCTAssertEqual(target.calls.last, .hover(0))
    }

    // MARK: Hover

    func testHoverOnlyReportsChanges() {
        recognizer.mouseMoved(to: center)
        recognizer.mouseMoved(to: CGPoint(x: 202, y: 151))
        recognizer.mouseMoved(to: empty)
        recognizer.mouseMoved(to: CGPoint(x: 101, y: 60))
        recognizer.mouseMoved(to: other)
        recognizer.mouseExited()
        recognizer.mouseExited()
        XCTAssertEqual(target.calls, [.hover(0), .hover(nil), .hover(1), .hover(nil)])
    }

    // MARK: Keys

    func testArrowsReturnEnterEscape() {
        let arrows = NSEvent.ModifierFlags([.numericPad, .function])   // what AppKit sends
        XCTAssertTrue(recognizer.keyDown(key(GraphKeyCode.left, "\u{F702}", arrows)))
        XCTAssertTrue(recognizer.keyDown(key(GraphKeyCode.right, "\u{F703}", arrows)))
        XCTAssertTrue(recognizer.keyDown(key(GraphKeyCode.up, "\u{F700}", arrows)))
        XCTAssertTrue(recognizer.keyDown(key(GraphKeyCode.down, "\u{F701}", arrows.union(.shift))))
        XCTAssertTrue(recognizer.keyDown(key(GraphKeyCode.returnKey, "\r")))
        XCTAssertTrue(recognizer.keyDown(key(GraphKeyCode.keypadEnter, "\u{03}", .numericPad)))
        XCTAssertTrue(recognizer.keyDown(key(GraphKeyCode.escape, "\u{1B}")))
        recognizer.escape()   // cancelOperation(_:)
        XCTAssertEqual(target.calls, [.select(.left), .select(.right), .select(.up), .select(.down),
                                      .open, .open, .escape, .escape])
    }

    func testRepeatedReturnOpensOnce() {
        XCTAssertTrue(recognizer.keyDown(key(GraphKeyCode.returnKey, "\r")))
        XCTAssertTrue(recognizer.keyDown(key(GraphKeyCode.returnKey, "\r", repeat: true)))
        XCTAssertEqual(target.calls, [.open])
    }

    func testPrintableCharactersGoToFilter() {
        let cases: [(UInt16, String, NSEvent.ModifierFlags)] = [
            (0, "a", []), (41, ":", .shift), (18, "1", []), (49, " ", []), (32, "ü", .option), (47, ".", []),
        ]
        for (code, chars, mods) in cases {
            XCTAssertTrue(recognizer.keyDown(key(code, chars, mods)), chars)
        }
        XCTAssertEqual(target.calls, [.type("a"), .type(":"), .type("1"), .type(" "), .type("ü"), .type(".")])
    }

    func testModifiedAndNonPrintableKeysAreNotTyped() {
        XCTAssertFalse(recognizer.keyDown(key(0, "a", .command)))
        XCTAssertFalse(recognizer.keyDown(key(0, "\u{01}", .control)))
        XCTAssertFalse(recognizer.keyDown(key(GraphKeyCode.left, "\u{F702}", [.command, .numericPad, .function])))
        XCTAssertFalse(recognizer.keyDown(key(122, "\u{F704}", .function)))     // F1
        XCTAssertFalse(recognizer.keyDown(key(115, "\u{F729}", .function)))     // Home
        XCTAssertFalse(recognizer.keyDown(key(48, "\t")))                       // Tab
        XCTAssertFalse(recognizer.keyDown(key(51, "\u{7F}")))                   // Delete
        XCTAssertFalse(recognizer.keyDown(key(32, "", .option)))                // dead key
        XCTAssertEqual(target.calls, [])
    }

    func testKeyEquivalents() {
        XCTAssertTrue(recognizer.keyEquivalent(key(0, "0", .command)))
        XCTAssertFalse(recognizer.keyEquivalent(key(0, "k", .command)))
        XCTAssertFalse(recognizer.keyEquivalent(key(0, "=", [])))
        XCTAssertFalse(recognizer.keyEquivalent(key(0, "=", [.command, .option])))
        XCTAssertEqual(target.actions, [.fitAll])
    }

    func testKeyboardZoomAnimatesAroundCenterAndCompounds() {
        target.camera = GraphCamera(center: CGPoint(x: 7, y: 9), zoom: 1)
        XCTAssertTrue(recognizer.keyEquivalent(key(24, "+", [.command, .shift])))
        XCTAssertEqual(animationStarts, 1)
        XCTAssertEqual(target.camera.zoom, 1)                 // nothing until the first frame
        clock += 0.075
        XCTAssertTrue(recognizer.stepAnimation())
        XCTAssertGreaterThan(target.camera.zoom, 1.1)         // ease-out: well past halfway
        XCTAssertLessThan(target.camera.zoom, 1.25)
        assertEqual(target.camera.center, CGPoint(x: 7, y: 9)) // center anchor: no drift
        // A second press mid-flight aims for 1.25².
        XCTAssertTrue(recognizer.keyEquivalent(key(24, "=", .command)))
        XCTAssertEqual(animationStarts, 1)
        clock += 1
        XCTAssertFalse(recognizer.stepAnimation())
        XCTAssertEqual(target.camera.zoom, 1.5625, accuracy: 1e-9)
        XCTAssertTrue(recognizer.keyEquivalent(key(27, "-", .command)))
        recognizer.finishAnimation()
        XCTAssertEqual(target.camera.zoom, 1.25, accuracy: 1e-9)
        XCTAssertEqual(target.count(.moved), 3)
    }

    func testKeyboardZoomWithoutAnimationJumps() {
        recognizer.animatesKeyboardZoom = false
        XCTAssertTrue(recognizer.keyEquivalent(key(27, "-", .command)))
        XCTAssertEqual(target.camera.zoom, 0.8, accuracy: 1e-9)
        XCTAssertEqual(animationStarts, 0)
    }

    func testScrollCancelsKeyboardZoom() {
        XCTAssertTrue(recognizer.keyEquivalent(key(24, "=", .command)))
        recognizer.scroll(GraphScrollInput(location: center, delta: CGSize(width: 5, height: 0), precise: true))
        XCTAssertFalse(recognizer.isAnimating)
        XCTAssertFalse(recognizer.stepAnimation())
    }

    // MARK: Lifecycle

    func testResetBalancesOpenGestures() {
        recognizer.mouseDown(at: center, clickCount: 1)
        recognizer.mouseDragged(to: CGPoint(x: 230, y: 150))
        recognizer.reset()
        XCTAssertEqual(target.actions.last, .end(0))

        recognizer.mouseDown(at: empty, clickCount: 1)
        recognizer.mouseDragged(to: CGPoint(x: 130, y: 60))
        recognizer.reset()
        XCTAssertEqual(panning, [true, false])

        target.camera = GraphCamera()
        target.pinned = [1]
        click(other)
        XCTAssertTrue(recognizer.hasPendingClick)
        recognizer.reset()
        runScheduled(delay: 0.4)
        XCTAssertFalse(target.calls.contains(.click(1)))
    }

    func testTargetIsHeldWeakly() {
        weak var gone: RecordingTarget?
        do {
            let t = RecordingTarget(positions: [])
            gone = t
            recognizer.target = t
        }
        XCTAssertNil(gone)
        recognizer.mouseDown(at: center, clickCount: 1)
        recognizer.mouseUp(at: center)
    }
}
