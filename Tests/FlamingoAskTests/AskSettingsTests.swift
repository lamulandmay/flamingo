import XCTest
import FlamingoCore
import FlamingoIndex
@testable import FlamingoAsk

final class AskSettingsTests: XCTestCase {
    func testKeyCheckTellsAWorkingKeyFromARejectedOne() async {
        MockAPI.reset([MockAPI.Reply(status: 200, body: Data(#"{"data":[]}"#.utf8))])
        let valid = await KeyCheck.run("sk-ant-good", session: MockAPI.session)
        XCTAssertEqual(valid, .valid)
        let request = MockAPI.requests.first?.request
        XCTAssertEqual(request?.url?.path, "/v1/models")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "x-api-key"), "sk-ant-good")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

        MockAPI.reset([SSE.error(401, "authentication_error", "invalid x-api-key")])
        let rejected = await KeyCheck.run("sk-ant-typo", session: MockAPI.session)
        XCTAssertEqual(rejected, .rejected)
    }

    func testKeyCheckThatCannotTellIsUnchecked() async {
        MockAPI.reset([SSE.error(529, "overloaded_error", "Overloaded")])
        let overloaded = await KeyCheck.run("sk-ant-x", session: MockAPI.session)
        XCTAssertEqual(overloaded, .unchecked, "a key is saved, not refused, when Anthropic can't answer")
    }

    func testTestsNeverTouchTheLoginKeychain() throws {
        XCTAssertFalse(KeyStore.keychainEnabled, "a test run reading the user's key raises an access prompt")
        try XCTSkipIf(KeyStore.keychainEnabled)
        XCTAssertNil(KeyStore.stored())
        XCTAssertThrowsError(try KeyStore.save("sk-ant-test"), "a test key never lands in the user's Keychain")
        XCTAssertNoThrow(try KeyStore.remove())
    }

    func testEngineFollowsTheModelChosenInSettings() throws {
        let saved = UserDefaults.standard.string(forKey: "FlamingoClaudeModel")
        defer { UserDefaults.standard.set(saved, forKey: "FlamingoClaudeModel") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let engine = AskEngine(index: try IndexStore(vault: Vault(root: dir)), source: Fixture.vault,
                               client: MockAPI.client, key: { "sk-test" })

        AskEngine.preferredModel = AskEngine.defaultModel
        XCTAssertNil(UserDefaults.standard.string(forKey: "FlamingoClaudeModel"), "the default isn't written down")
        XCTAssertEqual(engine.model, "claude-sonnet-5-5")

        AskEngine.preferredModel = "claude-opus-5-5"
        XCTAssertEqual(engine.model, "claude-opus-5-5", "an existing engine picks up the change")

        engine.model = "claude-haiku-5-5"
        XCTAssertEqual(engine.model, "claude-haiku-5-5", "a model set on the engine wins")
    }

    func testEveryListedModelGetsAValidRequest() {
        for (id, _) in AskSettingsPane.models {
            let body = Prompt.body(model: id, messages: [])
            XCTAssertEqual(body["output_config"]?["effort"], "low", "\(id) takes effort")
            XCTAssertNil(body["thinking"], "\(id): thinking stays adaptive; disabling it is a 400 on these models")
        }
    }
}
