import Foundation
import FlamingoCore

/// Pure functions from an event stream to sessions and graph edges. No I/O.
enum TrailClustering {

    // MARK: Sessions

    /// Sessions, oldest first. `events` need not be sorted.
    static func sessions(from events: [TrailEvent], tuning: TrailTuning, corrections: TrailCorrections = TrailCorrections()) -> [TrailSession] {
        let sorted = events.enumerated().sorted { a, b in
            a.element.at != b.element.at ? a.element.at < b.element.at : a.offset < b.offset
        }.map(\.element)

        var clusters: [[TrailEvent]] = []
        for e in sorted {
            let boundary = corrections.boundaries[e.id.uuidString]
            if let last = clusters.last?.last,
               boundary != .split && (boundary == .merge || e.at.timeIntervalSince(last.at) <= tuning.sessionGap) {
                clusters[clusters.count - 1].append(e)
            } else {
                clusters.append([e])
            }
        }
        return clusters.map { events in
            var session = session(from: events, tuning: tuning)
            session.excludesInferredConnections = events.contains { corrections.excludedSessionIDs.contains($0.id.uuidString) }
            session.hasGroupingCorrection = events.contains { corrections.boundaries[$0.id.uuidString] != nil }
            return session
        }
    }

    /// One cluster → one session. The id is the first raw event's id, so it stays the same as
    /// the session grows and names stick to it.
    static func session(from raw: [TrailEvent], tuning: TrailTuning) -> TrailSession {
        let kept = mergeSearches(collapseRapidOpens(raw, tuning: tuning), tuning: tuning)
        var seen = Set<FileRef>()
        var files: [FileRef] = []
        for e in kept where e.kind != .searched {
            if let f = e.file, seen.insert(f).inserted { files.append(f) }
        }
        var session = TrailSession(id: raw[0].id, start: raw[0].at, end: raw[raw.count - 1].at,
                                   events: kept, files: files)
        session.sourceEventIDs = raw.map(\.id)
        return session
    }

    /// Drops `opened` events for files the user only passed through: arrowing down a list
    /// opens every file on the way. A visit is a run of opens of one file; its dwell lasts
    /// until a different file is opened. Visits shorter than `minDwell` are dropped unless
    /// the file was commented on or linked in this session, or it is the last visit (the
    /// user stopped there).
    static func collapseRapidOpens(_ raw: [TrailEvent], tuning: TrailTuning) -> [TrailEvent] {
        let touched = Set(raw.filter { $0.kind == .commented || $0.kind == .linked }.compactMap(\.file))

        struct Visit { var file: FileRef; var start: Date; var indices: [Int] }
        var visits: [Visit] = []
        for (i, e) in raw.enumerated() where e.kind == .opened {
            guard let f = e.file else { continue }
            if let last = visits.last, last.file == f {
                visits[visits.count - 1].indices.append(i)
            } else {
                visits.append(Visit(file: f, start: e.at, indices: [i]))
            }
        }

        var drop = Set<Int>()
        for (n, v) in visits.enumerated() where n < visits.count - 1 {
            let dwell = visits[n + 1].start.timeIntervalSince(v.start)
            if dwell < tuning.minDwell, !touched.contains(v.file) { drop.formUnion(v.indices) }
        }
        return raw.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }

    /// Search-as-you-type records `c`, `ch`, `churn`. Close in time, a query that extends the
    /// previous one replaces it, and one the previous extends (backspacing toward a new
    /// query) is dropped. `churn`, `c`, `co`, `cohort` leaves `churn` and `cohort`.
    static func mergeSearches(_ events: [TrailEvent], tuning: TrailTuning) -> [TrailEvent] {
        var out: [TrailEvent] = []
        for e in events {
            if e.kind == .searched, let prev = out.last, prev.kind == .searched,
               e.at.timeIntervalSince(prev.at) <= tuning.searchMerge {
                let a = (prev.text ?? "").lowercased(), b = (e.text ?? "").lowercased()
                if b.hasPrefix(a) {
                    out[out.count - 1] = e
                    continue
                }
                if a.hasPrefix(b) { continue }
            }
            out.append(e)
        }
        return out
    }

    // MARK: Edges

    /// Undirected `trail` edges, `source < target`, sorted. Within one session:
    /// small sessions connect every pair; larger ones connect consecutive files and the
    /// most-commented files to each other, so one 50-file session doesn't produce 1,225 edges.
    /// A pair's weight sums one decayed vote per session it appeared in.
    static func edges(from sessions: [TrailSession], now: Date, tuning: TrailTuning) -> [Graph.Edge] {
        struct Pair: Hashable { let a: String; let b: String }
        func pair(_ x: FileRef, _ y: FileRef) -> Pair? {
            let p = x.relativePath, q = y.relativePath
            if p == q { return nil }
            return p < q ? Pair(a: p, b: q) : Pair(a: q, b: p)
        }

        var weight: [Pair: Double] = [:]
        for s in sessions where !s.excludesInferredConnections {
            let files = s.files
            guard files.count > 1 else { continue }
            var pairs = Set<Pair>()
            if files.count <= tuning.cliqueLimit {
                for i in 0..<files.count {
                    for j in (i + 1)..<files.count { if let p = pair(files[i], files[j]) { pairs.insert(p) } }
                }
            } else {
                // Consecutive in the order the user moved, not first appearance: going back
                // to a hub between other files connects the hub to each of them.
                var previous: FileRef?
                for e in s.events where e.kind != .searched {
                    guard let f = e.file else { continue }
                    if let prev = previous, let p = pair(prev, f) { pairs.insert(p) }
                    previous = f
                }
                var counts: [FileRef: Int] = [:]
                for e in s.events where e.kind == .commented || e.kind == .linked {
                    if let f = e.file { counts[f, default: 0] += 1 }
                }
                let order = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($1, $0) })
                let commented = counts.keys.sorted {
                    counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : (order[$0] ?? 0) < (order[$1] ?? 0)
                }.prefix(tuning.maxCommentedFiles)
                let c = Array(commented)
                for i in 0..<c.count {
                    for j in (i + 1)..<c.count { if let p = pair(c[i], c[j]) { pairs.insert(p) } }
                }
            }
            let ageDays = max(0, now.timeIntervalSince(s.end)) / 86_400
            let vote = 1 / (1 + ageDays / tuning.decayDays)
            for p in pairs { weight[p, default: 0] += vote }
        }

        // Keep each file's strongest edges. An edge survives if either end ranks it highly.
        var byFile: [String: [(Pair, Double)]] = [:]
        for (p, w) in weight {
            byFile[p.a, default: []].append((p, w))
            byFile[p.b, default: []].append((p, w))
        }
        var keep = Set<Pair>()
        for (_, list) in byFile {
            let top = list.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : ($0.0.a, $0.0.b) < ($1.0.a, $1.0.b) }
                .prefix(tuning.maxEdgesPerFile)
            for (p, _) in top { keep.insert(p) }
        }

        return keep.map { p in
            Graph.Edge(source: p.a, target: p.b, kind: .trail, weight: (weight[p]! * 1000).rounded() / 1000)
        }.sorted { ($0.source, $0.target) < ($1.source, $1.target) }
    }
}
