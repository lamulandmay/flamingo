import XCTest
@testable import FlamingoThoughts

final class BriefingClockTests: XCTestCase {
    var clock = BriefingClock(calendar: testCalendar)
    let ok = BriefingConditions()

    func testTheDayStartsAtFourInTheMorning() {
        XCTAssertEqual(BriefingDay.key(at("2026-10-17 03:59"), calendar: testCalendar), "2026-10-16")
        XCTAssertEqual(BriefingDay.key(at("2026-10-17 04:00"), calendar: testCalendar), "2026-10-17")
        XCTAssertEqual(BriefingDay.key(at("2026-10-17 00:00"), calendar: testCalendar), "2026-10-16")
        XCTAssertEqual(BriefingDay.key(at("2026-10-17 23:59"), calendar: testCalendar), "2026-10-17")
        XCTAssertEqual(BriefingDay.start(of: at("2026-10-17 03:59"), calendar: testCalendar), at("2026-10-16"))
        XCTAssertEqual(BriefingDay.begin(of: at("2026-10-17 08:30"), calendar: testCalendar), at("2026-10-17 04:00"))
        XCTAssertEqual(BriefingDay.begin(of: at("2026-10-17 01:00"), calendar: testCalendar), at("2026-10-16 04:00"))
    }

    func testTheDayHoldsAcrossDaylightSavingChanges() {
        // 2026-11-01: the clocks go back at 02:00, a 25-hour day. 03:59 is still the night of the 31st.
        XCTAssertEqual(BriefingDay.key(at("2026-11-01 03:59"), calendar: testCalendar), "2026-10-31")
        XCTAssertEqual(BriefingDay.key(at("2026-11-01 04:00"), calendar: testCalendar), "2026-11-01")
        XCTAssertEqual(BriefingDay.key(at("2026-11-02 03:59"), calendar: testCalendar), "2026-11-01")
        // 2026-03-08: they go forward; 04:00 is still the boundary.
        XCTAssertEqual(BriefingDay.key(at("2026-03-08 03:59"), calendar: testCalendar), "2026-03-07")
        XCTAssertEqual(BriefingDay.key(at("2026-03-08 04:00"), calendar: testCalendar), "2026-03-08")
        XCTAssertEqual(BriefingDay.key(at("2026-03-09 03:59"), calendar: testCalendar), "2026-03-08")
    }

    func testATimeZoneChangeMovesTheDay() {
        var tokyo = Calendar(identifier: .gregorian); tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let instant = at("2026-10-17 02:00") // 15:00 in Tokyo
        XCTAssertEqual(BriefingDay.key(instant, calendar: testCalendar), "2026-10-16")
        XCTAssertEqual(BriefingDay.key(instant, calendar: tokyo), "2026-10-17")
        var c = BriefingClock(calendar: tokyo, lastShownDay: "2026-10-16")
        XCTAssertEqual(c.evaluate(.activation(.user), now: instant), .show(day: "2026-10-17"), "landing in Tokyo is a new day")
    }

    func testTheFirstLaunchOfADayShowsItOnce() {
        XCTAssertEqual(clock.evaluate(.launch, now: at("2026-10-17 08:30"), conditions: ok), .show(day: "2026-10-17"))
        clock.didShow(at: at("2026-10-17 08:30"))
        XCTAssertEqual(clock.lastShownDay, "2026-10-17")
        XCTAssertEqual(clock.evaluate(.activation(.user), now: at("2026-10-17 09:00")), .skip(.alreadyShownToday))
        XCTAssertEqual(clock.evaluate(.launch, now: at("2026-10-17 21:00"), conditions: ok), .skip(.alreadyShownToday))
        XCTAssertEqual(clock.evaluate(.activation(.user), now: at("2026-10-18 03:59")), .skip(.alreadyShownToday), "03:59 is still the 17th")
        XCTAssertEqual(clock.evaluate(.activation(.user), now: at("2026-10-18 04:00")), .show(day: "2026-10-18"))
    }

    func testLaunchWaitsForTheFirstCommentsToLoad() {
        var c = ok; c.contentReady = false
        XCTAssertEqual(clock.evaluate(.launch, now: at("2026-10-17 08:30"), conditions: c), .skip(.notReady))
        XCTAssertEqual(clock.evaluate(.launch, now: at("2026-10-17 08:30"), conditions: ok), .show(day: "2026-10-17"), "asked again once loaded")
    }

    func testAnActivationAloneIsATriggerToo() {
        XCTAssertEqual(clock.evaluate(.activation(.user), now: at("2026-10-17 08:30")), .show(day: "2026-10-17"))
    }

    func testAnOpenFileRequestLeavesTheDayPending() {
        XCTAssertNil(clock.pendingDay)
        XCTAssertEqual(clock.evaluate(.activation(.openFileRequest), now: at("2026-10-17 08:30")), .skip(.openFileRequest))
        XCTAssertEqual(clock.pendingDay, "2026-10-17")
        XCTAssertNil(clock.lastShownDay, "not marked shown")
        XCTAssertEqual(clock.evaluate(.activation(.user), now: at("2026-10-17 08:45")), .show(day: "2026-10-17"), "the next ordinary activation")
        clock.didShow(at: at("2026-10-17 08:45"))
        XCTAssertNil(clock.pendingDay)
    }

    func testALaunchFromAFileIsPendingToo() {
        var c = ok; c.launchedByFileRequest = true
        XCTAssertEqual(clock.evaluate(.launch, now: at("2026-10-17 08:30"), conditions: c), .skip(.openFileRequest))
        XCTAssertEqual(clock.pendingDay, "2026-10-17")
        XCTAssertEqual(clock.evaluate(.activation(.user), now: at("2026-10-17 08:31")), .show(day: "2026-10-17"))
    }

    func testTheGlobalPaletteDoesNotTrigger() {
        XCTAssertEqual(clock.evaluate(.activation(.globalPalette), now: at("2026-10-17 08:30")), .skip(.globalPalette))
        XCTAssertEqual(clock.evaluate(.activation(.user), now: at("2026-10-17 08:31")), .show(day: "2026-10-17"))
    }

    func testASheetOrTheCapturePanelInTheWayPutsItOff() {
        var c = ok; c.sheetOrPanelUp = true
        XCTAssertEqual(clock.evaluate(.activation(.user), now: at("2026-10-17 08:30"), conditions: c), .skip(.blocked))
        XCTAssertNil(clock.lastShownDay)
        XCTAssertEqual(clock.evaluate(.activation(.user), now: at("2026-10-17 08:40"), conditions: ok), .show(day: "2026-10-17"))
    }

    func testNothingToShowTestsAndTheToggleAllSkip() {
        var c = ok; c.nothingToShow = true
        XCTAssertEqual(clock.evaluate(.launch, now: at("2026-10-17 08:30"), conditions: c), .skip(.nothingToShow))
        c = ok; c.underTest = true
        XCTAssertEqual(clock.evaluate(.launch, now: at("2026-10-17 08:30"), conditions: c), .skip(.underTest))
        c = ok; c.autoOpenEnabled = false
        XCTAssertEqual(clock.evaluate(.launch, now: at("2026-10-17 08:30"), conditions: c), .skip(.disabled))
        XCTAssertNil(clock.lastShownDay, "an empty or disabled day is not a shown day: the next trigger asks again")
    }

    func testAWakeInTheBackgroundWaitsForTheNextActivation() {
        clock = BriefingClock(calendar: testCalendar, lastShownDay: "2026-10-16")
        XCTAssertEqual(clock.evaluate(.wake, now: at("2026-10-17 07:30")), .skip(.waitingForActivation))
        XCTAssertEqual(clock.evaluate(.activation(.user), now: at("2026-10-17 08:30")), .show(day: "2026-10-17"))
    }

    func testAWakeWithFlamingoAlreadyInFrontShowsAtOnce() {
        clock = BriefingClock(calendar: testCalendar, lastShownDay: "2026-10-16")
        var c = ok; c.appIsActive = true
        XCTAssertEqual(clock.evaluate(.wake, now: at("2026-10-17 07:30"), conditions: c), .show(day: "2026-10-17"))
    }

    func testAWakeOnTheSameDayShowsNothing() {
        clock = BriefingClock(calendar: testCalendar, lastShownDay: "2026-10-17")
        var c = ok; c.appIsActive = true
        XCTAssertEqual(clock.evaluate(.wake, now: at("2026-10-17 15:00"), conditions: c), .skip(.alreadyShownToday))
    }

    func testStayingUpPastMidnightDoesNotMakeANewDay() {
        clock = BriefingClock(calendar: testCalendar, lastShownDay: "2026-10-16")
        var c = ok; c.appIsActive = true
        XCTAssertEqual(clock.evaluate(.wake, now: at("2026-10-17 00:30"), conditions: c), .skip(.alreadyShownToday))
    }
}
