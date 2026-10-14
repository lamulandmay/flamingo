import Foundation
import FlamingoCore
import FlamingoIndex
@testable import FlamingoAsk

/// An in-memory vault whose search behaves like plan 05's: every query word must appear,
/// the last one as a prefix. Comments are searchable and come back at their own anchor.
struct FakeSource: PassageSource {
    var vault = Vault(root: URL(fileURLWithPath: "/tmp/fake-vault"))
    var sectionsByFile: [FileRef: [SourceSection]] = [:]
    var textByFile: [FileRef: String] = [:]
    var commentsByFile: [FileRef: [Comment]] = [:]
    var failSearch = false

    func search(_ query: String, limit: Int) throws -> [SearchHit] {
        if failSearch { throw NSError(domain: "fake", code: 1) }
        let words = QueryPlan.words(query)
        guard !words.isEmpty else { return [] }
        func matches(_ text: String) -> Bool {
            let have = QueryPlan.words(text)
            return words.enumerated().allSatisfy { i, w in
                i == words.count - 1 ? have.contains { $0.hasPrefix(w) } : have.contains(w)
            }
        }
        var hits: [SearchHit] = []
        for (file, sections) in sectionsByFile.sorted(by: { $0.key.relativePath < $1.key.relativePath }) {
            for s in sections where matches((s.title ?? "") + " " + s.text) {
                hits.append(SearchHit(file: file, anchor: s.anchor, snippet: "«\(s.text.prefix(60))»", score: -1))
            }
        }
        for (file, text) in textByFile where matches(text) {
            hits.append(SearchHit(file: file, anchor: nil, snippet: String(text.prefix(60)), score: -1))
        }
        for (file, comments) in commentsByFile.sorted(by: { $0.key.relativePath < $1.key.relativePath }) {
            for c in comments where matches(c.text) {
                hits.append(SearchHit(file: file, anchor: c.anchor, snippet: "…\(c.text.prefix(40))…", score: -2))
            }
        }
        return Array(hits.prefix(limit))
    }

    func sections(of ref: FileRef) throws -> [SourceSection] { sectionsByFile[ref] ?? [] }
    func text(of ref: FileRef) throws -> String? { textByFile[ref] }
    func comments() throws -> [FileRef: [Comment]] { commentsByFile }
    func files() -> [FileRef] {
        Array(Set(sectionsByFile.keys).union(textByFile.keys).union(commentsByFile.keys))
            .sorted { $0.relativePath < $1.relativePath }
    }
}

enum Fixture {
    static let deck = FileRef(relativePath: "decks/q3.pptx")
    static let sheet = FileRef(relativePath: "models/q3-model.xlsx")
    static let notes = FileRef(relativePath: "notes/standup.md")
    static let decision = Comment(
        timestamp: Date(timeIntervalSince1970: 1_792_000_000),
        anchor: FileAnchor(kind: .slide, value: "7"),
        text: "Pricing here contradicts [[q3-model.xlsx#sheet Price]]. Decided: keep $49, drop the annual discount.")
    static let titleNote = Comment(
        timestamp: Date(timeIntervalSince1970: 1_791_000_000),
        anchor: FileAnchor(kind: .slide, value: "1"),
        text: "Needs a better title")

    /// The plan's "done means" vault: a deck, a sheet, and a comment that connects them.
    static var vault: FakeSource {
        var s = FakeSource()
        s.sectionsByFile[deck] = [
            SourceSection(anchor: FileAnchor(kind: .slide, value: "1"), title: "Q3 review", text: "Q3 review. Revenue, churn and the plan for Q4."),
            SourceSection(anchor: FileAnchor(kind: .slide, value: "7"), title: "Pricing", text: "Pricing: $49 per seat per month, 20% off annual plans."),
            SourceSection(anchor: FileAnchor(kind: .slide, value: "9"), title: "Churn", text: "Churn by cohort fell to 2.1% after onboarding changes."),
        ]
        s.sectionsByFile[sheet] = [
            SourceSection(anchor: FileAnchor(kind: .sheet, value: "Revenue"), title: "Revenue", text: "Seats 1200, ARPU 41.20, MRR 49440"),
            SourceSection(anchor: FileAnchor(kind: .sheet, value: "Price"), title: "Price", text: "List 49 | Annual discount 0% | Effective 49"),
        ]
        s.textByFile[notes] = "Standup: shipped onboarding; nothing on pricing yet."
        s.commentsByFile[deck] = [titleNote, decision]
        return s
    }
}
