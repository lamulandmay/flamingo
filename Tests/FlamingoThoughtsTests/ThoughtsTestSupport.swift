import XCTest
import FlamingoCore
import FlamingoAsk
@testable import FlamingoIndex
@testable import FlamingoThoughts

/// New York, so a test date means the same wall clock on every machine, and DST is real.
let testCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    c.locale = Locale(identifier: "en_US_POSIX")
    return c
}()

/// `"2026-10-17 02:00"` in New York.
func at(_ text: String, _ calendar: Calendar = testCalendar) -> Date {
    let f = DateFormatter()
    f.calendar = calendar
    f.timeZone = calendar.timeZone
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = text.count > 10 ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
    return f.date(from: text)!
}

/// A vault in a temporary folder with a few real files and everything that reads it.
class ThoughtsTestCase: XCTestCase {
    var root: URL!
    var vault: Vault!
    var store: SidecarStore!

    static let deck = FileRef(relativePath: "decks/q3-board-review.pptx")
    static let model = FileRef(relativePath: "finance/q3-model.xlsx")
    static let memo = FileRef(relativePath: "docs/pricing-memo.docx")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("thoughts-\(UUID().uuidString)")
        for (path, text) in [("decks/q3-board-review.pptx", "slide 7 pricing"), ("finance/q3-model.xlsx", "Arc ASP 229"),
                             ("docs/pricing-memo.docx", "options a b c")] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        vault = Vault(root: root)
        store = SidecarStore(vault: vault)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A thought record as the index would give it.
    func record(_ text: String, file: FileRef = ThoughtsTestCase.deck, anchor: FileAnchor? = FileAnchor(kind: .slide, value: "7"),
                at timestamp: Date, uid: String? = "tabc123456", kind: ThoughtKind = .intent, action: String? = "review-conflict",
                objects: [String]? = ["decks/q3-board-review.pptx#slide 7", "finance/q3-model.xlsx"], state: ThoughtState = .open,
                origin: CommentProvenance.Origin = .human, parent: String? = nil, replies: Int = 0, lastHumanReplyAt: Date? = nil,
                due: Date? = nil, snoozeUntil: Date? = nil, kindBy: ThoughtDecider = .model, fileModified: Date? = Date(timeIntervalSince1970: 1_700_000_000)) -> ThoughtRecord {
        var meta = ThoughtMeta(uid: uid, parent: parent)
        if let action, let objects { meta.intent = ThoughtIntent(action: action, objects: objects, confidence: 0.9, model: "m") }
        let comment = Comment(id: UUID(), timestamp: timestamp, anchor: anchor, text: text,
                              provenance: CommentProvenance(origin: origin), meta: meta)
        return ThoughtRecord(file: file, comment: comment, uid: uid, parent: parent, kind: kind, kindBy: kindBy, state: state, due: due,
                             snoozeUntil: snoozeUntil, action: action, origin: origin, fileModified: fileModified, replies: replies,
                             lastHumanReplyAt: lastHumanReplyAt)
    }

    func ledger() -> WorkLedger { WorkLedger(vault: vault) }
}

/// A worker that answers without a model, and says what it was asked.
final class FakeWorker: WorkPerforming, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [WorkRequest] = []
    var requests: [WorkRequest] { lock.withLock { _requests } }
    /// Called for each request; throw to fail it.
    var behaviour: @Sendable (WorkRequest) async throws -> Void = { _ in }
    var title: @Sendable (WorkRequest) -> String = { _ in "Arc price: deck $249, model $229" }
    var tokens = 1_000

    func work(_ request: WorkRequest, onStatus: @escaping @Sendable (String) -> Void) async throws -> WorkResult {
        lock.withLock { _requests.append(request) }
        try await behaviour(request)
        onStatus("working")
        let title = self.title(request)
        let on = request.file.relativePath + (request.anchor.map { "#" + $0.label } ?? "")
        let memo = WorkMemo(thought: request.thoughtUID, on: on, recipe: request.recipe.rawValue, verdict: "conflict",
                            sources: request.objects, model: "fake-model", provider: "llama", tokens: tokens,
                            created: ThoughtDates.stamp(request.now, calendar: testCalendar), title: title,
                            body: "Slide 7 says $249; the model says $229.\n\n## Next step\nFix the model.")
        let links = request.objects.map { "[[\($0)]]" }.joined(separator: ", ")
        return WorkResult(memo: memo, replyText: "Conflict. Slide 7 says $249; the model says $229.\nSources: \(links)",
                          model: "fake-model", provider: "llama", tokens: tokens, fingerprint: "00000000")
    }
}
