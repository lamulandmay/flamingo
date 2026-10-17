import Foundation
import FlamingoCore
import FlamingoIndex

/// A source whose scope is fixed, so Ask's own "open file first" step is skipped for it.
protocol ScopedPassageSource: PassageSource {}

/// Scope is enforced at the source boundary, like `SelectedFileSource`, over several files:
/// a thought's target, the files it links to and the files of its thread. Sections are ranked
/// across all of them, so one file can't be lost behind a vault-wide search limit.
struct MultiFileSource: ScopedPassageSource {
    let base: PassageSource
    let scope: [FileRef]
    var vault: Vault { base.vault }

    init(base: PassageSource, files: [FileRef]) {
        self.base = base
        var seen = Set<FileRef>()
        scope = files.filter { seen.insert($0).inserted }
    }

    private func contains(_ ref: FileRef) -> Bool { scope.contains(ref) }
    func files() -> [FileRef] { scope }
    func sections(of ref: FileRef) throws -> [SourceSection] { contains(ref) ? try base.sections(of: ref) : [] }
    func text(of ref: FileRef) throws -> String? { contains(ref) ? try base.text(of: ref) : nil }
    func comments(on ref: FileRef) throws -> [Comment] { contains(ref) ? try base.comments(on: ref) : [] }

    func searchSections(_ query: String, limit: Int) throws -> [SearchHit] {
        let terms = QueryPlan.terms(query)
        var scored: [(hit: SearchHit, matches: Int, order: Int)] = []
        for file in scope {
            let sections = try base.sections(of: file)
            if sections.isEmpty {
                if let text = try base.text(of: file), !text.isEmpty {
                    scored.append((SearchHit(file: file, snippet: Retriever.excerpt(text, terms: terms, max: 1800), score: 1),
                                   Retriever.matchCount(terms, in: text), scored.count))
                }
                continue
            }
            for s in sections {
                scored.append((SearchHit(file: file, anchor: s.anchor, snippet: Retriever.excerpt(s.text, terms: terms, max: 1800), score: 1),
                               Retriever.matchCount(terms, in: (s.title ?? "") + " " + s.text), scored.count))
            }
        }
        return Array(scored.sorted { $0.matches == $1.matches ? $0.order < $1.order : $0.matches > $1.matches }.prefix(limit).map(\.hit))
    }

    func searchComments(_ query: String, limit: Int) throws -> [CommentHit] {
        let terms = QueryPlan.terms(query)
        var all: [CommentHit] = []
        for file in scope {
            all += try base.comments(on: file).map { CommentHit(file: file, comment: $0, snippet: $0.text, score: 1) }
        }
        return Array(all.sorted {
            let a = Retriever.matchCount(terms, in: $0.comment.text), b = Retriever.matchCount(terms, in: $1.comment.text)
            return a == b ? $0.comment.timestamp > $1.comment.timestamp : a > b
        }.prefix(limit))
    }
}

extension SelectedFileSource: ScopedPassageSource {}
