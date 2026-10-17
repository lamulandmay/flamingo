import Foundation
import FlamingoCore
import FlamingoIndex

/// What a recipe hands the model: numbered passages from the files the thought names (and
/// nothing else), the state of those files, and any file the recipe chose itself.
struct WorkReading {
    var passages: [Passage]
    var sources: [WorkFingerprint.Source]
    /// Files the recipe added to the thought's own (the other version, for compare-versions).
    var extraPaths: [String] = []
    var endpoint: LocalEndpoint?
}

/// Gathers passages for a work request. Reads only the files the thought names plus the file
/// it is on, except find-related, which searches the vault and sends excerpts only.
struct WorkReader {
    let engine: AskEngine
    let request: WorkRequest
    let endpoint: LocalEndpoint

    private var source: PassageSource { engine.source }
    private var vault: Vault { engine.index.vault }

    struct Entry { var ref: FileRef; var anchors: [FileAnchor] }

    /// The files the request names, in order, with the places in them; the thought's own file last.
    func entries() -> [Entry] {
        var out: [Entry] = []
        func add(_ path: String, _ anchor: FileAnchor?) {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return }
            let ref = FileRef(relativePath: path)
            guard !ref.isVirtual, vault.exists(ref) else { return }
            if let i = out.firstIndex(where: { $0.ref == ref }) {
                if let anchor, !out[i].anchors.contains(anchor) { out[i].anchors.append(anchor) }
            } else { out.append(Entry(ref: ref, anchors: anchor.map { [$0] } ?? [])) }
        }
        for object in request.objects {
            let parts = object.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            add(parts[0], parts.count > 1 ? FileAnchor(parsing: parts[1]) : nil)
        }
        add(request.file.relativePath, request.anchor)
        return out
    }

    func read() throws -> WorkReading {
        let named = entries()
        guard !named.isEmpty else { throw WorkError.noSources("None of the files this names exist any more") }
        let sources = WorkFingerprint.sources(of: named.map(\.ref.relativePath), in: vault)
        switch request.recipe {
        case .reviewConflict, .summarize:
            return WorkReading(passages: try sectionPassages(named), sources: sources)
        case .compareVersions:
            let (pair, boosted) = try versionPair(named)
            let passages = try sectionPassages(pair, boost: boosted)
            let extra = pair.map(\.ref.relativePath).filter { p in !named.contains { $0.ref.relativePath == p } }
            return WorkReading(passages: passages, sources: WorkFingerprint.sources(of: pair.map(\.ref.relativePath), in: vault), extraPaths: extra)
        case .answer:
            let question = ThoughtRules.prose(of: request.thoughtText)
            let scoped = MultiFileSource(base: source, files: named.map(\.ref))
            let found = try engine.gather(question, history: [], source: scoped, context: .empty, budget: endpoint.passageBudget).passages
            guard !found.isEmpty else { throw WorkError.noSources("The named files say nothing about this") }
            return WorkReading(passages: found, sources: sources)
        case .findRelated:
            return WorkReading(passages: try relatedPassages(named), sources: sources)
        }
    }

    // MARK: Sections

    static func section(for anchor: FileAnchor, in sections: [SourceSection]) -> SourceSection? {
        sections.first { $0.anchor == anchor }
            ?? (anchor.kind == .cell ? sections.first { $0.anchor.kind == .sheet && anchor.value.hasPrefix($0.anchor.value + "!") } : nil)
            ?? (anchor.kind == .line ? sections.filter {
                $0.anchor.kind == .line && (Int($0.anchor.value) ?? Int.max) <= (Int(anchor.value) ?? 0)
            }.max { (Int($0.anchor.value) ?? 0) < (Int($1.anchor.value) ?? 0) } : nil)
    }

    /// Anchored sections first, then each file's sections ranked against the thought's words and
    /// the other files' terms, packed to a share of the budget per file.
    private func sectionPassages(_ entries: [Entry], boost: [String: [FileAnchor]] = [:]) throws -> [Passage] {
        let sectionsByFile = try Dictionary(entries.map { ($0.ref, try source.sections(of: $0.ref)) }, uniquingKeysWith: { a, _ in a })
        let thoughtTerms = QueryPlan.terms(ThoughtRules.prose(of: request.thoughtText))
        // What each file says at the places the thought names: the other files are read against it.
        func anchoredText(_ e: Entry) -> String {
            e.anchors.compactMap { a in Self.section(for: a, in: sectionsByFile[e.ref] ?? []).map { ($0.title ?? "") + " " + String($0.text.prefix(500)) } }.joined(separator: " ")
        }
        var out: [Passage] = []
        let share = max(600, endpoint.passageBudget / max(1, entries.count))
        for e in entries {
            let sections = sectionsByFile[e.ref] ?? []
            let others = entries.filter { $0.ref != e.ref }.map(anchoredText).joined(separator: " ")
            let terms = Array(Set(thoughtTerms + QueryPlan.terms(others).prefix(14)))
            var candidates: [(anchor: FileAnchor?, title: String?, text: String, rank: Int)] = []
            var taken = Set<String>()
            for a in e.anchors + (boost[e.ref.relativePath] ?? []) {
                if let s = Self.section(for: a, in: sections), taken.insert(s.anchor.rendered).inserted {
                    candidates.append((e.anchors.contains(a) ? a : s.anchor, s.title, s.text, Int.max))
                }
            }
            for (i, s) in sections.enumerated() where taken.insert(s.anchor.rendered).inserted {
                let m = Retriever.matchCount(terms, in: (s.title ?? "") + " " + s.text)
                if m > 0 || sections.count <= 4 { candidates.append((s.anchor, s.title, s.text, m * 1000 - i)) }
            }
            if sections.isEmpty, let text = try source.text(of: e.ref), !text.isEmpty {
                candidates.append((e.anchors.first, nil, text, 0))
            }
            var used = 0
            for c in candidates.sorted(by: { $0.rank > $1.rank }) {
                let text = Retriever.excerpt(c.text, terms: terms, max: c.rank == Int.max ? 2200 : 1500)
                guard !text.isEmpty else { continue }
                let p = Passage(id: 0, kind: .section, file: e.ref, anchor: c.anchor, title: c.title, text: text)
                let cost = Retriever.tokens(p)
                guard used + cost <= share else { continue }
                used += cost
                out.append(p)
            }
        }
        guard !out.isEmpty else { throw WorkError.noSources("The named files have nothing readable yet") }
        return number(out)
    }

    private func number(_ passages: [Passage]) -> [Passage] {
        passages.enumerated().map { i, p in
            Passage(id: i + 1, kind: p.kind, file: p.file, anchor: p.anchor, title: p.title, text: p.text,
                    timestamp: p.timestamp, provenance: p.provenance, commentID: p.commentID)
        }
    }

    // MARK: Versions

    /// The two files to compare: the two the thought names, else the named one and its most
    /// likely other version. `boost` is where the two differ, so those sections are read first.
    private func versionPair(_ named: [Entry]) throws -> ([Entry], [String: [FileAnchor]]) {
        let own = request.file
        let focus = named.first { $0.ref != own } ?? named[0]
        if named.count >= 2, let other = named.first(where: { $0.ref != focus.ref }) { return ([focus, other], [:]) }
        let family = try engine.index.fileFamily(for: focus.ref, limit: 8)
        guard let member = family.members.first(where: { $0.kind == .possibleVersion }) ?? family.members.first(where: { $0.kind == .identicalCopy }) else {
            throw WorkError.noSources("No other version of \(focus.ref.name) was found")
        }
        var boost: [String: [FileAnchor]] = [:]
        for e in member.comparison?.selectedOnly ?? [] { if let a = e.anchor { boost[e.file.relativePath, default: []].append(a) } }
        for e in member.comparison?.candidateOnly ?? [] { if let a = e.anchor { boost[e.file.relativePath, default: []].append(a) } }
        return ([focus, Entry(ref: member.file, anchors: [])], boost)
    }

    // MARK: Related

    /// Excerpts of other thoughts and other files that bear on the thought. Only excerpts are
    /// handed to the model, never whole files.
    private func relatedPassages(_ named: [Entry]) throws -> [Passage] {
        let query = QueryPlan.terms(ThoughtRules.prose(of: request.thoughtText)).prefix(8).joined(separator: " ")
        guard !query.isEmpty else { throw WorkError.noSources("The thought has nothing to search for") }
        let namedFiles = Set(named.map(\.ref))
        var out: [Passage] = []
        var used = 0
        func add(_ p: Passage) {
            let cost = Retriever.tokens(p)
            guard used + cost <= endpoint.passageBudget else { return }
            used += cost
            out.append(p)
        }
        for hit in (try? engine.index.searchThoughts(query, limit: 10)) ?? [] {
            let r = hit.record
            guard r.origin == .human, r.uid != request.thoughtUID, r.state != .dismissed else { continue }
            let re = hit.parentLine.map { "re: " + $0 + "\n" } ?? ""
            add(Passage(id: 0, kind: .comment, file: r.file, anchor: r.comment.anchor, text: re + String(r.comment.text.prefix(500)),
                        timestamp: r.comment.timestamp, provenance: r.comment.provenance, commentID: r.comment.id))
            if out.count >= 5 { break }
        }
        var seen = Set<FileRef>()
        for hit in (try? engine.index.searchSections(query, limit: 40)) ?? [] where hit.commentID == nil {
            guard !namedFiles.contains(hit.file), seen.insert(hit.file).inserted else { continue }
            add(Passage(id: 0, kind: .section, file: hit.file, anchor: hit.anchor, text: String(Retriever.plain(hit.snippet).prefix(600))))
            if seen.count >= 6 { break }
        }
        for e in named.prefix(2) {
            for similar in (try? engine.index.similarFiles(to: e.ref, limit: 4)) ?? [] {
                guard !namedFiles.contains(similar.file), let text = similar.passage, !text.isEmpty, seen.insert(similar.file).inserted else { continue }
                add(Passage(id: 0, kind: .section, file: similar.file, text: String(text.prefix(600))))
            }
        }
        guard !out.isEmpty else { throw WorkError.noSources("Nothing related found") }
        return number(out)
    }
}
