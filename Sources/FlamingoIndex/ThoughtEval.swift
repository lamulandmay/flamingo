import Foundation
import FlamingoCore

/// The thought recall benchmark: `flamingo-index <vault> --eval fixtures/thought-cases.json --mode thoughts`
/// and `FLAMINGO_LIVE=1 scripts/test.sh --filter SemanticBenchmarkTests/testThoughtRecallBenchmark`.
///
/// Cases whose kind is `echo-related` or `echo-unrelated` test "you thought this before" (a draft
/// should bring back the earlier thought, an unrelated one should bring back nothing); all
/// the others test finding a thought by what it means (`relevant` holds `thought:` keys).
public enum ThoughtEval {
    public struct Report: Sendable {
        public var recall: [SemanticEval.Report]
        public var echoRelatedTop2 = 0, echoRelatedTotal = 0
        public var echoUnrelatedSilent = 0, echoUnrelatedTotal = 0

        public var search: SemanticEval.Report? { recall.first { $0.mode == "searchThoughts" } }
        public var commandK: SemanticEval.Report? { recall.first { $0.mode == "⌘K thought rows" } }

        /// Whether every target of the plan holds: recall@5 ≥ 0.90, MRR ≥ 0.80, a ⌘K row in the top
        /// three for ≥ 85%, the earlier thought in the top two for 8 of 10 related drafts and
        /// nothing shown for 9 of 10 unrelated ones (scaled when there are other counts).
        public var meetsTargets: Bool {
            guard let s = search, let k = commandK else { return false }
            let related = echoRelatedTotal == 0 || Double(echoRelatedTop2) / Double(echoRelatedTotal) >= 0.8
            let unrelated = echoUnrelatedTotal == 0 || Double(echoUnrelatedSilent) / Double(echoUnrelatedTotal) >= 0.9
            return s.overall.recall >= 0.90 && s.overall.mrr >= 0.80 && k.overall.hit3 >= 0.85 && related && unrelated
        }

        public var text: String {
            func f(_ x: Double) -> String { String(format: "%.3f", x) }
            var lines = [SemanticEval.table(recall)]
            if let s = search { lines.append("searchThoughts: recall@5 \(f(s.overall.recall)) (target 0.90)  MRR \(f(s.overall.mrr)) (target 0.80)") }
            if let k = commandK { lines.append("⌘K thought row in top 3: \(f(k.overall.hit3)) (target 0.85)") }
            lines.append("echo: earlier thought in top 2 for \(echoRelatedTop2)/\(echoRelatedTotal) related drafts (target 8/10); nothing shown for \(echoUnrelatedSilent)/\(echoUnrelatedTotal) unrelated drafts (target 9/10)")
            lines.append(meetsTargets ? "all thought targets met" : "thought targets NOT met")
            return lines.joined(separator: "\n")
        }
    }

    static func key(_ hit: ThoughtHit) -> String { SemanticEval.thoughtKey(path: hit.record.file.relativePath, timestamp: hit.record.comment.timestamp) }

    public static func run(_ cases: [SemanticEval.Case], on store: IndexStore, limit: Int = 20) throws -> Report {
        let recall = cases.filter { !$0.kind.hasPrefix("echo") }
        let modes: [(String, (String) throws -> [String])] = [
            ("thoughts keyword", { try store.searchThoughts($0, limit: limit, includeSemantic: false).map(key) }),
            ("searchThoughts", { try store.searchThoughts($0, limit: limit).map(key) }),
            ("⌘K thought rows", { try store.unifiedSearch(UnifiedSearchQuery(raw: $0), limit: 20, includeSemantic: true).thoughts.map(key) }),
        ]
        var report = Report(recall: try modes.map { try SemanticEval.run(recall, mode: $0.0, rank: $0.1) })
        for c in cases where c.kind == "echo-related" {
            report.echoRelatedTotal += 1
            let found = store.similarThoughts(to: c.query, limit: 2, wait: 10).map(key)
            if !Set(found).isDisjoint(with: c.relevant) { report.echoRelatedTop2 += 1 }
        }
        for c in cases where c.kind == "echo-unrelated" {
            report.echoUnrelatedTotal += 1
            if store.similarThoughts(to: c.query, limit: 2, wait: 10).isEmpty { report.echoUnrelatedSilent += 1 }
        }
        return report
    }
}
