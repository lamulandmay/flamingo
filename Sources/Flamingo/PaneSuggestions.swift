import Foundation
import FlamingoCore
import FlamingoIndex

/// A file on screen that picks are chosen against. The pane you are working in weighs most.
struct PaneSeed: Equatable {
    var file: FileRef
    var weight: Double
    static let activeWeight = 1.0, otherWeight = 0.8
}

struct PaneSuggestion: Equatable, Identifiable {
    var file: FileRef
    var score: Double
    /// Up to two, strongest first. Empty when the file is here only because you touched it lately.
    var reasons: [ConnectionReason]
    var phrases: [String]
    var id: String { file.relativePath }
}

/// What each empty pane offers: the files most related to what's already on screen, with
/// recency as a tie-breaker, handed out in blocks so no two launchers show the same file.
enum PaneSuggestions {
    static let block = 8
    static let recencyWeight = 0.3

    /// `evidence` holds each seed's connections. Score = Σ seed weight · strength + 0.3 · recency
    /// (the file's recents score over the best one). Files in `exclude` are never offered.
    /// Launcher `k` gets ranked `[8k ..< 8k + 8]`; recents sit in the same ranking, so a short
    /// list is filled from them.
    static func rank(seeds: [PaneSeed], evidence: [FileRef: FileConnectionsSnapshot],
                     recents: [(file: FileRef, score: Double)], exclude: Set<FileRef>,
                     launchers: Int, block: Int = PaneSuggestions.block) -> [[PaneSuggestion]] {
        guard launchers > 0 else { return [] }
        var scores: [FileRef: Double] = [:]
        var reasons: [FileRef: [(ConnectionReason, Double, String)]] = [:]
        for seed in seeds {
            guard let snapshot = evidence[seed.file] else { continue }
            for connection in snapshot.explicit + snapshot.suggested where !exclude.contains(connection.file) {
                scores[connection.file, default: 0] += seed.weight * connection.strength
                for reason in connection.reasons {
                    reasons[connection.file, default: []].append((reason, seed.weight * connection.strength, reason.phrase(connection.evidence)))
                }
            }
        }
        let top = recents.map(\.score).max() ?? 0
        for recent in recents where !exclude.contains(recent.file) {
            scores[recent.file, default: 0] += top > 0 ? recencyWeight * recent.score / top : 0
        }
        let order = ConnectionReason.allCases
        let ranked = scores.sorted { a, b in a.value != b.value ? a.value > b.value : a.key.relativePath < b.key.relativePath }
            .map { file, score -> PaneSuggestion in
                // One entry per reason, strongest reason first, at most two.
                var seen = Set<ConnectionReason>()
                let picked = (reasons[file] ?? [])
                    .sorted { (order.firstIndex(of: $0.0) ?? 0) < (order.firstIndex(of: $1.0) ?? 0) }
                    .filter { seen.insert($0.0).inserted }.prefix(2)
                return PaneSuggestion(file: file, score: score, reasons: picked.map(\.0), phrases: picked.map(\.2))
            }
        return (0..<launchers).map { k in
            let lower = min(ranked.count, k * block), upper = min(ranked.count, k * block + block)
            return Array(ranked[lower..<upper])
        }
    }
}
