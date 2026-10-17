import XCTest
import FlamingoCore
@testable import FlamingoIndex

/// Relevance benchmark. The live runs need Ollama (or fall back to Apple's on-device model)
/// and print a table: `FLAMINGO_LIVE=1 scripts/test.sh --filter SemanticBenchmarkTests`.
final class SemanticBenchmarkTests: XCTestCase {
    static let fixtureCases: [SemanticEval.Case] = [
        .init(query: "the doc about lamp pricing", relevant: ["docs/pricing-memo.docx", "notes/pricing-decisions.md"], kind: "en"),
        .init(query: "what did Maya say about flicker", relevant: ["research/interview-maya-chen.m4a"], kind: "en"),
        .init(query: "how long does the supplier take to deliver LED modules", relevant: ["legal/supplier-agreement.pdf"], kind: "en"),
        .init(query: "contract with the manufacturer", relevant: ["legal/supplier-agreement.pdf"], kind: "en"),
        .init(query: "size of the market opportunity", relevant: ["research/market-sizing.pdf"], kind: "en"),
        .init(query: "how many months until we run out of money", relevant: ["decks/q3-board-review.pptx"], kind: "en"),
        .init(query: "complaints customers have about existing desk lamps", relevant: ["decks/q3-board-review.pptx", "research/interview-maya-chen.m4a"], kind: "en"),
        .init(query: "cost of each component in the lamp", relevant: ["finance/unit-economics.xlsx"], kind: "en"),
        .init(query: "when does the product go on sale", relevant: ["decks/arc-launch-plan.pptx"], kind: "en"),
        .init(query: "what colours will the lamp come in", relevant: ["design/moodboard.jpg"], kind: "en"),
        .init(query: "3D model of the lamp", relevant: ["design/arc-lamp.usdz"], kind: "en"),
        .init(query: "script that predicts holiday sales", relevant: ["tools/forecast.py"], kind: "en"),
        .init(query: "promotional video", relevant: ["media/arc-teaser.mp4"], kind: "en"),
        .init(query: "things we still have to do before launch", relevant: ["notes/launch-checklist.md"], kind: "en"),
        .init(query: "unanswered questions", relevant: ["notes/open-questions.md"], kind: "en"),
        .init(query: "notes from the team meeting", relevant: ["notes/weekly-sync-2026-10-08.md"], kind: "en"),
        .init(query: "no visible flicker requirement", relevant: ["docs/arc-product-brief.docx"], kind: "en"),
        .init(query: "who is the target customer", relevant: ["docs/arc-product-brief.docx"], kind: "en"),
        .init(query: "hinge wearing out during testing", relevant: ["docs/arc-product-brief.docx", "decks/q3-board-review.pptx", "notes/weekly-sync-2026-10-08.md"], kind: "en"),
        .init(query: "what price should we charge", relevant: ["docs/pricing-memo.docx", "notes/pricing-decisions.md"], kind: "en"),
        .init(query: "profit per unit at different prices", relevant: ["finance/unit-economics.xlsx", "docs/pricing-memo.docx"], kind: "en"),
        .init(query: "open job positions", relevant: ["decks/q3-board-review.pptx"], kind: "en"),
        .init(query: "where did we record pricing choices", relevant: ["notes/pricing-decisions.md"], kind: "en"),
        .init(query: "photo of the whiteboard price ladder", relevant: ["design/whiteboard-pricing.jpg"], kind: "en"),
        .init(query: "biggest threats to shipping on time", relevant: ["decks/q3-board-review.pptx", "legal/supplier-agreement.pdf"], kind: "en"),
        .init(query: "灯的定价备忘录", relevant: ["docs/pricing-memo.docx", "notes/pricing-decisions.md"], kind: "cross"),
        .init(query: "供应商合同", relevant: ["legal/supplier-agreement.pdf"], kind: "cross"),
        .init(query: "市场规模估算", relevant: ["research/market-sizing.pdf"], kind: "cross"),
        .init(query: "Arc 的发布日期", relevant: ["decks/arc-launch-plan.pptx"], kind: "cross"),
        .init(query: "客户访谈", relevant: ["research/interview-maya-chen.m4a"], kind: "cross"),
        .init(query: "q3 model", relevant: ["finance/q3-model.xlsx"], kind: "exact"),
        .init(query: "Lumen Optics", relevant: ["legal/supplier-agreement.pdf"], kind: "exact"),
        .init(query: "revenue by channel", relevant: ["decks/q3-board-review.pptx"], kind: "exact"),
    ]

    var live: Bool { ProcessInfo.processInfo.environment["FLAMINGO_LIVE"] == "1" }

    static func modes(_ store: IndexStore) -> [(String, (String) throws -> [String])] {
        func files(_ r: UnifiedSearchResponse) -> [String] { r.results.filter { !$0.isDirectory }.map(\.file.relativePath) }
        return [
            ("lexical", { try store.search($0, inFolder: nil, limit: 20, includeSemantic: false).map(\.file.relativePath) }),
            ("semantic-only", { store.semanticSections($0, limit: 50).map(\.path) }),
            ("hybrid search()", { try store.search($0, limit: 20).map(\.file.relativePath) }),
            ("sections (Ask)", { try store.searchSections($0, limit: 30).map(\.file.relativePath) }),
            ("palette lexical", { files(try store.unifiedSearch(UnifiedSearchQuery(raw: $0), limit: 20)) }),
            ("palette semantic", { files(try store.unifiedSearch(UnifiedSearchQuery(raw: $0), limit: 20, includeSemantic: true)) }),
        ]
    }

    func runBenchmark(_ name: String, store: IndexStore, cases: [SemanticEval.Case]) throws -> [SemanticEval.Report] {
        let started = Date()
        var embedded = 0
        // Background embedding may stop early when the model is busy; keep going until done.
        while true {
            let n = store.embedPending()
            embedded += n
            let progress = try store.embeddingProgress()
            if n == 0 || progress.embedded >= progress.total { break }
        }
        let progress = try store.embeddingProgress()
        print("[\(name)] embedded \(embedded) (\(progress.embedded)/\(progress.total)) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        for (_, rank) in Self.modes(store) { _ = try? rank("warm up") }
        let reports = try Self.modes(store).map { try SemanticEval.run(cases, mode: $0.0, rank: $0.1) }
        print("[\(name)] \(cases.count) queries\n" + SemanticEval.table(reports))
        if ProcessInfo.processInfo.environment["FLAMINGO_BENCH_CALIBRATE"] == "1" { calibrate(store, cases: cases) }
        if ProcessInfo.processInfo.environment["FLAMINGO_BENCH_MISSES"] == "1" {
            for r in reports where r.mode.hasPrefix("palette semantic") || r.mode.hasPrefix("hybrid") {
                print("  misses in \(r.mode):")
                for m in r.misses { print("    \(m.rank.map(String.init) ?? "-")  \(m.query)  →  \(m.top.joined(separator: ", "))") }
            }
        }
        return reports
    }

    /// Prints how cosines of relevant passages compare with the best irrelevant ones, per
    /// model, to set `EmbeddingProfile.floor`/`strong`.
    func calibrate(_ store: IndexStore, cases: [SemanticEval.Case]) {
        let embedder = store.embedding.lock.withLock { store.embedding.embedder }
        for (index, profile) in store.semanticIndexes() {
            var relevant: [Float] = [], irrelevant: [Float] = [], top1: [(Float, Bool)] = []
            for c in cases where c.kind != "exact" {
                guard let q = store.queryVector(c.query, profile: profile, embedder: embedder, wait: 10) else { continue }
                let found = index.nearest(q, k: 300, floor: -1)
                let rows = found.map { index.row($0.row) }
                let paths: [Int64: String] = (try? store.read { db in
                    Dictionary(try db.query("SELECT rowid, path FROM sections WHERE rowid IN (SELECT value FROM json_each(?))", IndexStore.json(rows.filter { !$0.isComment }.map(\.owner))) { (Int64($0.int(0)), $0.string(1)) }
                               + db.query("SELECT -rowid, path FROM comments WHERE rowid IN (SELECT value FROM json_each(?))", IndexStore.json(rows.filter(\.isComment).map(\.owner))) { (Int64($0.int(0)), $0.string(1)) },
                               uniquingKeysWith: { a, _ in a })
                }) ?? [:]
                var bestRel: Float = -1, bestIrr: Float = -1
                for (f, r) in zip(found, rows) {
                    guard let p = paths[r.isComment ? -r.owner : r.owner] else { continue }
                    if c.relevant.contains(p) { bestRel = max(bestRel, f.score) } else { bestIrr = max(bestIrr, f.score) }
                }
                if bestRel > -1 { relevant.append(bestRel) }
                if bestIrr > -1 { irrelevant.append(bestIrr) }
                top1.append((max(bestRel, bestIrr), bestRel >= bestIrr))
            }
            func pct(_ a: [Float], _ p: Double) -> String { a.isEmpty ? "-" : String(format: "%.3f", a.sorted()[min(a.count - 1, Int(Double(a.count) * p))]) }
            print("[calibrate \(profile.id)] best relevant cosine p10 \(pct(relevant, 0.1)) p50 \(pct(relevant, 0.5)) p90 \(pct(relevant, 0.9)); best irrelevant p10 \(pct(irrelevant, 0.1)) p50 \(pct(irrelevant, 0.5)) p90 \(pct(irrelevant, 0.9))")
            let wrong = top1.filter { !$0.1 }.map(\.0), right = top1.filter { $0.1 }.map(\.0)
            print("[calibrate \(profile.id)] top-1 right p10 \(pct(right, 0.1)) p50 \(pct(right, 0.5)); top-1 wrong p50 \(pct(wrong, 0.5)) p90 \(pct(wrong, 0.9))")
        }
    }

    func testFixtureVaultBenchmark() throws {
        try XCTSkipUnless(live, "set FLAMINGO_LIVE=1")
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../fixtures/vault").standardized
        // FLAMINGO_BENCH_DIR keeps the vaults (and their vectors) between runs, for tuning.
        let keep = ProcessInfo.processInfo.environment["FLAMINGO_BENCH_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("fixture") }
        let root = keep ?? FileManager.default.temporaryDirectory.appendingPathComponent("bench-fixture-\(UUID().uuidString)")
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixtures, to: root)
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: root.appendingPathComponent(".flamingo/index.sqlite" + suffix)) }
        }
        defer { if keep == nil { try? FileManager.default.removeItem(at: root) } }
        let store = try IndexStore(vault: Vault(root: root))
        try store.reindex()
        let reports = try runBenchmark("fixture vault", store: store, cases: Self.fixtureCases)
        let lexical = reports.first { $0.mode == "palette lexical" }!, semantic = reports.first { $0.mode == "palette semantic" }!
        XCTAssertGreaterThanOrEqual(semantic.overall.mrr, lexical.overall.mrr)
    }

    /// Thought recall on the fixture vault: `fixtures/thought-cases.json` (paraphrase, Chinese and
    /// cross-language queries, ⌘K rows, "you thought this before" drafts). Targets in `ThoughtEval`.
    func testThoughtRecallBenchmark() throws {
        try XCTSkipUnless(live, "set FLAMINGO_LIVE=1")
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixtures = here.appendingPathComponent("../../fixtures/vault").standardized
        let cases = try JSONDecoder().decode([SemanticEval.Case].self, from: Data(contentsOf: here.appendingPathComponent("../../fixtures/thought-cases.json")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bench-thoughts-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixtures, to: root)
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: root.appendingPathComponent(".flamingo/index.sqlite" + suffix)) }
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IndexStore(vault: Vault(root: root))
        try store.reindex()
        while true {
            let n = store.embedPending()
            let progress = try store.embeddingProgress()
            if n == 0 || progress.embedded >= progress.total { break }
        }
        let report = try ThoughtEval.run(cases, on: store)
        print("[thoughts]\n" + report.text)
        XCTAssertGreaterThanOrEqual(report.search?.overall.recall ?? 0, 0.90)
        XCTAssertGreaterThanOrEqual(report.search?.overall.mrr ?? 0, 0.80)
        XCTAssertGreaterThanOrEqual(report.commandK?.overall.hit3 ?? 0, 0.85)
        XCTAssertGreaterThanOrEqual(report.echoRelatedTop2, 8)
        XCTAssertGreaterThanOrEqual(report.echoUnrelatedSilent, 9)
    }

    func testBilingualBenchmark() throws {
        try XCTSkipUnless(live, "set FLAMINGO_LIVE=1")
        let distractors = Int(ProcessInfo.processInfo.environment["FLAMINGO_BENCH_DISTRACTORS"] ?? "") ?? 1200
        let keep = ProcessInfo.processInfo.environment["FLAMINGO_BENCH_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("bilingual-\(distractors)") }
        let root = keep ?? FileManager.default.temporaryDirectory.appendingPathComponent("bench-bilingual-\(UUID().uuidString)")
        if !FileManager.default.fileExists(atPath: root.path) { try SemanticBenchmarkCorpus.write(to: root, distractors: distractors) }
        if let keep {
            // For `flamingo-index <vault> --no-reindex --eval cases.json`.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(SemanticBenchmarkCorpus.cases).write(to: keep.appendingPathExtension("cases.json"))
        }
        defer { if keep == nil { try? FileManager.default.removeItem(at: root) } }
        let store = try IndexStore(vault: Vault(root: root))
        try store.reindex()
        let reports = try runBenchmark("bilingual vault, \(distractors) distractors", store: store, cases: SemanticBenchmarkCorpus.cases)
        let lexical = reports.first { $0.mode == "palette lexical" }!, semantic = reports.first { $0.mode == "palette semantic" }!
        XCTAssertGreaterThanOrEqual(semantic.overall.mrr, lexical.overall.mrr)
    }

    /// Always runs: the harness, corpus and keyword path work without any model.
    func testHarnessScoresKeywordSearchOnTheCorpus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bench-smoke-\(UUID().uuidString)")
        try SemanticBenchmarkCorpus.write(to: root, distractors: 40)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IndexStore(vault: Vault(root: root))
        try store.reindex()
        let exact = SemanticBenchmarkCorpus.cases.filter { $0.kind == "exact" }
        let report = try SemanticEval.run(exact, mode: "lexical") { try store.search($0, inFolder: nil, limit: 20, includeSemantic: false).map(\.file.relativePath) }
        XCTAssertEqual(report.overall.count, exact.count)
        XCTAssertGreaterThanOrEqual(report.overall.hit1, 0.8, SemanticEval.table([report]))
        let all = SemanticEval.run(SemanticBenchmarkCorpus.cases, mode: "none") { _ in [] }
        XCTAssertEqual(all.overall.mrr, 0)
        XCTAssertEqual(all.misses.count, SemanticBenchmarkCorpus.cases.count)
    }
}
