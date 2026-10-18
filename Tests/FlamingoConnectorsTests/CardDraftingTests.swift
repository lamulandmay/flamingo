import XCTest
@testable import FlamingoConnectors

final class CardDraftingTests: XCTestCase {
    private func shape(_ text: String = Fixtures.schoolText) throws -> FeedShape {
        FeedShape(try ICalendar(parsing: text), timeZone: Fixtures.newYork)
    }

    func testShapeCountsWithoutContent() throws {
        let s = try shape()
        XCTAssertEqual([s.events, s.todos, s.allDay, s.repeating, s.extensions], [4, 1, 1, 0, 0])
        XCTAssertEqual(s.properties, ["CATEGORIES", "DESCRIPTION", "DTEND", "DTSTAMP", "DTSTART", "DUE", "DURATION",
                                      "STATUS", "SUMMARY", "UID", "URL"])
        XCTAssertEqual(s.earliest, Fixtures.utc("2026-10-19T20:00:00Z"))
        XCTAssertEqual(s.latest, Fixtures.utc("2026-11-02T04:59:00Z"))
        XCTAssertEqual(s.summary, "4 events, 1 to-dos (1 all day, 0 repeating); properties: CATEGORIES, DESCRIPTION, DTEND, "
                       + "DTSTAMP, DTSTART, DUE, DURATION, STATUS, SUMMARY, UID, URL; dates 2026-10-19 to 2026-11-02")
        let recurring = try shape(Fixtures.recurringText)
        XCTAssertEqual([recurring.events, recurring.repeating], [6, 4])
    }

    /// The privacy line: what Claude may see of a feed holds no titles, words, UIDs, links or zones.
    func testShapeAndPromptCarryNoTitles() throws {
        let extra = Fixtures.calendar("""
        BEGIN:VEVENT
        UID:secret-uid@private.example
        DTSTART:20261020T100000Z
        SUMMARY:Therapy with Dr Rivera
        LOCATION:12 Hidden Lane
        X-SECRET-NAME:Rivera
        ATTENDEE;CN=Sam Patient:mailto:sam@private.example
        END:VEVENT
        """)
        let shapes = [try shape(), try shape(Fixtures.recurringText),
                      FeedShape(try ICalendar(parsing: ICalAdapter.text(extra)), timeZone: Fixtures.newYork)]
        XCTAssertEqual(shapes[2].extensions, 1)
        let forbidden = ["History", "essay", "Maths", "Museum", "Band", "English", "Upload", "portal", "Essay,Draft", "Exams",
                         "assign-1", "school.example", "tasks/1", "Amsterdam", "Eastern", "Swim", "Standup", "Birthday", "Chess",
                         "Therapy", "Rivera", "Hidden Lane", "secret-uid", "private.example", "Sam", "X-SECRET", "SECRET-NAME"]
        let encoder = JSONEncoder()
        for s in shapes {
            let json = String(decoding: try encoder.encode(s), as: UTF8.self)
            let prompt = CardDrafting.prompt(description: "My planner", host: "https://planner.example", shape: s).user
            for text in [json, s.summary, prompt] {
                for word in forbidden {
                    XCTAssertFalse(text.localizedCaseInsensitiveContains(word), "\(word) leaked: \(text)")
                }
            }
        }
    }

    func testPromptHasDescriptionHostAndShapeOnly() throws {
        let p = CardDrafting.prompt(description: "  ManageBac, only exams and essays \n", host: "https://school.example", shape: try shape())
        XCTAssertEqual(p.system, CardDrafting.system)
        XCTAssertTrue(p.user.hasPrefix("Description: ManageBac, only exams and essays\nHost: https://school.example\nShape: 4 events"))
        let bare = CardDrafting.prompt(description: "x", host: "", shape: nil).user
        XCTAssertTrue(bare.hasSuffix("Host: none\nShape: unknown"))
    }

    func testCardFromReply() throws {
        let reply = """
        Here's the card:
        ```json
        {"name": "ManageBac deadlines", "purpose": "Exams and essays due", "role": "Deadlines",
         "refreshMinutes": 2, "window": {"daysBack": "3", "daysAhead": 900}, "include": "exam, essay",
         "exclude": ["mock", 4], "weight": true}
        ```
        Let me know if you want changes.
        """
        let card = try CardDrafting.card(fromReply: reply, description: "my school planner", source: "https://school.example",
                                         adapter: .ical)
        XCTAssertEqual(card.id, "managebac-deadlines")
        XCTAssertEqual(card.name, "ManageBac deadlines")
        XCTAssertEqual(card.role, .deadlines)
        XCTAssertEqual(card.refreshMinutes, 5)
        XCTAssertEqual(card.window, ConnectorWindow(daysBack: 3, daysAhead: 366))
        XCTAssertEqual(card.include, ["exam", "essay"])
        XCTAssertEqual(card.exclude, ["mock"])
        XCTAssertEqual(card.weight, 1, "a bool is not a weight")
        XCTAssertEqual(card.createdBy, .claude)
        XCTAssertEqual(card.described, "my school planner")
        XCTAssertEqual(card.source, "https://school.example")

        let flat = try CardDrafting.card(fromReply: #"{"name":"X","daysBack":2,"role":"party"}"#, description: "", source: "", adapter: .ical)
        XCTAssertEqual(flat.window.daysBack, 2)
        XCTAssertEqual(flat.role, .reference)
        for bad in ["no json here", #"{"purpose":"x"}"#, #"{"name":"   "}"#, "} backwards {"] {
            XCTAssertThrowsError(try CardDrafting.card(fromReply: bad, description: "", source: "", adapter: .ical), bad) {
                XCTAssertEqual($0 as? ConnectorError, .badDraft)
            }
        }
    }

    func testHeuristicCard() throws {
        let school = CardDrafting.heuristicCard(description: "ManageBac homework and exams", source: "https://school.example", adapter: .ical)
        XCTAssertEqual(school.role, .deadlines)
        XCTAssertEqual(school.id, "managebac-homework-and-exams")
        XCTAssertEqual([school.refreshMinutes, school.window.daysBack, school.window.daysAhead], [60, 1, 60])
        XCTAssertEqual(school.weight, 1.5)
        XCTAssertEqual(school.createdBy, .person)

        XCTAssertEqual(CardDrafting.heuristicCard(description: "Work", source: "", adapter: .imap).role, .inbox)
        XCTAssertEqual(CardDrafting.heuristicCard(description: "Team meetings", source: "", adapter: .ical).role, .schedule)
        let todos = FeedShape(events: 2, todos: 9)
        XCTAssertEqual(CardDrafting.heuristicCard(description: "Stuff", source: "", adapter: .ical, shape: todos).role, .deadlines)

        let unnamed = CardDrafting.heuristicCard(description: "", source: "https://www.lincoln.edu", adapter: .ical)
        XCTAssertEqual(unnamed.name, "Lincoln")
        XCTAssertEqual(unnamed.role, .schedule)
        let long = CardDrafting.heuristicCard(description: "My school's planner with all of the important things\nsecond line",
                                              source: "", adapter: .ical)
        XCTAssertEqual(long.name, "My school's planner with all of")
        XCTAssertEqual(long.purpose, "My school's planner with all of the important things")
    }
}
