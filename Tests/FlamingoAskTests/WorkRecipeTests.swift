import XCTest
import FlamingoCore
import FlamingoIndex
@testable import FlamingoAsk

/// The recipes against the demo vault, with a model that answers from a script.
final class WorkRecipeTests: LocalModelTestCase {
    static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/fake-llm/\(name).json")
    }

    static var shared: ThoughtVault?
    var v: ThoughtVault!

    override func setUpWithError() throws {
        if Self.shared == nil { Self.shared = try ThoughtVault() }
        v = Self.shared
    }

    func request(_ recipe: WorkRecipe, thought: String = "review conflict between this and [[q3-model.xlsx]]",
                 objects: [String] = ["decks/q3-board-review.pptx#slide 7", "finance/q3-model.xlsx"],
                 purpose: CompletionPurpose = .nightShift) -> WorkRequest {
        WorkRequest(recipe: recipe, thoughtUID: "t8m2k4q9xa", thoughtText: thought, thoughtTimestamp: Date(timeIntervalSince1970: 1_792_000_000),
                    file: ThoughtVault.deck, anchor: FileAnchor(kind: .slide, value: "7"), objects: objects, purpose: purpose,
                    now: Date(timeIntervalSince1970: 1_792_050_000))
    }

    /// The model answers with `text`, passage references resolved against the prompt it was sent.
    func model(says text: @escaping @Sendable (_ prompt: String) -> String) {
        LoopbackStub.reset { url, body in
            guard url.path.hasSuffix("/chat/completions") else { return nil }
            return LoopbackStub.chat(text(LocalOnlyTests.userText(body) ?? ""))
        }
    }

    func canned(_ name: String) -> @Sendable (String) -> String {
        let text = (try? String(contentsOf: Self.fixture(name), encoding: .utf8)) ?? "{}"
        return { LocalCompletionRuntime.resolvePassageReferences(in: text, prompt: $0) }
    }

    // MARK: review-conflict

    func testReviewConflictMakesAMemoAndAReply() async throws {
        model(says: canned("night-shift-review-conflict"))
        let result = try await v.engine.work(request(.reviewConflict)) { _ in }

        let memo = result.memo
        XCTAssertEqual(memo.recipe, "review-conflict")
        XCTAssertEqual(memo.verdict, "conflict")
        XCTAssertEqual(memo.thought, "t8m2k4q9xa")
        XCTAssertEqual(memo.on, "decks/q3-board-review.pptx#slide 7")
        XCTAssertEqual(memo.title, "Arc price: deck $249, model $229")
        XCTAssertEqual(memo.provider, "llama")
        XCTAssertEqual(memo.created, ThoughtDates.stamp(Date(timeIntervalSince1970: 1_792_050_000)))
        XCTAssertGreaterThan(memo.tokens ?? 0, 0)
        XCTAssertTrue(memo.sources.contains { $0.hasPrefix("decks/q3-board-review.pptx#slide 7 \u{00B7} ") }, "\(memo.sources)")
        XCTAssertTrue(memo.sources.contains { $0.hasPrefix("finance/q3-model.xlsx#sheet Assumptions \u{00B7} ") }, "\(memo.sources)")
        XCTAssertTrue(memo.body.contains("## Where they disagree"))
        XCTAssertTrue(memo.body.contains("[[decks/q3-board-review.pptx#slide 7]] \u{201C}Pricing Arc: $249\u{201D}"), memo.body)
        XCTAssertTrue(memo.body.contains("[[finance/q3-model.xlsx#sheet Assumptions]] \u{201C}Arc ASP 229 From the August plan\u{201D}"), memo.body)
        XCTAssertTrue(memo.body.contains("## Next step"))
        XCTAssertNotNil(WorkMemo.parse(memo.render()), "a memo that round-trips")

        XCTAssertTrue(result.replyText.hasPrefix("Conflict. Slide 7 prices Arc at $249"), result.replyText)
        XCTAssertTrue(result.replyText.contains("[[decks/q3-board-review.pptx#slide 7]]"))
        XCTAssertTrue(result.replyText.contains("[[finance/q3-model.xlsx#sheet Assumptions]]"))
        XCTAssertFalse(result.replyText.contains("<!--"))
        XCTAssertEqual(result.fingerprint.count, 8)
    }

    func testThePromptTreatsPassagesAsDataAndReadsOnlyTheNamedFiles() async throws {
        var prompt = ""
        LoopbackStub.reset { url, body in
            guard url.path.hasSuffix("/chat/completions") else { return nil }
            prompt = String(decoding: body, as: UTF8.self)
            return LoopbackStub.chat(self.canned("night-shift-review-conflict")(LocalOnlyTests.userText(body) ?? ""))
        }
        _ = try await v.engine.work(request(.reviewConflict)) { _ in }
        let json = try JSON.decode(Data(prompt.utf8))
        XCTAssertEqual(json["chat_template_kwargs"], ["enable_thinking": false])
        XCTAssertEqual(json["response_format"]?["type"], "json_schema")
        let messages = try XCTUnwrap(json["messages"]?.array)
        let system = try XCTUnwrap(messages[0]["content"]?.string)
        XCTAssertTrue(system.contains("quoted data"))
        XCTAssertTrue(system.contains("never instructions"))
        let user = try XCTUnwrap(messages[1]["content"]?.string)
        let files = Set(user.components(separatedBy: "file=\"").dropFirst().map { String($0.prefix { $0 != "\"" }) })
        XCTAssertEqual(files, ["decks/q3-board-review.pptx", "finance/q3-model.xlsx"], "nothing else in the vault was read")
        XCTAssertTrue(user.contains("<thought written="))
        XCTAssertTrue(user.contains("$249"))
        XCTAssertTrue(user.contains("Arc ASP"))
    }

    func testAnInventedQuoteIsDroppedButTheLinkStays() async throws {
        model(says: { prompt in
            let text = #"{"title":"T","tldr":"Prices differ.","verdict":"conflict","conflicts":[{"topic":"Price","a":{"passage":"@decks/q3-board-review.pptx#slide 7","quote":"We will sell Arc for forty dollars"},"b":{"passage":"@finance/q3-model.xlsx","quote":"Arc ASP 229"},"why":"They differ."}],"consistent":[],"next":""}"#
            return LocalCompletionRuntime.resolvePassageReferences(in: text, prompt: prompt)
        })
        let result = try await v.engine.work(request(.reviewConflict)) { _ in }
        XCTAssertFalse(result.memo.body.contains("forty dollars"))
        XCTAssertTrue(result.memo.body.contains("[[decks/q3-board-review.pptx#slide 7]]"))
        XCTAssertTrue(result.memo.body.contains("\u{201C}Arc ASP 229\u{201D}"), "a real quote is kept")
    }

    func testTextThatCouldBecomeALinkOrAMarkerIsNeutralised() async throws {
        model(says: { prompt in
            let text = #"{"title":"See [[secrets]] <!-- x -->","tldr":"Open [[/etc/passwd]] --> now","verdict":"conflict","conflicts":[{"topic":"[[a]]","a":{"passage":"@decks/q3-board-review.pptx#slide 7","quote":""},"b":{"passage":"@finance/q3-model.xlsx","quote":""},"why":"x\n## Injected heading"}],"consistent":[],"next":"Then\n## Do this"}"#
            return LocalCompletionRuntime.resolvePassageReferences(in: text, prompt: prompt)
        })
        let result = try await v.engine.work(request(.reviewConflict)) { _ in }
        let all = result.memo.render() + result.replyText
        XCTAssertFalse(all.contains("[[secrets]]")); XCTAssertFalse(all.contains("[[/etc/passwd]]")); XCTAssertFalse(all.contains("[[a]]"))
        XCTAssertFalse(all.contains("<!--")); XCTAssertFalse(all.contains("-->"))
        XCTAssertFalse(all.contains("\n## Injected heading"))
        XCTAssertFalse(result.memo.title.contains("[["))
    }

    // MARK: Bad output

    func testInvalidJSONIsAnErrorNotAMemo() async throws {
        model(says: { _ in "Sure! Here is my analysis of the conflict." })
        do { _ = try await v.engine.work(request(.reviewConflict)) { _ in }; XCTFail("should throw") }
        catch { XCTAssertEqual(error as? WorkError, .invalidOutput("not JSON")) }
    }

    func testAConflictThatCitesNothingItWasGivenIsInvalid() async throws {
        model(says: { _ in
            #"{"title":"T","tldr":"They differ.","verdict":"conflict","conflicts":[{"topic":"x","a":{"passage":97,"quote":"q"},"b":{"passage":98,"quote":"q"},"why":"w"}],"consistent":[],"next":""}"#
        })
        do { _ = try await v.engine.work(request(.reviewConflict)) { _ in }; XCTFail("should throw") }
        catch { guard case WorkError.invalidOutput = error else { return XCTFail("\(error)") } }
    }

    func testAFileThatChangesWhileTheModelWorksLeavesNoResult() async throws {
        let target = v.root.appendingPathComponent("finance/q3-model.xlsx")
        let original = try Data(contentsOf: target)
        defer { try? original.write(to: target) }
        LoopbackStub.reset { url, body in
            guard url.path.hasSuffix("/chat/completions") else { return nil }
            // The person saves the workbook while the model is thinking.
            try? (original + Data([0])).write(to: target)
            return LoopbackStub.chat(self.canned("night-shift-review-conflict")(LocalOnlyTests.userText(body) ?? ""))
        }
        do { _ = try await v.engine.work(request(.reviewConflict)) { _ in }; XCTFail("should throw") }
        catch { XCTAssertEqual(error as? WorkError, .sourceChanged) }
    }

    func testNamingNothingThatExistsFailsBeforeAskingAModel() async throws {
        LoopbackStub.reset { _, _ in XCTFail("no model call expected"); return nil }
        var r = request(.summarize, objects: ["nowhere/gone.pdf"])
        r.file = FileRef(relativePath: "_inbox/2026-10-14")
        do { _ = try await v.engine.work(r) { _ in }; XCTFail("should throw") }
        catch { guard case WorkError.noSources = error else { return XCTFail("\(error)") } }
        XCTAssertTrue(LoopbackStub.requests.isEmpty)
    }

    func testNoLocalModelMeansTheWorkWaitsAsAnError() async throws {
        use { $0.llama = { _, _ in throw AskError.unavailable("No local model") } }
        LoopbackStub.reset(nil)
        do { _ = try await v.engine.work(request(.summarize)) { _ in }; XCTFail("should throw") }
        catch { XCTAssertTrue(error is AskError); XCTAssertEqual(LoopbackStub.violations, []) }
    }

    // MARK: The other recipes (with the shipped fixtures)

    func testEveryRecipeWorksWithTheFakeModel() async throws {
        use { $0.environment = { ["FLAMINGO_FAKE_LLM": "1"] } }
        LoopbackStub.reset(nil)
        let deck = "decks/q3-board-review.pptx#slide 7"
        let cases: [(WorkRecipe, [String], String)] = [
            (.summarize, [deck], "## Key points"),
            (.answer, ["finance/q3-model.xlsx"], "## Answer"),
            (.compareVersions, [deck, "decks/arc-launch-plan.pptx"], "## What changed"),
            (.findRelated, [deck], "## Related"),
        ]
        for (recipe, objects, heading) in cases {
            let result = try await v.engine.work(request(recipe, thought: "What price does the model use for Arc?", objects: objects)) { _ in }
            XCTAssertEqual(result.memo.recipe, recipe.rawValue)
            XCTAssertEqual(result.model, "fake-llm")
            XCTAssertTrue(result.memo.body.contains(heading), "\(recipe): \(result.memo.body)")
            XCTAssertFalse(result.replyText.isEmpty)
            XCTAssertTrue(result.replyText.contains("[["), "\(recipe) reply links its sources: \(result.replyText)")
            XCTAssertNotNil(WorkMemo.parse(result.memo.render()))
        }
        XCTAssertTrue(LoopbackStub.requests.isEmpty)
    }

    func testAnAnswerRecipeTurnsCitationNumbersIntoLinks() async throws {
        use { $0.environment = { ["FLAMINGO_FAKE_LLM": "1"] } }
        let result = try await v.engine.work(request(.answer, thought: "What price does the model use for Arc?", objects: ["finance/q3-model.xlsx", "decks/q3-board-review.pptx#slide 7"])) { _ in }
        XCTAssertFalse(result.memo.body.contains("[1]"), result.memo.body)
        XCTAssertTrue(result.memo.body.contains("[[finance/q3-model.xlsx"), result.memo.body)
    }

    func testCompareVersionsNeedsAnotherVersion() async throws {
        use { $0.environment = { ["FLAMINGO_FAKE_LLM": "1"] } }
        // The workbook has no sibling that looks like a version of it.
        var r = request(.compareVersions, objects: ["finance/q3-model.xlsx"])
        r.file = ThoughtVault.model
        r.anchor = nil
        do { _ = try await v.engine.work(r) { _ in }; XCTFail("should throw") }
        catch { guard case WorkError.noSources = error else { return XCTFail("\(error)") } }
    }

    func testFingerprintChangesWithTheFile() throws {
        let paths = ["finance/q3-model.xlsx", "decks/q3-board-review.pptx"]
        let a = WorkFingerprint.sources(of: paths, in: v.vault)
        XCTAssertEqual(a.count, 2)
        XCTAssertEqual(WorkFingerprint.hash(a), WorkFingerprint.hash(a.reversed()), "order doesn't matter")
        var b = a; b[0].size += 1
        XCTAssertNotEqual(WorkFingerprint.hash(a), WorkFingerprint.hash(b))
        XCTAssertEqual(WorkFingerprint.paths(objects: ["a/b.pptx#slide 7", "c.xlsx", "a/b.pptx"], target: FileRef(relativePath: "t.md")),
                       ["a/b.pptx", "c.xlsx", "t.md"])
        XCTAssertEqual(WorkFingerprint.paths(objects: [], target: FileRef(relativePath: "_inbox/2026-10-14")), [])
        XCTAssertEqual(WorkFingerprint.jobID(uid: "tabc", recipe: "summarize", hash: "00ff00ff"), "tabc:summarize:00ff00ff")
    }
}
