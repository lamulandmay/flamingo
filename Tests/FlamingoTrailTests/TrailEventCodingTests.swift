import XCTest
import FlamingoCore
@testable import FlamingoTrail

final class TrailEventCodingTests: XCTestCase {
    private let fixedID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func decode(_ json: String) throws -> TrailEvent {
        try JSONDecoder().decode(TrailEvent.self, from: Data(json.utf8))
    }

    private func storeEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return enc
    }

    // MARK: Round trip

    func testRoundTripAllKinds() throws {
        let events = [
            ev(.opened, 0, file: "decks/q3.pptx", anchor: FileAnchor(kind: .slide, value: "7")),
            ev(.commented, 0.5, file: "decks/q3.pptx", text: "Pricing contradicts [[q3-model.xlsx]]",
               anchor: FileAnchor(kind: .cell, value: "Q3!B12")),
            ev(.searched, 2, text: "churn"),
            ev(.linked, 3.25, file: "notes/a.md", text: "q3-model.xlsx"),
            ev(.opened, 4, file: "media/talk.mp4", anchor: FileAnchor(kind: .time, value: "1:23")),
        ]
        for e in events {
            for enc in [JSONEncoder(), storeEncoder()] {
                let back = try JSONDecoder().decode(TrailEvent.self, from: try enc.encode(e))
                XCTAssertEqual(back, e)
            }
        }
    }

    func testRoundTripKeepsMillisecondPrecision() throws {
        let e = TrailEvent(at: Date(), kind: .searched, text: "q")
        let back = try JSONDecoder().decode(TrailEvent.self, from: try JSONEncoder().encode(e))
        XCTAssertEqual(back.id, e.id)
        XCTAssertEqual(back.at.timeIntervalSince1970, e.at.timeIntervalSince1970, accuracy: 0.001)
    }

    func testEncodedLineIsCompact() throws {
        let e = TrailEvent(id: fixedID, at: trailBase, kind: .commented, file: ref("decks/q3.pptx"),
                           anchor: FileAnchor(kind: .slide, value: "7"), text: "see A/B")
        let line = String(decoding: try storeEncoder().encode(e), as: UTF8.self)
        XCTAssertEqual(line, #"{"anchor":"slide 7","at":"2026-10-14T20:05:12.000Z","file":"decks/q3.pptx","id":"11111111-2222-3333-4444-555555555555","kind":"commented","text":"see A/B"}"#)
        XCTAssertFalse(line.contains(#"\/"#))
        XCTAssertFalse(line.contains("\n"))
    }

    func testEncodingOmitsAbsentFields() throws {
        let line = String(decoding: try storeEncoder().encode(ev(.searched, 0, text: "churn", id: fixedID)), as: UTF8.self)
        XCTAssertEqual(line, #"{"at":"2026-10-14T20:05:12.000Z","id":"11111111-2222-3333-4444-555555555555","kind":"searched","text":"churn"}"#)
    }

    // MARK: Legacy and hand-written shapes

    func testDecodesSynthesizedLegacyShape() throws {
        // What the old synthesized Codable wrote: nested FileRef/FileAnchor, reference-date seconds.
        let e = try decode(#"{"id":"11111111-2222-3333-4444-555555555555","at":813701112,"kind":"opened","file":{"relativePath":"decks/q3.pptx"},"anchor":{"kind":"slide","value":"7"}}"#)
        XCTAssertEqual(e.id, fixedID)
        XCTAssertEqual(e.at, trailBase)
        XCTAssertEqual(e.kind, .opened)
        XCTAssertEqual(e.file, ref("decks/q3.pptx"))
        XCTAssertEqual(e.anchor, FileAnchor(kind: .slide, value: "7"))
        XCTAssertNil(e.text)
    }

    func testDecodesNumericDates() throws {
        let reference = try decode(#"{"at":813701112.5,"kind":"searched","text":"x"}"#)
        XCTAssertEqual(reference.at.timeIntervalSince(trailBase), 0.5, accuracy: 1e-6)
        let unixSeconds = try decode(#"{"at":1792008312,"kind":"searched","text":"x"}"#)
        XCTAssertEqual(unixSeconds.at, trailBase)
        let unixMillis = try decode(#"{"at":1792008312250,"kind":"searched","text":"x"}"#)
        XCTAssertEqual(unixMillis.at.timeIntervalSince(trailBase), 0.25, accuracy: 1e-6)
    }

    func testDecodesStringDates() throws {
        XCTAssertEqual(try decode(#"{"at":"2026-10-14T20:05:12Z","kind":"searched","text":"x"}"#).at, trailBase)
        XCTAssertEqual(try decode(#"{"at":"2026-10-14T20:05:12.000Z","kind":"searched","text":"x"}"#).at, trailBase)

        // Sidecar-style local time.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let local = cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 20, minute: 5, second: 12))!
        XCTAssertEqual(try decode(#"{"at":"2026-10-14 20:05:12","kind":"searched","text":"x"}"#).at, local)
        let minutes = cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 20, minute: 5))!
        XCTAssertEqual(try decode(#"{"at":"2026-10-14 20:05","kind":"searched","text":"x"}"#).at, minutes)
    }

    func testRejectsUnreadableDateOrKind() {
        XCTAssertThrowsError(try decode(#"{"at":"last tuesday","kind":"searched","text":"x"}"#))
        XCTAssertThrowsError(try decode(#"{"at":"2026-10-14T20:05:12Z","kind":"teleported"}"#))
        XCTAssertThrowsError(try decode(#"{"kind":"searched","text":"x"}"#))
    }

    func testDecodesAnchorStrings() throws {
        let plain = try decode(#"{"at":"2026-10-14T20:05:12Z","kind":"opened","file":"a.pdf","anchor":"page 12"}"#)
        XCTAssertEqual(plain.anchor, FileAnchor(kind: .page, value: "12"))
        let rendered = try decode(#"{"at":"2026-10-14T20:05:12Z","kind":"opened","file":"q3.xlsx","anchor":"(cell Q3!B12)"}"#)
        XCTAssertEqual(rendered.anchor, FileAnchor(kind: .cell, value: "Q3!B12"))
        // An anchor we can't read is dropped, not fatal.
        let unknown = try decode(#"{"at":"2026-10-14T20:05:12Z","kind":"opened","file":"a.pdf","anchor":"chapter 3"}"#)
        XCTAssertNil(unknown.anchor)
        XCTAssertEqual(unknown.file, ref("a.pdf"))
        let bare = try decode(#"{"at":"2026-10-14T20:05:12Z","kind":"opened","file":"a.pdf","anchor":"page"}"#)
        XCTAssertNil(bare.anchor)
    }

    func testParseAnchor() {
        XCTAssertEqual(TrailEvent.parseAnchor("slide 7"), FileAnchor(kind: .slide, value: "7"))
        XCTAssertEqual(TrailEvent.parseAnchor(" (slide 7) "), FileAnchor(kind: .slide, value: "7"))
        XCTAssertEqual(TrailEvent.parseAnchor("region 10 20 30 40"), FileAnchor(kind: .region, value: "10 20 30 40"))
        XCTAssertNil(TrailEvent.parseAnchor("slide"))
        XCTAssertNil(TrailEvent.parseAnchor("slide   "))
        XCTAssertNil(TrailEvent.parseAnchor(""))
    }

    func testEmptyFileStringMeansNoFile() throws {
        XCTAssertNil(try decode(#"{"at":"2026-10-14T20:05:12Z","kind":"searched","file":"","text":"x"}"#).file)
    }

    // MARK: Ids

    func testMissingIdIsDerivedDeterministically() throws {
        let line = #"{"at":"2026-10-14T20:05:12Z","kind":"opened","file":"decks/q3.pptx","anchor":"slide 7"}"#
        let a = try decode(line), b = try decode(line)
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(Array(a.id.uuidString)[14], "3", "name-based ids are version 3")

        let other = try decode(#"{"at":"2026-10-14T20:05:12Z","kind":"opened","file":"decks/q3.pptx","anchor":"slide 8"}"#)
        XCTAssertNotEqual(a.id, other.id)
        let later = try decode(#"{"at":"2026-10-14T20:05:13Z","kind":"opened","file":"decks/q3.pptx","anchor":"slide 7"}"#)
        XCTAssertNotEqual(a.id, later.id)
    }

    func testDerivedIdIgnoresSpelling() throws {
        // The same event in every accepted spelling gets the same derived id.
        let spellings = [
            #"{"at":"2026-10-14T20:05:12Z","kind":"opened","file":"decks/q3.pptx","anchor":"slide 7"}"#,
            #"{"at":"2026-10-14T20:05:12.000Z","kind":"opened","file":"decks/q3.pptx","anchor":"(slide 7)"}"#,
            #"{"at":813701112,"kind":"opened","file":{"relativePath":"decks/q3.pptx"},"anchor":{"kind":"slide","value":"7"}}"#,
            #"{"at":1792008312,"kind":"opened","file":"decks/q3.pptx","anchor":"slide 7"}"#,
        ]
        let ids = try Set(spellings.map { try decode($0).id })
        XCTAssertEqual(ids.count, 1)
    }

    func testInvalidIdFallsBackToDerived() throws {
        let line = #"{"id":"not-a-uuid","at":"2026-10-14T20:05:12Z","kind":"searched","text":"x"}"#
        let noID = #"{"at":"2026-10-14T20:05:12Z","kind":"searched","text":"x"}"#
        XCTAssertEqual(try decode(line).id, try decode(noID).id)
    }
}
