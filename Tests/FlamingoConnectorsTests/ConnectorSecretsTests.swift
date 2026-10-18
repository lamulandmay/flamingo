import XCTest
import Security
@testable import FlamingoConnectors

/// Only the environment path runs here: under XCTest the Keychain is switched off, so nothing
/// below can raise its access prompt.
final class ConnectorSecretsTests: XCTestCase {
    func testKeychainIsOffInTests() {
        XCTAssertFalse(ConnectorSecrets.keychainEnabled)
        XCTAssertNil(ConnectorSecrets.stored("school"))
        XCTAssertThrowsError(try ConnectorSecrets.save("https://x.example/feed", for: "school")) {
            XCTAssertEqual($0 as? ConnectorError, .keychain(errSecNotAvailable))
        }
        XCTAssertNoThrow(try ConnectorSecrets.remove(for: "school"))
    }

    func testSaveChecksBeforeTheKeychain() {
        XCTAssertThrowsError(try ConnectorSecrets.save("https://x.example", for: "../x")) {
            XCTAssertEqual($0 as? ConnectorError, .invalidID)
        }
        XCTAssertThrowsError(try ConnectorSecrets.save("  \n", for: "school")) {
            XCTAssertEqual($0 as? ConnectorError, .missingSecret)
        }
    }

    func testEnvironmentFirst() {
        XCTAssertEqual(ConnectorSecrets.environmentName(for: "managebac-2"), "FLAMINGO_CONNECTOR_MANAGEBAC_2")
        let env = ["FLAMINGO_CONNECTOR_SCHOOL": "  https://school.example/feed.ics?t=1 \n", "FLAMINGO_CONNECTOR_BLANK": "  "]
        XCTAssertEqual(ConnectorSecrets.secret(for: "school", environment: env), "https://school.example/feed.ics?t=1")
        XCTAssertNil(ConnectorSecrets.secret(for: "blank", environment: env))
        XCTAssertNil(ConnectorSecrets.secret(for: "other", environment: env))
    }

    func testFeedLinkKeepsOnlyTheHost() throws {
        let link = try ConnectorSecrets.feedLink("webcal://User:Pass@School.Example/ical/abc123.ics?token=SECRET")
        XCTAssertEqual(link.source, "https://school.example")
        XCTAssertTrue(link.secret.hasPrefix("https://"))
        XCTAssertTrue(link.secret.contains("token=SECRET"))
        XCTAssertFalse(link.source.contains("abc123") || link.source.contains("Pass"))
        let port = try ConnectorSecrets.feedLink("https://cal.example:8443/f.ics")
        XCTAssertEqual(port.source, "https://cal.example:8443")
        XCTAssertThrowsError(try ConnectorSecrets.feedLink("not a link")) { XCTAssertEqual($0 as? ConnectorError, .invalidSource) }
        XCTAssertThrowsError(try ConnectorSecrets.feedLink("file:///etc/passwd"))
    }

    func testErrorMessagesNeverCarryTheAddress() {
        let all: [ConnectorError] = [.invalidID, .invalidSource, .missingSecret, .unsupported(.imap), .network,
                                     .httpStatus(401), .httpStatus(404), .httpStatus(500), .tooLarge, .notCalendar,
                                     .unreadable, .accessDenied, .keychain(-25300), .storage, .badDraft]
        for error in all {
            XCTAssertFalse(error.message.isEmpty)
            XCTAssertFalse(error.message.contains("http"), error.message)
        }
        XCTAssertEqual(ConnectorError.missingSecret.message, "Feed address missing")
    }
}
