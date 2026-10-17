import XCTest
@testable import FlamingoCore

final class ThoughtRulesTests: XCTestCase {
    private func read(_ text: String, at stamp: String = "2026-10-16 18:40") -> ThoughtReading {
        ThoughtRules.read(text, at: SidecarFormat.timestamp(from: stamp)!)
    }

    /// Every thought in fixtures/vault, labelled by hand before looking at what the rules say.
    /// `todo` for something to do, `intent` for something a model could do for me, `question`, `idea` for the rest.
    static let labels: [String: ThoughtKind] = [
        "research/market-sizing.pdf|2026-10-07 11:02": .idea,
        "research/interview-maya-chen.m4a|2026-10-14 09:41": .idea,
        "research/interview-maya-chen.m4a|2026-10-14 09:43": .idea,
        "design/whiteboard-pricing.jpg|2026-10-13 14:23": .idea,
        "design/arc-lamp.usdz|2026-10-14 10:13": .question,
        "design/moodboard.jpg|2026-10-02 10:15": .idea,
        "design/arc-render.png|2026-10-02 10:20": .todo,
        "tools/forecast.py|2026-10-06 16:30": .todo,
        "docs/arc-product-brief.docx|2026-09-28 16:02": .idea,
        "docs/arc-product-brief.docx|2026-10-14 09:48": .todo,
        "docs/pricing-memo.docx|2026-10-13 14:19": .todo,
        "decks/arc-launch-plan.pptx|2026-10-14 09:36": .todo,
        "decks/q3-board-review.pptx|2026-10-08 17:20": .todo,
        "decks/q3-board-review.pptx|2026-10-08 17:31": .todo,
        "decks/q3-board-review.pptx|2026-10-09 08:45": .todo,
        "decks/q3-board-review.pptx|2026-10-13 14:11": .idea,
        "notes/pricing-decisions.md|2026-10-13 14:38": .todo,
        "finance/q3-model.xlsx|2026-10-13 14:44": .todo,
        "finance/unit-economics.xlsx|2026-10-13 14:31": .idea,
        "finance/unit-economics.xlsx|2026-10-14 10:06": .idea,
        "legal/supplier-agreement.pdf|2026-10-14 09:55": .intent,
        "legal/supplier-agreement.pdf|2026-10-14 10:01": .todo,
        "media/arc-teaser.mp4|2026-10-14 10:18": .todo,
    ]

    func testFixtureThoughtsAgreeWithHandLabels() throws {
        let notes = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../fixtures/vault/.flamingo/notes").standardized
        let vault = Vault(root: notes.deletingLastPathComponent().deletingLastPathComponent())
        let store = SidecarStore(vault: vault)
        var checked = 0, agreed = 0
        var disagreements: [String] = []
        for ref in try store.sidecarRefs() {
            for c in try store.comments(for: ref) {
                let key = ref.relativePath + "|" + SidecarFormat.string(fromTimestamp: c.timestamp)
                guard let expected = Self.labels[key] else { XCTFail("unlabelled thought \(key)"); continue }
                let got = ThoughtRules.read(c.text, at: c.timestamp).kind
                checked += 1
                if got == expected { agreed += 1 } else { disagreements.append("\(key): labelled \(expected), rules say \(got): \(c.text)") }
            }
        }
        XCTAssertEqual(checked, 23)
        XCTAssertGreaterThanOrEqual(Double(agreed) / Double(checked), 0.90, disagreements.joined(separator: "\n"))
        print("thought rules agreement \(agreed)/\(checked)", disagreements)
    }

    func testQuestions() {
        XCTAssertEqual(read("Which one went to Ningbo?").kind, .question)
        XCTAssertEqual(read("why is the model still at $229？").kind, .question)
        XCTAssertEqual(read("what price does the model use").kind, .question)
        XCTAssertEqual(read("Should we go with option C").kind, .question)
        XCTAssertEqual(read("这个价格合适吗").kind, .question)
        XCTAssertEqual(read("为什么模型还是用229美元").kind, .question)
        XCTAssertEqual(read("怎么处理这个冲突").kind, .question)
        XCTAssertEqual(read("Is this right?\n> Arc — $249").kind, .question)
        XCTAssertEqual(read("Home offices should be a rounding error").kind, .idea)
    }

    func testIntents() {
        XCTAssertEqual(read("review conflict between this and [[q3-model.xlsx]] before friday").kind, .intent)
        XCTAssertEqual(read("Compare the two versions of [[pricing-memo.docx]]").kind, .intent)
        XCTAssertEqual(read("Summarize [[supplier-agreement.pdf#page 3]]").kind, .intent)
        XCTAssertEqual(read("Check slide 7 against the model").kind, .intent)
        XCTAssertEqual(read("对比 [[a.docx]] 和 [[b.docx]] 的版本差异").kind, .intent)
        XCTAssertEqual(read("请核对 [[q3-model.xlsx]]").kind, .intent)
        XCTAssertEqual(read("Check the settings tomorrow").kind, .todo, "an AI verb with nothing to look at is just a chore")
    }

    func testTodosAndIdeas() {
        XCTAssertEqual(read("Call Tom about the PO").kind, .todo)
        XCTAssertEqual(read("remember to update the deck").kind, .todo)
        XCTAssertEqual(read("I need to ship this by friday").kind, .todo)
        XCTAssertEqual(read("Pricing looks fine, then email Maya").kind, .todo)
        XCTAssertEqual(read("记得给供应商发邮件").kind, .todo)
        XCTAssertEqual(read("联系 Tom 确认交期").kind, .todo)
        XCTAssertEqual(read("Coral only on the packaging").kind, .idea)
        XCTAssertEqual(read("这个想法很有意思").kind, .idea)
        XCTAssertEqual(read("").kind, .idea)
        XCTAssertEqual(read("> Arc — $249 retail\n> Call Tom").kind, .idea, "a quoted selection is not what the person said")
    }

    func testMentionsAndRecipes() {
        XCTAssertEqual(read("@ai what price does the model use?").mentions, ["ai"])
        XCTAssertEqual(read("hey @Flamingo and @ai, summarize [[x.pdf]]").mentions, ["flamingo", "ai"])
        XCTAssertTrue(read("me@ai.example.com is the address").mentions.isEmpty)
        XCTAssertEqual(read("@ai what does [[q3-model.xlsx]] assume?").kind, .question)
        XCTAssertEqual(read("@ai what does [[q3-model.xlsx]] assume?").recipe, "answer")
        XCTAssertEqual(read("review conflict between this and [[q3-model.xlsx]]").recipe, "review-conflict")
        XCTAssertEqual(read("compare the versions of [[a.docx]]").recipe, "compare-versions")
        XCTAssertEqual(read("Summarize [[a.pdf]]").recipe, "summarize")
        XCTAssertEqual(read("Coral only").recipe, nil)
    }

    func testDueIsReadFromTheThoughtsOwnTimestamp() throws {
        // 2026-10-16 is a Friday.
        let r = read("review conflict between this and [[q3-model.xlsx]] before friday")
        XCTAssertEqual(r.due?.string(), "2026-10-23", "friday written on a friday means next friday")
        XCTAssertEqual(read("Call Tom tomorrow", at: "2026-10-13 09:00").due?.string(), "2026-10-14")
        XCTAssertEqual(read("Date card should say November 18, not just November. Matches [[a.pptx#slide 3]]").due?.string(), "2026-11-18")
        XCTAssertNil(read("Coral only on the packaging until friday").due, "an idea with no deadline word has no due date")
        XCTAssertNotNil(read("Send the deck by friday").due)
    }

    func testActionsProposedFromWords() {
        let file = FileRef(relativePath: "decks/q3.pptx")
        let model = FileRef(relativePath: "finance/q3-model.xlsx")
        let c = Comment(timestamp: SidecarFormat.timestamp(from: "2026-10-16 18:40")!, anchor: FileAnchor(kind: .slide, value: "7"),
                        text: "@ai review conflict between this and [[q3-model.xlsx]] before friday")
        let rules = ThoughtRules.read(c.text, at: c.timestamp)
        let actions = ThoughtAction.proposed(for: c, rules: rules, resolvedLinks: [model], file: file)
        XCTAssertEqual(actions.first, .ask(mention: "ai", scope: ["decks/q3.pptx#slide 7", "finance/q3-model.xlsx"]))
        XCTAssertTrue(actions.contains(.work(recipe: "review-conflict", objects: ["decks/q3.pptx#slide 7", "finance/q3-model.xlsx"])))
        XCTAssertTrue(actions.contains { if case .remind = $0 { return true } else { return false } })
        XCTAssertTrue(actions.contains(.connect("decks/q3.pptx", "finance/q3-model.xlsx")))
        let plain = Comment(text: "Coral only on the packaging")
        XCTAssertEqual(ThoughtAction.proposed(for: plain, rules: ThoughtRules.read(plain.text, at: plain.timestamp), resolvedLinks: []), [])
        let codable = try? JSONDecoder().decode([ThoughtAction].self, from: JSONEncoder().encode(actions))
        XCTAssertEqual(codable, actions)
    }
}
