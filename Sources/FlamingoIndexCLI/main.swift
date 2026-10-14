import Foundation
import FlamingoCore
import FlamingoIndex

// flamingo-index — build and query a vault's index without the app. Plan 05 owns.

let usage = """
usage: flamingo-index <vault> [options]

  (no options)        reindex, write graph.json, print a summary
  --search "q"        hits as  path  (anchor)  snippet
  --sections "q"      every matching section, not grouped by file
  --comments "q"      matching comments
  --files "name"      fuzzy file-name match (the command palette)
  --recent            most recently modified files
  --backlinks <path>  comments elsewhere that link to <path>
  --text <path>       the indexed text of one file
  --graph             node and edge counts by kind
  --bench             reindex from scratch, then time searches
  --watch             keep running and apply changes as they happen
  --no-reindex        query the existing index as is
  --force             re-extract every file, changed or not
  --limit N           cap results (default 20)

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
var watch = false, reindexFirst = true, bench = false, force = false
var limit = 20
let takesValue: Set<String> = ["--search", "--sections", "--comments", "--files", "--backlinks", "--text"]
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
    case "--force": force = true
    case "--bench": bench = true
    case "--recent", "--graph": actions.append((a, nil))
    case "--limit":
        guard i + 1 < args.count, let n = Int(args[i + 1]) else { fail("--limit needs a number") }
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

let vault = Vault(root: URL(fileURLWithPath: vaultPath))

// MARK: - Bench

if bench {
    do {
        let db = vault.stateDir.appendingPathComponent("index.sqlite").path
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db + suffix) }
        let fresh = try IndexStore(vault: vault)
        try fresh.reindex()
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

let store: IndexStore
do { store = try IndexStore(vault: vault) } catch { fail("cannot open index: \(error)") }

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
    let graph = try store.buildGraph()
    if actions.isEmpty && !watch {
        let links = graph.edges.filter { $0.kind == .link }.count
        print("\(graph.nodes.count) nodes, \(links) links → \(store.graphURL.path)")
    }

    for (action, value) in actions {
        let t = DispatchTime.now()
        switch action {
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
