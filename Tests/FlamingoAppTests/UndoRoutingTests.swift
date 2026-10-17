import AppKit
import XCTest
@testable import Flamingo

@MainActor
final class UndoRoutingTests: XCTestCase {
    @MainActor private final class Value: NSObject {
        var number = 0
        func set(_ number: Int, manager: UndoManager) {
            let previous = self.number
            manager.registerUndo(withTarget: self) { $0.set(previous, manager: manager) }
            self.number = number
            manager.setActionName("Typing")
        }
    }

    private func change(_ value: Value, to number: Int, manager: UndoManager,
                        timeline: NativeUndoTimeline, at time: TimeInterval) {
        manager.beginUndoGrouping()
        value.set(number, manager: manager)
        timeline.textChanged(at: time)
        manager.endUndoGrouping()
        timeline.closedGroup(at: time)
    }

    func testInterleavedNativeAndWorkspaceActionsStayInChronologicalOrder() {
        let manager = UndoManager(), value = Value()
        manager.groupsByEvent = false
        let timeline = NativeUndoTimeline(manager: manager)
        change(value, to: 1, manager: manager, timeline: timeline, at: 1)
        change(value, to: 2, manager: manager, timeline: timeline, at: 3)
        XCTAssertEqual(UndoRouting.source(native: timeline.latest(.undo), workspace: 2), .native)
        manager.undo(); timeline.undid(at: 4)
        XCTAssertEqual(value.number, 1)
        XCTAssertEqual(UndoRouting.source(native: timeline.latest(.undo), workspace: 2), .workspace)
        XCTAssertEqual(UndoRouting.source(native: timeline.latest(.undo), workspace: nil), .native)
        manager.undo(); timeline.undid(at: 5)
        XCTAssertNil(timeline.latest(.undo))
        XCTAssertEqual(timeline.latest(.redo), 5)
        manager.redo(); timeline.redid(at: 6)
        XCTAssertEqual(value.number, 1)
        XCTAssertEqual(timeline.latest(.undo), 6)
        XCTAssertEqual(timeline.latest(.redo), 4)
    }

    func testNewWorkspaceActionSuppressesOldNativeRedoWithoutRemovingNativeUndo() {
        let manager = UndoManager(), value = Value()
        manager.groupsByEvent = false
        let timeline = NativeUndoTimeline(manager: manager)
        change(value, to: 1, manager: manager, timeline: timeline, at: 1)
        change(value, to: 2, manager: manager, timeline: timeline, at: 2)
        manager.undo(); timeline.undid(at: 3)
        timeline.suppressRedo()
        XCTAssertNil(timeline.latest(.redo))
        XCTAssertEqual(timeline.latest(.undo), 1)
        manager.undo(); timeline.undid(at: 4)
        XCTAssertEqual(timeline.latest(.redo), 4)
        manager.redo(); timeline.redid(at: 5)
        XCTAssertNil(timeline.latest(.redo), "The earlier discarded branch must remain unavailable.")
    }

    func testNativeManagerResetDoesNotLeaveStaleTimestampAheadOfWorkspace() {
        let manager = UndoManager(), value = Value()
        manager.groupsByEvent = false
        let timeline = NativeUndoTimeline(manager: manager)
        change(value, to: 1, manager: manager, timeline: timeline, at: 20)
        manager.removeAllActions()
        XCTAssertNil(timeline.latest(.undo))
        XCTAssertEqual(UndoRouting.source(native: timeline.latest(.undo), workspace: 10), .workspace)
        change(value, to: 2, manager: manager, timeline: timeline, at: 30)
        XCTAssertEqual(timeline.latest(.undo), 30)
    }

    func testCommandRoutingRecognizesOnlyUndoAndRedoShortcuts() throws {
        func event(_ modifiers: NSEvent.ModifierFlags, character: String = "z") throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                          timestamp: 0, windowNumber: 0, context: nil,
                                          characters: character, charactersIgnoringModifiers: character,
                                          isARepeat: false, keyCode: 6))
        }
        XCTAssertEqual(UndoRouting.direction(for: try event(.command)), .undo)
        XCTAssertEqual(UndoRouting.direction(for: try event([.command, .shift])), .redo)
        for modifiers: NSEvent.ModifierFlags in [[], .control, .option, [.command, .option], [.command, .control]] {
            XCTAssertNil(UndoRouting.direction(for: try event(modifiers)))
        }
        XCTAssertNil(UndoRouting.direction(for: try event(.command, character: "x")))
    }
}
