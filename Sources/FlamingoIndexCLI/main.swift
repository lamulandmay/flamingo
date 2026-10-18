import Foundation
import FlamingoCore
import FlamingoIndex
import FlamingoAgents

// flamingo-index — build and query a vault's index without the app. Plan 05 owns.

let usage = """
usage: flamingo-index <vault> [options]

  (no options)        reindex, write graph.json, print a summary
  --search "q"        hits as  path  (anchor)  snippet
  --unified "q"       names, contents, thoughts and folders, with elapsed time
  --family <path>     inspect family evidence for a vault-relative file
  --sections "q"      every matching section, not grouped by file
  --comments "q"      matching comments
  --files "name"      fuzzy file-name match (the command palette)
  --recent            most recently modified files
  --backlinks <path>  comments elsewhere that link to <path>
  --text <path>       the indexed text of one file
  --graph             node and edge counts by kind
  --bench             re-extract everything, then time searches
  --semantic "q"      nearest passages by meaning, with relevance and model
  --hybrid "q"        unified search with meaning (what the palette shows second)
  --similar <path>    files closest in meaning to <path>
  --pairs [min]       suggested connections across the vault (default: the model's floor)
  --embed             embed everything pending now, with progress
  --eval <cases.json> recall@5 / MRR for [{"query", "relevant": [paths], "kind"}]
  --mode thoughts     with --eval: cases name thoughts ("thought:<path>|<time>"); also scores ⌘K rows and echo
  --vector-bench N    time in-memory vector search over N synthetic passages
  --watch             keep running and apply changes as they happen
  --no-reindex        query the existing index as is
  --catalog-indexed   benchmark unified filename fallback using indexed paths as catalog
  --force             re-extract every file, changed or not
  --limit N           cap results (default 20)
  --structure check   how <vault> differs from the project structure (plan 18)
  --structure plan    what making <vault> a project would do
  --structure apply   make <vault> a project: git init and the missing items, never overwriting
  --agents            which agents work where in <vault>, and the folders Flamingo would offer

"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

func err(_ s: String, terminator: String = "\n") {
    FileHandle.standardError.write((s + terminator).data(using: .utf8)!)
}

func ms(since t: DispatchTime) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1e6 }

func fmt(_ x: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", x) }

func line(_ hit: SearchHit) -> String {
    let anchor = hit.anchor.map { "  \($0.rendered)" } ?? ""
    let mark = hit.commentID == nil ? "" : "  ✎"
    return "\(hit.file.relativePath)\(anchor)\(mark)  \(hit.snippet)"
}

// MARK: - Arguments

setvbuf(stdout, nil, _IOLBF, 0)
var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("-h") || args.contains("--help") { print(usage, terminator: ""); exit(args.isEmpty ? 2 : 0) }

var vaultPath: String?
var actions: [(String, String?)] = []
var watch = false, reindexFirst = true, bench = false, force = false, catalogIndexed = false
var limit = 20
let takesValue: Set<String> = ["--search", "--sections", "--comments", "--files", "--backlinks", "--text", "--unified", "--family",
                                "--semantic", "--hybrid", "--similar", "--eval", "--vector-bench", "--mode", "--structure"]
var i = 0
while i < args.count {
    let a = args[i]
    if takesValue.contains(a) {
        guard i + 1 < args.count else { fail("\(a) needs a value") }
        actions.append((a, args[i + 1])); i += 2; continue
    }
    switch a {
    case "--watch": watch = true
    case "--no-reindex": reindexFirst = false
    case "--catalog-indexed": catalogIndexed = true
    case "--force": force = true
    case "--bench": bench = true
    case "--recent", "--graph", "--embed", "--agents": actions.append((a, nil))
    case "--pairs":
        if i + 1 < args.count, Double(args[i + 1]) != nil { actions.append((a, args[i + 1])); i += 1 } else { actions.append((a, nil)) }
    case "--limit":
        guard i + 1 < args.count, let n = Int(args[i + 1]), n >= 0 else { fail("--limit needs a number ≥ 0") }
        limit = n; i += 1
    default:
        if a.hasPrefix("--") { fail("unknown option \(a)\n\n\(usage)") }
        if vaultPath != nil { fail("one vault at a time\n\n\(usage)") }
        vaultPath = a
    }
    i += 1
}
guard let vaultPath else { fail(usage) }
var isDir: ObjCBool = false
guard FileManager.default.fileExists(atPath: vaultPath, isDirectory: &isDir), isDir.boolValue else {
    fail("not a folder: \(vaultPath)")
}

// MARK: - Project structure (no index involved)

if let (_, verb) = actions.first(where: { $0.0 == "--structure" }) {
    let root = URL(fileURLWithPath: vaultPath).standardizedFileURL
    switch verb {
    case "check":
        let report = ProjectChecker.check(root: root)
        print(report.marker.map { "project \($0.project.uuidString), structure \($0.structure)" } ?? "not a project")
        for issue in report.issues { print((issue.isRestorable ? "  restorable  " : "  ") + issue.description) }
        exit(report.isStructured && report.issues.isEmpty ? 0 : 1)
    case "plan", "apply":
        let plan = ProjectScaffolder.plan(root: root)
        for change in plan.changes { print(change.description) }
        for conflict in plan.conflicts { print("! " + conflict.description) }
        guard verb == "apply" else { exit(plan.conflicts.isEmpty ? 0 : 1) }
        do {
            let created = try ProjectScaffolder.apply(plan)
            print("created \(created.count): " + created.joined(separator: ", "))
            exit(0)
        } catch {
            fail(error.localizedDescription)
        }
    default:
        fail("--structure takes check, plan or apply")
    }
}

if actions.contains(where: { $0.0 == "--agents" }) {
    let root = URL(fileURLWithPath: vaultPath)
    let presence = AgentPresence(vaultRoot: root)
    let start = DispatchTime.now()
    let activity = presence.activity()
    let elapsed = ms(since: start)
    let time = DateFormatter()
    time.dateFormat = "HH:mm"
    for item in activity {
        let state = item.isLive ? "live" : "log " + time.string(from: item.lastActive)
        print("\(item.harness.name)  \(state)  \(item.project.path)" + (item.title.map { "  \"\($0)\"" } ?? ""))
    }
    let declined = ProjectsStore(vault: Vault(root: root)).declined()
    let offers = presence.offers(declined: declined)
    print(offers.isEmpty ? "no folders to offer" : "offer: " + offers.map(\.root.path).joined(separator: ", "))
    err("(\(fmt(elapsed)) ms)")
    exit(0)
}

let vault = Vault(root: URL(fileURLWithPath: vaultPath))

// MARK: - Bench

if bench {
    do {
        // Forced rather than deleting index.sqlite, which the app may have open.
        let fresh = try IndexStore(vault: vault)
        try fresh.reindex(force: true)
        let r = fresh.lastReindex!
        print("reindex: \(r.scanned) files, \(r.extracted) extracted in \(fmt(r.seconds, 2))s (\(fmt(Double(r.scanned) / max(r.seconds, 0.001), 0)) files/s)")
        let words = try fresh.indexedFiles().compactMap { ref -> String? in
            ref.name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first { $0.count >= 3 }.map(String.init)
        }
        var queries = Array(Set(words)).sorted().prefix(40).map { $0 }
        queries += queries.prefix(10).map { String($0.prefix(3)) }   // prefix searches
        queries += ["the", "and report", "\"quarterly review\"", "zzzzqx"]
        var times: [Double] = []
        for q in queries {
            let t = DispatchTime.now()
            _ = try fresh.search(q)
            times.append(ms(since: t))
        }
        times.sort()
        let p = { (f: Double) in times[min(times.count - 1, Int(Double(times.count) * f))] }
        print("search: \(times.count) queries, p50 \(fmt(p(0.5), 2))ms, p95 \(fmt(p(0.95), 2))ms, max \(fmt(times.last ?? 0, 2))ms")
        let t = DispatchTime.now()
        let g = try fresh.buildGraph()
        print("graph: \(g.nodes.count) nodes, \(g.edges.count) edges in \(fmt(ms(since: t), 1))ms")
        exit(0)
    } catch {
        fail("flamingo-index: \(error)")
    }
}

// MARK: - Vector bench (no vault index needed)

if let n = actions.first(where: { $0.0 == "--vector-bench" }).flatMap({ Int($0.1 ?? "") }) {
    do {
        for line in try SemanticBench.vectorSearch(passages: n, in: vault.stateDir) { print(line) }
        exit(0)
    } catch { fail("flamingo-index: \(error)") }
}

// Background embedding would die with this process; `--embed` runs it in the foreground.
if !watch { IndexStore.autoEmbed = false }
let readOnly = !reindexFirst && !watch && !actions.contains { ["--graph", "--embed"].contains($0.0) }
let store: IndexStore
do { store = try IndexStore(vault: vault, readOnly: readOnly) } catch { fail("cannot open index: \(error)") }

// MARK: - Reindex

func reindex() throws {
    let interactive = isatty(STDERR_FILENO) != 0
    var last = -1
    try store.reindex(force: force) { p in
        let pct = Int(p * 100)
        if interactive, pct != last { last = pct; err("\r\(pct)%", terminator: "") }
    }
    if interactive { err("\r", terminator: "") }
    let r = store.lastReindex!
    let s = try store.stats()
    print("\(s.files) files · \(r.extracted) extracted · \(r.removed) removed · \(s.sections) sections · \(s.comments) comments · \(fmt(r.seconds, 2))s")
}

do {

    if reindexFirst { try reindex() }
    let needsGraph = reindexFirst || actions.contains { $0.0 == "--graph" }
    let graph = needsGraph ? try store.buildGraph() : nil
    if actions.isEmpty && !watch, let graph {
        let links = graph.edges.filter { $0.kind == .link }.count
        print("\(graph.nodes.count) nodes, \(links) links → \(store.graphURL.path)")
    }

    let diagnosticCatalog = catalogIndexed ? try store.indexedFiles() : []
    for (action, value) in actions {
        let t = DispatchTime.now()
        switch action {
        case "--unified":
            let query = UnifiedSearchQuery(raw: value!)
            let response = try store.unifiedSearch(query, limit: limit, catalogFiles: diagnosticCatalog)
            let elapsed = ms(since: t)
            for result in response.results {
                let kind = result.isDirectory ? "folder" : "file"
                print("[\(kind)] \(result.file.relativePath)  score=\(fmt(result.score, 2))")
                result.hits.forEach { print("  " + line($0)) }
                if let coverage = result.coverage { print("  " + coverage) }
            }
            for hit in response.thoughts {
                print("[thought] \(hit.record.file.relativePath)  \(hit.record.kind.rawValue)\(hit.record.state == .open ? "" : " " + hit.record.state.rawValue)  \(hit.snippet)")
            }
            if !query.summary.isEmpty { err(query.summary.joined(separator: " · ")) }
            if let notice = response.notice { err(notice) }
            err("\(response.results.count) unified results in \(fmt(elapsed, 2))ms")
        case "--family":
            let family = try store.fileFamily(for: FileRef(relativePath: value!), limit: limit)
            let elapsed = ms(since: t)
            for member in family.members {
                print("[\(member.kind.label)] \(member.file.relativePath)  \(member.reason)")
                if let comparison = member.comparison {
                    print("  \(comparison.sharedSections) shared extracted sections; \(comparison.scope)")
                    for evidence in comparison.selectedOnly { print("  Selected only: \(evidence.anchor?.rendered ?? "") \(evidence.excerpt)") }
                    for evidence in comparison.candidateOnly { print("  Candidate only: \(evidence.anchor?.rendered ?? "") \(evidence.excerpt)") }
                }
            }
            family.notes.forEach { err($0) }
            err("\(family.members.count) family members in \(fmt(elapsed, 2))ms")
        case "--search":
            let hits = try store.search(value!, limit: limit)
            let elapsed = ms(since: t)
            hits.forEach { print(line($0)) }
            err("\(hits.count) hits in \(fmt(elapsed, 2))ms")
        case "--sections":
            let hits = try store.searchSections(value!, limit: limit)
            let elapsed = ms(since: t)
            hits.forEach { print(line($0)) }
            err("\(hits.count) sections in \(fmt(elapsed, 2))ms")
        case "--comments":
            for h in try store.searchComments(value!, limit: limit) {
                print("\(h.file.relativePath)\(h.comment.anchor.map { "  \($0.rendered)" } ?? "")  \(h.snippet)")
            }
        case "--files":
            try store.files(matching: value!, limit: limit).forEach { print($0.relativePath) }
        case "--recent":
            try store.recent(limit: limit).forEach { print($0.relativePath) }
        case "--semantic":
            let hits = try store.semanticSearch(value!, limit: limit)
            let elapsed = ms(since: t)
            for h in hits {
                print("\(fmt(h.relevance, 2))  cos \(fmt(h.score, 3))  \(line(h.hit))")
            }
            err("\(hits.count) passages in \(fmt(elapsed, 2))ms · \(store.semanticStatus().model ?? "no model")")
        case "--hybrid":
            let response = try store.unifiedSearch(UnifiedSearchQuery(raw: value!), limit: limit, includeSemantic: true)
            let elapsed = ms(since: t)
            for result in response.results {
                print("[\(result.isDirectory ? "folder" : "file")] \(result.file.relativePath)  score=\(fmt(result.score, 2))")
                result.hits.prefix(2).forEach { print("  " + line($0)) }
            }
            for hit in response.thoughts {
                print("[thought] \(hit.record.file.relativePath)  \(hit.record.kind.rawValue)  \(hit.snippet)")
            }
            err("\(response.results.count) results in \(fmt(elapsed, 2))ms")
        case "--similar":
            let similar = try store.similarFiles(to: FileRef(relativePath: value!), limit: limit)
            let elapsed = ms(since: t)
            for s in similar { print("\(fmt(s.score, 3))  \(s.file.relativePath)  \(s.passage ?? "")") }
            err("\(similar.count) similar files in \(fmt(elapsed, 2))ms")
        case "--pairs":
            let minScore = value.flatMap(Double.init) ?? store.similarityFloor()
            let pairs = try store.similarPairs(minScore: minScore, perFile: 3)
            let elapsed = ms(since: t)
            for p in pairs.prefix(limit) { print("\(fmt(p.score, 3))  \(p.a)  ↔  \(p.b)") }
            err("\(pairs.count) pairs ≥ \(fmt(minScore, 2)) in \(fmt(elapsed, 1))ms")
        case "--embed":
            var total = 0
            while true {
                let n = store.embedPending()
                total += n
                let status = store.semanticStatus()
                err("\(status.model ?? "no model"): \(status.embedded)/\(status.total) sections, \(status.embeddedComments)/\(status.comments) thoughts")
                if n == 0 || status.embedded >= status.total { break }
            }
            err("embedded \(total) sections in \(fmt(ms(since: t) / 1000, 1))s")
        case "--mode":
            break
        case "--eval":
            let data = try Data(contentsOf: URL(fileURLWithPath: value!))
            let cases = try JSONDecoder().decode([SemanticEval.Case].self, from: data)
            if actions.contains(where: { $0.0 == "--mode" && $0.1 == "thoughts" }) {
                let report = try ThoughtEval.run(cases, on: store)
                print(report.text)
                for r in report.recall where r.mode == "searchThoughts" {
                    for m in r.misses { print("  \(m.rank.map(String.init) ?? "-")  \(m.query)  →  \(m.top.joined(separator: ", "))") }
                }
                if !report.meetsTargets { exit(1) }
                break
            }
            func files(_ r: UnifiedSearchResponse) -> [String] { r.results.filter { !$0.isDirectory }.map(\.file.relativePath) }
            let modes: [(String, (String) throws -> [String])] = [
                ("lexical", { try store.search($0, inFolder: nil, limit: 20, includeSemantic: false).map(\.file.relativePath) }),
                ("semantic-only", { try store.semanticSearch($0, limit: 50).map(\.hit.file.relativePath) }),
                ("hybrid search()", { try store.search($0, limit: 20).map(\.file.relativePath) }),
                ("sections (Ask)", { try store.searchSections($0, limit: 30).map(\.file.relativePath) }),
                ("palette lexical", { files(try store.unifiedSearch(UnifiedSearchQuery(raw: $0), limit: 20)) }),
                ("palette semantic", { files(try store.unifiedSearch(UnifiedSearchQuery(raw: $0), limit: 20, includeSemantic: true)) }),
            ]
            let reports = try modes.map { try SemanticEval.run(cases, mode: $0.0, rank: $0.1) }
            print(SemanticEval.table(reports))
            for r in reports where r.mode == "palette semantic" {
                for m in r.misses { print("  \(m.rank.map(String.init) ?? "-")  \(m.query)  →  \(m.top.joined(separator: ", "))") }
            }
        case "--backlinks":
            for (ref, c) in try store.backlinks(to: FileRef(relativePath: value!)).prefix(limit) {
                print("\(ref.relativePath)\(c.anchor.map { "  \($0.rendered)" } ?? "")  \(c.text.replacingOccurrences(of: "\n", with: " "))")
            }
        case "--text":
            let ref = FileRef(relativePath: value!)
            for s in try store.sections(of: ref) {
                print("\(s.anchor.rendered)\(s.title.map { " \($0)" } ?? "")")
            }
            print(try store.text(of: ref) ?? "(not indexed)")
        case "--graph":
            guard let graph else { break }
            let byKind = Dictionary(grouping: graph.edges, by: \.kind)
            let orphans = graph.nodes.filter { !FileManager.default.fileExists(atPath: vault.url(for: FileRef(relativePath: $0.id)).path) }
            print("\(graph.nodes.count) nodes (\(orphans.count) without a file), "
                  + "\(byKind[.link]?.count ?? 0) link edges, \(byKind[.trail]?.count ?? 0) trail edges")
            print(store.graphURL.path)
        default: break
        }
    }
} catch {
    fail("flamingo-index: \(error)")
}

// MARK: - Watch

if watch {
    let watcher = VaultWatcher(vault: vault)
    watcher.onChange = { refs in
        let t = DispatchTime.now()
        do {
            try store.update(refs)
            let shown = refs.prefix(5).map { $0.relativePath.isEmpty ? "(everything)" : $0.relativePath }
            print("updated \(refs.count): \(shown.joined(separator: ", "))\(refs.count > 5 ? ", …" : "") in \(fmt(ms(since: t), 1))ms")
        } catch {
            err("update failed: \(error)")
        }
    }
    watcher.onSidecarChange = { _ in   // after onChange, so the comments are already in
        if let g = try? store.buildGraph() { print("graph: \(g.nodes.count) nodes, \(g.edges.count) edges") }
    }
    watcher.start()
    err("watching \(vault.root.path)  (ctrl-c to stop)")
    dispatchMain()
}
