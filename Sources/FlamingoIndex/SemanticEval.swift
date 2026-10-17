import Foundation
import FlamingoCore

/// A small relevance benchmark: queries with the files that answer them, scored against
/// any ranking function. Used by `flamingo-index --eval` and the benchmark tests.
public enum SemanticEval {
    public struct Case: Codable, Sendable, Equatable {
        public var query: String
        /// Vault-relative paths that answer the query. For thoughts, `thought:<path>|<yyyy-MM-dd HH:mm>`
        /// keys (see `thoughtKey`), which name a thought by its note and minute.
        public var relevant: [String]
        /// A free-form group for the per-kind breakdown (`en`, `zh`, `cross`, `exact`, …).
        public var kind: String
        public init(query: String, relevant: [String], kind: String = "all") {
            self.query = query; self.relevant = relevant; self.kind = kind
        }
    }

    public struct Score: Sendable, Equatable {
        public var count = 0
        /// Mean over queries of |relevant ∩ top k| / min(k, |relevant|).
        public var recall = 0.0
        /// Mean reciprocal rank of the first relevant file, 0 past rank 10.
        public var mrr = 0.0
        /// Share of queries whose first result is relevant.
        public var hit1 = 0.0
        /// Share of queries with a relevant result in the first three.
        public var hit3 = 0.0
    }

    public struct Miss: Sendable, Equatable {
        public var query: String
        public var rank: Int?
        public var top: [String]
    }

    public struct Report: Sendable {
        public var mode: String
        public var k: Int
        public var overall = Score()
        public var byKind: [String: Score] = [:]
        public var misses: [Miss] = []
        /// Milliseconds per query, sorted.
        public var latencies: [Double] = []
        public var p50: Double { latencies.isEmpty ? 0 : latencies[latencies.count / 2] }
        public var p95: Double { latencies.isEmpty ? 0 : latencies[min(latencies.count - 1, Int(Double(latencies.count) * 0.95))] }
    }

    /// Runs every case through `rank`, which returns file paths best first (duplicates are
    /// dropped, so a section-level ranking can be passed as is).
    public static func run(_ cases: [Case], mode: String, k: Int = 5, rank: (String) throws -> [String]) rethrows -> Report {
        var report = Report(mode: mode, k: k)
        var sums: [String: (n: Int, r: Double, m: Double, h: Double, h3: Double)] = [:]
        for c in cases {
            let started = DispatchTime.now()
            var seen = Set<String>()
            let ranked = try rank(c.query).filter { seen.insert($0).inserted }
            report.latencies.append(Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6)
            let relevant = Set(c.relevant)
            let first = ranked.prefix(10).firstIndex { relevant.contains($0) }.map { $0 + 1 }
            let recall = Double(Set(ranked.prefix(k)).intersection(relevant).count) / Double(max(1, min(k, relevant.count)))
            let rr = first.map { 1 / Double($0) } ?? 0
            let h = first == 1 ? 1.0 : 0
            let h3 = (first ?? 99) <= 3 ? 1.0 : 0
            for key in ["*", c.kind] {
                var s = sums[key] ?? (0, 0, 0, 0, 0)
                s.n += 1; s.r += recall; s.m += rr; s.h += h; s.h3 += h3
                sums[key] = s
            }
            if first != 1 { report.misses.append(Miss(query: c.query, rank: first, top: Array(ranked.prefix(3)))) }
        }
        func score(_ s: (n: Int, r: Double, m: Double, h: Double, h3: Double)) -> Score {
            let n = Double(max(1, s.n))
            return Score(count: s.n, recall: s.r / n, mrr: s.m / n, hit1: s.h / n, hit3: s.h3 / n)
        }
        report.overall = score(sums["*"] ?? (0, 0, 0, 0, 0))
        for (key, s) in sums where key != "*" { report.byKind[key] = score(s) }
        report.latencies.sort()
        return report
    }

    /// The key a thought has in a case's `relevant` list: `thought:decks/q3.pptx|2026-10-13 14:11`.
    public static func thoughtKey(path: String, timestamp: Date) -> String {
        "thought:" + path + "|" + SidecarFormat.string(fromTimestamp: timestamp)
    }

    /// A plain-text table: one row per report, overall then per kind.
    public static func table(_ reports: [Report]) -> String {
        let kinds = Array(Set(reports.flatMap { $0.byKind.keys })).sorted()
        func f(_ x: Double) -> String { String(format: "%.3f", x) }
        var lines = ["mode                 recall@k  MRR    hit@1  " + kinds.map { "\($0.padding(toLength: 13, withPad: " ", startingAt: 0))" }.joined() + " p50ms   p95ms"]
        for r in reports {
            var line = r.mode.padding(toLength: 20, withPad: " ", startingAt: 0) + " "
            line += f(r.overall.recall) + "     " + f(r.overall.mrr) + "  " + f(r.overall.hit1) + "  "
            for k in kinds {
                let s = r.byKind[k] ?? Score()
                line += (f(s.recall) + "/" + f(s.mrr)).padding(toLength: 13, withPad: " ", startingAt: 0)
            }
            line += String(format: " %6.1f  %6.1f", r.p50, r.p95)
            lines.append(line)
        }
        lines.append("per kind: recall@k/MRR; counts " + kinds.map { "\($0)=\(reports.first?.byKind[$0]?.count ?? 0)" }.joined(separator: " "))
        return lines.joined(separator: "\n")
    }
}
