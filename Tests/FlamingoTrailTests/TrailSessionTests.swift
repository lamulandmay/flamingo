import XCTest
import FlamingoCore
@testable import FlamingoTrail

final class TrailSessionTests: XCTestCase {
    private let tuning = TrailTuning()

    private func sessions(_ events: [TrailEvent], tuning: TrailTuning = TrailTuning()) -> [TrailSession] {
        TrailClustering.sessions(from: events, tuning: tuning)
    }

    // MARK: Splitting

    func testGapLongerThanSessionGapSplits() {
        let s = sessions(opens(["a.md"]) + opens(["b.md"], from: 25 * 60 + 1))
        XCTAssertEqual(s.map { paths($0.files) }, [["a.md"], ["b.md"]])
    }

    func testGapOfExactlySessionGapDoesNotSplit() {
        let s = sessions(opens(["a.md"]) + opens(["b.md"], from: 25 * 60))
        XCTAssertEqual(s.map { paths($0.files) }, [["a.md", "b.md"]])
    }

    func testGapIsMeasuredFromThePreviousEvent() {
        // Two hours of work with a pause of 20 minutes between files is one session.
        let s = sessions(opens(["a.md", "b.md", "c.md", "d.md", "e.md", "f.md", "g.md"], step: 20 * 60))
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].files.count, 7)
    }

    func testSessionGapIsTunable() {
        var t = TrailTuning()
        t.sessionGap = 60
        XCTAssertEqual(sessions(opens(["a.md", "b.md"], step: 61), tuning: t).count, 2)
        XCTAssertEqual(sessions(opens(["a.md", "b.md"], step: 60), tuning: t).count, 1)
    }

    func testEmptyStream() {
        XCTAssertEqual(sessions([]), [])
    }

    func testUnsortedInputIsSorted() {
        let stream = opens(["a.md", "b.md", "c.md"]) + opens(["x.md", "y.md"], from: 7200)
        let s = sessions(stream.reversed())
        XCTAssertEqual(s.map { paths($0.files) }, [["a.md", "b.md", "c.md"], ["x.md", "y.md"]])
        XCTAssertEqual(s[0].id, stream[0].id)
        XCTAssertEqual(s[1].id, stream[3].id)
    }

    func testStartAndEndSpanAllRawEvents() {
        // The first open is dropped as a pass-through, but the session still starts there.
        let stream = [ev(.opened, 0, file: "a.md"), ev(.opened, 1, file: "b.md"), ev(.searched, 400, text: "churn")]
        let s = sessions(stream)[0]
        XCTAssertEqual(s.start, trailBase)
        XCTAssertEqual(s.end, trailBase.addingTimeInterval(400))
        XCTAssertEqual(paths(s.files), ["b.md"])
    }

    // MARK: Ids

    func testSessionIdIsFirstRawEventId() {
        let stream = [ev(.opened, 0, file: "a.md"), ev(.opened, 1, file: "b.md"), ev(.opened, 30, file: "c.md")]
        let s = sessions(stream)[0]
        XCTAssertEqual(s.id, stream[0].id, "even though that open is dropped as a pass-through")
        XCTAssertFalse(s.events.contains { $0.id == stream[0].id })
    }

    func testSessionIdIsStableAsEventsAreAppended() {
        let stream = opens(["a.md", "b.md", "c.md", "d.md"]) + [ev(.commented, 45, file: "d.md", text: "hm")]
            + opens(["e.md"], from: 3 * 3600)
        var ids: [UUID] = []
        for n in 1...5 { ids.append(sessions(Array(stream.prefix(n)))[0].id) }
        XCTAssertEqual(Set(ids), [stream[0].id])

        let all = sessions(stream)
        XCTAssertEqual(all.map(\.id), [stream[0].id, stream[5].id])
    }

    // MARK: Rapid-fire opens

    func testRapidFireOpensCollapse() {
        // Arrowing down a list: A, B and C each open for under 3s; the user stops on C for 8s
        // and ends on D. A and B were passed through; C was read; D is where they stopped.
        let stream = [ev(.opened, 0, file: "A"), ev(.opened, 1, file: "B"),
                      ev(.opened, 2, file: "C"), ev(.opened, 10, file: "D")]
        let s = sessions(stream)[0]
        XCTAssertEqual(paths(s.files), ["C", "D"])
        XCTAssertEqual(s.events.map(\.id), [stream[2].id, stream[3].id])
    }

    func testLastVisitIsKeptEvenIfShort() {
        let s = sessions([ev(.opened, 0, file: "A"), ev(.opened, 1, file: "B")])[0]
        XCTAssertEqual(paths(s.files), ["B"])
    }

    func testDwellOfExactlyMinDwellIsKept() {
        let s = sessions([ev(.opened, 0, file: "A"), ev(.opened, 3, file: "B"), ev(.opened, 4, file: "C")])[0]
        XCTAssertEqual(paths(s.files), ["A", "C"])
    }

    func testRepeatedOpensOfOneFileAreOneVisit() {
        // Paging through slides of one deck re-opens it with new anchors; the visit lasts
        // from the first of those opens until another file is opened.
        let stream = [
            ev(.opened, 0, file: "q3.pptx", anchor: FileAnchor(kind: .slide, value: "1")),
            ev(.opened, 1, file: "q3.pptx", anchor: FileAnchor(kind: .slide, value: "2")),
            ev(.opened, 2, file: "q3.pptx", anchor: FileAnchor(kind: .slide, value: "3")),
            ev(.opened, 4, file: "model.xlsx"),
            ev(.opened, 30, file: "notes.md"),
        ]
        let s = sessions(stream)[0]
        XCTAssertEqual(paths(s.files), ["q3.pptx", "model.xlsx", "notes.md"])
        XCTAssertEqual(s.events.count, 5)
    }

    func testCommentedFilePassedThroughQuicklyIsKept() {
        let stream = [ev(.opened, 0, file: "A"), ev(.opened, 1, file: "B"),
                      ev(.commented, 1.5, file: "B", text: "quick thought"),
                      ev(.opened, 2, file: "C"), ev(.opened, 10, file: "D")]
        let s = sessions(stream)[0]
        XCTAssertEqual(paths(s.files), ["B", "C", "D"])
        XCTAssertEqual(s.comments.map(\.text), ["quick thought"])
    }

    func testFileCommentedLaterInSessionKeepsItsEarlierQuickVisit() {
        let stream = [ev(.opened, 0, file: "A"), ev(.opened, 1, file: "B"), ev(.opened, 2, file: "C"),
                      ev(.opened, 60, file: "D"), ev(.commented, 600, file: "A", text: "back to A")]
        let s = sessions(stream)[0]
        XCTAssertEqual(paths(s.files), ["A", "C", "D"])
    }

    func testLinkedFilePassedThroughQuicklyIsKept() {
        let stream = [ev(.opened, 0, file: "A"), ev(.linked, 0.5, file: "A", text: "B"),
                      ev(.opened, 1, file: "B"), ev(.opened, 2, file: "C")]
        let s = sessions(stream)[0]
        XCTAssertEqual(paths(s.files), ["A", "C"])
    }

    func testSearchesDoNotInterruptVisits() {
        let stream = [ev(.opened, 0, file: "A"), ev(.searched, 0.5, text: "churn"),
                      ev(.opened, 1, file: "B"), ev(.opened, 20, file: "C")]
        let s = sessions(stream)[0]
        XCTAssertEqual(paths(s.files), ["B", "C"])
        XCTAssertEqual(s.searches, ["churn"])
    }

    func testMinDwellIsTunable() {
        var t = TrailTuning()
        t.minDwell = 0
        let s = sessions([ev(.opened, 0, file: "A"), ev(.opened, 1, file: "B")], tuning: t)[0]
        XCTAssertEqual(paths(s.files), ["A", "B"])
    }

    // MARK: Files

    func testFilesInOrderOfFirstAppearanceDeduplicated() {
        let stream = opens(["A", "B", "A", "C", "B", "A"])
        let s = sessions(stream)[0]
        XCTAssertEqual(paths(s.files), ["A", "B", "C"])
        XCTAssertEqual(s.events.count, 6, "revisits stay in the event list")
    }

    func testCommentAndLinkEventsContributeFiles() {
        let stream = [ev(.commented, 0, file: "A", text: "hm"), ev(.searched, 5, text: "q"),
                      ev(.linked, 10, file: "B", text: "C")]
        let s = sessions(stream)[0]
        XCTAssertEqual(paths(s.files), ["A", "B"], "link targets are text, not files")
    }

    func testSearchOnlySessionHasNoFiles() {
        let s = sessions([ev(.searched, 0, text: "churn")])[0]
        XCTAssertEqual(s.files, [])
        XCTAssertEqual(s.filesToReopen, [])
        XCTAssertEqual(s.searches, ["churn"])
    }

    // MARK: Resume

    func testFilesToReopenPutsEachFileAtItsLastVisit() {
        XCTAssertEqual(paths(sessions(opens(["A", "B", "A"]))[0].filesToReopen), ["B", "A"])
        XCTAssertEqual(paths(sessions(opens(["A", "B", "A", "C", "B"]))[0].filesToReopen), ["A", "C", "B"])
    }

    func testFilesToReopenSkipsSearchesAndCountsComments() {
        let stream = opens(["A", "B"]) + [ev(.searched, 15, text: "x"), ev(.commented, 25, file: "A", text: "hm")]
        let s = sessions(stream)[0]
        XCTAssertEqual(paths(s.filesToReopen), ["B", "A"])
    }

    func testFilesToReopenSkipsPassThroughs() {
        let stream = [ev(.opened, 0, file: "A"), ev(.opened, 1, file: "B"),
                      ev(.opened, 2, file: "C"), ev(.opened, 10, file: "D")]
        XCTAssertEqual(paths(sessions(stream)[0].filesToReopen), ["C", "D"])
    }

    // MARK: Searches

    func testSearchAsYouTypeMergesIntoFinalQuery() {
        let s = sessions([ev(.searched, 0, text: "c"), ev(.searched, 1, text: "ch"), ev(.searched, 2, text: "churn")])[0]
        XCTAssertEqual(s.searches, ["churn"])
        XCTAssertEqual(s.events.count, 1)
        XCTAssertEqual(s.events[0].at, trailBase.addingTimeInterval(2))
    }

    func testSlowTypingStillMergesWhileEachStepIsWithinWindow() {
        let s = sessions([ev(.searched, 0, text: "c"), ev(.searched, 10, text: "ch"),
                          ev(.searched, 20, text: "chu"), ev(.searched, 30, text: "churn")])[0]
        XCTAssertEqual(s.searches, ["churn"])
    }

    func testBackspacingMergesToo() {
        let s = sessions([ev(.searched, 0, text: "churn"), ev(.searched, 1, text: "chur")])[0]
        XCTAssertEqual(s.searches, ["chur"])
    }

    func testMergeIgnoresCase() {
        let s = sessions([ev(.searched, 0, text: "Ch"), ev(.searched, 1, text: "churn")])[0]
        XCTAssertEqual(s.searches, ["churn"])
    }

    func testUnrelatedQueriesStaySeparate() {
        let s = sessions([ev(.searched, 0, text: "churn"), ev(.searched, 5, text: "pricing")])[0]
        XCTAssertEqual(s.searches, ["churn", "pricing"])
    }

    func testPrefixQueriesFarApartStaySeparate() {
        let s = sessions([ev(.searched, 0, text: "ch"), ev(.searched, 16, text: "churn")])[0]
        XCTAssertEqual(s.searches, ["ch", "churn"])
    }

    func testSearchesSeparatedByAnOpenStaySeparate() {
        let s = sessions([ev(.searched, 0, text: "c"), ev(.opened, 1, file: "A"), ev(.searched, 5, text: "ch")])[0]
        XCTAssertEqual(s.searches, ["c", "ch"])
    }

    func testCommentsAccessorKeepsOrder() {
        let stream = [ev(.opened, 0, file: "A"), ev(.commented, 5, file: "A", text: "one"),
                      ev(.opened, 10, file: "B"), ev(.commented, 15, file: "B", text: "two")]
        XCTAssertEqual(sessions(stream)[0].comments.map(\.text), ["one", "two"])
    }
}
