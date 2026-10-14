import XCTest
import FlamingoCore
@testable import FlamingoTrail

/// Deterministic so a slow run is reproducible.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// About a year of heavy use: 250 sessions of 200 events over 400 files, with arrowing
/// through lists, comments, links and search-as-you-type.
func syntheticYear(sessions: Int = 250, perSession: Int = 200, files: Int = 400) -> [TrailEvent] {
    var rng = SplitMix64(state: 42)
    let pool = (0..<files).map { "folder\($0 % 20)/file\($0).md" }
    let words = ["churn", "pricing", "q3 model", "retention", "cohort", "deck"]
    var out: [TrailEvent] = []
    out.reserveCapacity(sessions * perSession)
    var t: TimeInterval = -400 * 86_400
    for _ in 0..<sessions {
        t += 30 * 60 + Double.random(in: 0..<86_400, using: &rng)     // always a new session
        let end = out.count + perSession
        while out.count < end {
            let roll = Int.random(in: 0..<100, using: &rng)
            let file = pool[Int.random(in: 0..<files, using: &rng)]
            switch roll {
            case 0..<70:
                t += roll < 20 ? 1 : Double.random(in: 3..<120, using: &rng)   // some arrowing through
                out.append(ev(.opened, t, file: file))
            case 70..<80:
                t += 20
                out.append(ev(.commented, t, file: file, text: "thought \(out.count)"))
            case 80..<85:
                t += 5
                out.append(ev(.linked, t, file: file, text: pool.randomElement(using: &rng)!))
            default:
                let w = words.randomElement(using: &rng)!
                for n in 1...min(w.count, 4) where out.count < end {        // search-as-you-type
                    t += 0.4
                    out.append(ev(.searched, t, text: String(w.prefix(n))))
                }
            }
        }
    }
    return out
}

final class TrailPerformanceTests: XCTestCase {

    func testClusteringFiftyThousandEventsIsFast() {
        let events = syntheticYear()
        XCTAssertEqual(events.count, 50_000)
        let tuning = TrailTuning()

        let start = Date()
        let sessions = TrailClustering.sessions(from: events.shuffled(), tuning: tuning)
        let afterSessions = Date()
        let edges = TrailClustering.edges(from: sessions, now: trailBase, tuning: tuning)
        let elapsed = Date().timeIntervalSince(start)
        print("[trail perf] sessions \(String(format: "%.3f", afterSessions.timeIntervalSince(start)))s, "
              + "total \(String(format: "%.3f", elapsed))s for \(events.count) events → "
              + "\(sessions.count) sessions, \(edges.count) edges")

        XCTAssertLessThan(elapsed, 3, "clustering 50k events should take well under a second in release")
        XCTAssertEqual(sessions.count, 250)
        XCTAssertTrue(sessions.allSatisfy { !$0.events.isEmpty && $0.files.count > 1 })
        XCTAssertFalse(edges.isEmpty)
        for e in edges { XCTAssertLessThan(e.source, e.target) }
    }

    func testReadingFiftyThousandLinesThenAnIncrementalRead() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flamingo-trail-perf-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = Vault(root: root)
        try FileManager.default.createDirectory(at: vault.stateDir, withIntermediateDirectories: true)

        let events = syntheticYear()
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for e in events { data.append(try enc.encode(e)); data.append(0x0A) }
        let store = TrailStore(vault: vault)
        try data.write(to: store.fileURL)

        var start = Date()
        let first = try store.events()
        let cold = Date().timeIntervalSince(start)

        start = Date()
        let second = try store.events()
        let warm = Date().timeIntervalSince(start)
        print("[trail perf] cold read \(String(format: "%.3f", cold))s, warm read \(String(format: "%.3f", warm))s")

        XCTAssertEqual(first.count, events.count)
        XCTAssertEqual(second.map(\.id), first.map(\.id))
        XCTAssertLessThan(cold, 10)
        XCTAssertLessThan(warm, max(1, cold / 2), "a read with nothing appended must not re-parse the file")
    }
}
