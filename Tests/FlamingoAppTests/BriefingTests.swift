import XCTest
import AppKit
import FlamingoThoughts
@testable import Flamingo

final class BriefingTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1512, height: 949)
    private let original = CGRect(x: 156, y: 141, width: 1200, height: 760)

    // MARK: Window plan

    func testZoomGoesToTheVisibleFrame() {
        XCTAssertEqual(BriefingWindowPlan.zoomTarget(window: original, visible: visible, isFullScreen: false), visible)
    }

    func testNativeFullScreenIsLeftAlone() {
        XCTAssertNil(BriefingWindowPlan.zoomTarget(window: original, visible: visible, isFullScreen: true))
    }

    func testAWindowAlreadyFillingTheScreenDoesNotZoom() {
        XCTAssertNil(BriefingWindowPlan.zoomTarget(window: visible.insetBy(dx: 1, dy: 1), visible: visible, isFullScreen: false))
    }

    func testRestoreWhenUntouched() {
        XCTAssertEqual(BriefingWindowPlan.restoreTarget(saved: original, zoomed: visible, current: visible, isFullScreen: false), original)
    }

    func testNoRestoreWhenMovedOrResized() {
        XCTAssertNil(BriefingWindowPlan.restoreTarget(saved: original, zoomed: visible, current: visible.offsetBy(dx: 40, dy: 0), isFullScreen: false))
        XCTAssertNil(BriefingWindowPlan.restoreTarget(saved: original, zoomed: visible, current: CGRect(x: 0, y: 0, width: 900, height: 600), isFullScreen: false))
    }

    func testNoRestoreInNativeFullScreen() {
        XCTAssertNil(BriefingWindowPlan.restoreTarget(saved: original, zoomed: visible, current: visible, isFullScreen: true))
    }

    func testFrameRoundTripsThroughDefaultsText() {
        XCTAssertEqual(BriefingWindowPlan.decode(BriefingWindowPlan.encode(original)), original)
        XCTAssertNil(BriefingWindowPlan.decode("1,2,3"))
        XCTAssertNil(BriefingWindowPlan.decode(nil))
    }

    // MARK: Trigger glue

    private func conditions(sheet: Bool = false, test: Bool = false, auto: Bool = true, ready: Bool = true, file: Bool = false, active: Bool = true) -> BriefingConditions {
        BriefingTrigger.conditions(sheetOrPanelUp: sheet, nothingToShow: false, underTest: test, autoOpenEnabled: auto,
                                   contentReady: ready, launchedByFileRequest: file, appIsActive: active)
    }

    func testFirstActivationOfTheDayShows() {
        let clock = BriefingClock(lastShownDay: "2026-10-16")
        XCTAssertTrue(BriefingTrigger.wouldShow(clock, .activation(.user), now: Date(), conditions: conditions()))
    }

    func testSkipsWhenShownTodayOffInTestsOrBlocked() {
        let now = Date()
        let today = BriefingClock(calendar: .current).day(now)
        XCTAssertFalse(BriefingTrigger.wouldShow(BriefingClock(lastShownDay: today), .activation(.user), now: now, conditions: conditions()))
        let clock = BriefingClock(lastShownDay: nil)
        XCTAssertFalse(BriefingTrigger.wouldShow(clock, .activation(.user), now: now, conditions: conditions(auto: false)))
        XCTAssertFalse(BriefingTrigger.wouldShow(clock, .activation(.user), now: now, conditions: conditions(test: true)))
        XCTAssertFalse(BriefingTrigger.wouldShow(clock, .activation(.user), now: now, conditions: conditions(sheet: true)))
        XCTAssertFalse(BriefingTrigger.wouldShow(clock, .launch, now: now, conditions: conditions(ready: false)))
    }

    func testOpenFileRequestLeavesTheDayPending() {
        var clock = BriefingClock(lastShownDay: nil)
        let now = Date()
        XCTAssertFalse(BriefingTrigger.wouldShow(clock, .activation(.openFileRequest), now: now, conditions: conditions()))
        _ = clock.evaluate(.activation(.openFileRequest), now: now, conditions: conditions())
        XCTAssertEqual(clock.pendingDay, clock.day(now))
        XCTAssertTrue(BriefingTrigger.wouldShow(clock, .activation(.user), now: now, conditions: conditions()))
    }

    func testActivationSourceByRecentCause() {
        let now = Date()
        XCTAssertEqual(BriefingTrigger.source(openFileAt: now.addingTimeInterval(-0.3), paletteAt: nil, now: now), .openFileRequest)
        XCTAssertEqual(BriefingTrigger.source(openFileAt: nil, paletteAt: now.addingTimeInterval(-0.3), now: now), .globalPalette)
        XCTAssertEqual(BriefingTrigger.source(openFileAt: now.addingTimeInterval(-30), paletteAt: nil, now: now), .user)
    }

    func testWakeWaitsForTheNextActivation() {
        var clock = BriefingClock(lastShownDay: nil)
        let now = Date()
        XCTAssertFalse(BriefingTrigger.wouldShow(clock, .wake, now: now, conditions: conditions(active: false)))
        _ = clock.evaluate(.wake, now: now, conditions: conditions(active: false))
        XCTAssertTrue(BriefingTrigger.wouldShow(clock, .activation(.user), now: now, conditions: conditions()))
    }

    func testUnderTestIsDetected() { XCTAssertTrue(BriefingTrigger.isUnderTest) }

    // MARK: Memos, keys, text

    func testMemoIsNewTheDayItIsFirstShownThenSeen() {
        let first = BriefingMemoAging.apply(paths: ["a", "b"], day: "2026-10-17", firstShown: [:])
        XCTAssertEqual(first.fresh, ["a", "b"]); XCTAssertTrue(first.stale.isEmpty)
        let sameDay = BriefingMemoAging.apply(paths: ["a"], day: "2026-10-17", firstShown: first.updated)
        XCTAssertEqual(sameDay.fresh, ["a"])
        let next = BriefingMemoAging.apply(paths: ["a", "c"], day: "2026-10-18", firstShown: first.updated)
        XCTAssertEqual(next.stale, ["a"]); XCTAssertEqual(next.fresh, ["c"])
    }

    func testKeys() {
        func key(_ c: String?, _ code: UInt16 = 0, _ m: NSEvent.ModifierFlags = []) -> BriefingKeyAction {
            BriefingKeys.action(characters: c, keyCode: code, modifiers: m)
        }
        XCTAssertEqual(key("j"), .move(1)); XCTAssertEqual(key("k"), .move(-1))
        XCTAssertEqual(key(nil, 125), .move(1)); XCTAssertEqual(key(nil, 126), .move(-1))
        XCTAssertEqual(key("e"), .done); XCTAssertEqual(key("s"), .snooze); XCTAssertEqual(key("r"), .reply)
        XCTAssertEqual(key("a"), .attach); XCTAssertEqual(key(nil, 36), .open)
        XCTAssertEqual(key(nil, 51), .dismiss); XCTAssertEqual(key(nil, 53), .close)
        XCTAssertEqual(key("e", 0, .command), .none, "⌘E is not Done")
        XCTAssertEqual(key("z"), .none)
    }

    func testPlainWikilinks() {
        XCTAssertEqual(BriefingFormat.plain("see [[finance/q3-model.xlsx#cell A1]] and [[x.md|the note]]"), "see q3-model.xlsx and the note")
        XCTAssertEqual(BriefingFormat.plain("nothing here"), "nothing here")
    }

    func testDateLine() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 9))!
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(BriefingFormat.weekday(date, calendar: cal, locale: en), "Saturday")
        XCTAssertEqual(BriefingFormat.monthDay(date, calendar: cal, locale: en), "October 17")
    }
}
