import Foundation
import FlamingoCore
import FlamingoIndex

/// Scope is enforced at the source boundary, including model follow-up searches and links.
/// Ranking the selected file directly avoids losing it behind a workspace-wide search limit.
struct SelectedFileSource: PassageSource {
    let base: PassageSource
    let file: FileRef
    var vault: Vault { base.vault }
    func files() -> [FileRef] { [file] }
    func sections(of ref: FileRef) throws -> [SourceSection] { ref == file ? try base.sections(of: ref) : [] }
    func text(of ref: FileRef) throws -> String? { ref == file ? try base.text(of: ref) : nil }
    func comments(on ref: FileRef) throws -> [Comment] { ref == file ? try base.comments(on: ref) : [] }

    func searchSections(_ query: String, limit: Int) throws -> [SearchHit] {
        let terms = QueryPlan.terms(query)
        let sections = try base.sections(of: file)
        if sections.isEmpty, let text = try base.text(of: file), !text.isEmpty {
            return [SearchHit(file: file, snippet: Retriever.excerpt(text, terms: terms, max: 1800), score: 1)]
        }
        return Array(sections.enumerated().sorted {
            let a = Retriever.matchCount(terms, in: ($0.element.title ?? "") + " " + $0.element.text)
            let b = Retriever.matchCount(terms, in: ($1.element.title ?? "") + " " + $1.element.text)
            return a == b ? $0.offset < $1.offset : a > b
        }.prefix(limit).map { _, s in
            SearchHit(file: file, anchor: s.anchor, snippet: Retriever.excerpt(s.text, terms: terms, max: 1800), score: 1)
        })
    }

    func searchComments(_ query: String, limit: Int) throws -> [CommentHit] {
        let terms = QueryPlan.terms(query)
        return Array(try base.comments(on: file).sorted {
            let a = Retriever.matchCount(terms, in: $0.text), b = Retriever.matchCount(terms, in: $1.text)
            return a == b ? $0.timestamp > $1.timestamp : a > b
        }.prefix(limit).map { CommentHit(file: file, comment: $0, snippet: $0.text, score: 1) })
    }
}
