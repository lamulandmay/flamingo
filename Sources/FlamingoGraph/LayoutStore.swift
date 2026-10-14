import Foundation
import CoreGraphics
import FlamingoCore

/// `<vault>/.flamingo/graph-layout.json`. Plain JSON, sorted keys, coordinates rounded to 0.1.
struct SavedLayout: Codable, Equatable, Sendable {
    var version: Int = 1
    /// Node id (relative path) to `[x, y]`.
    var nodes: [String: [Double]]
    /// Sorted ids.
    var pinned: [String]
}

extension SavedLayout {
    private enum CodingKeys: String, CodingKey { case version, nodes, pinned }

    /// Lenient: a missing `version` or `pinned` is not a reason to throw the layout away.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        nodes = try c.decode([String: [Double]].self, forKey: .nodes)
        pinned = try c.decodeIfPresent([String].self, forKey: .pinned) ?? []
    }

    /// Coordinates rounded to 0.1 (no negative zero), non-finite entries dropped, pins sorted,
    /// unique and limited to known nodes.
    var normalized: SavedLayout {
        var out = SavedLayout(version: version, nodes: [:], pinned: [])
        out.nodes.reserveCapacity(nodes.count)
        for (id, xy) in nodes where xy.count >= 2 && xy[0].isFinite && xy[1].isFinite {
            out.nodes[id] = [LayoutStore.round(xy[0]), LayoutStore.round(xy[1])]
        }
        out.pinned = Array(Set(pinned.filter { out.nodes[$0] != nil })).sorted()
        return out
    }
}

/// Persistence and initial placement for the graph layout.
enum LayoutStore {
    static let fileName = "graph-layout.json"

    static func fileURL(in vault: Vault) -> URL {
        vault.stateDir.appendingPathComponent(fileName)
    }

    /// nil if missing or unreadable. Never throws.
    static func load(from vault: Vault) -> SavedLayout? {
        guard let data = try? Data(contentsOf: fileURL(in: vault)),
              let layout = try? JSONDecoder().decode(SavedLayout.self, from: data) else { return nil }
        return layout
    }

    /// Atomic write. Creates `.flamingo/` if needed and writes nothing else anywhere.
    static func save(_ layout: SavedLayout, to vault: Vault) throws {
        try FileManager.default.createDirectory(at: vault.stateDir, withIntermediateDirectories: true)
        try encode(layout).write(to: fileURL(in: vault), options: .atomic)
    }

    /// The exact bytes `save` writes.
    static func encode(_ layout: SavedLayout) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(layout.normalized)
    }

    static func layout(for topology: GraphTopology, positions: [CGPoint], pinned: Set<Int>) -> SavedLayout {
        var nodes: [String: [Double]] = [:]
        nodes.reserveCapacity(topology.count)
        for i in 0..<min(topology.count, positions.count) {
            let p = positions[i]
            guard p.x.isFinite, p.y.isFinite else { continue }
            nodes[topology.ids[i]] = [round(Double(p.x)), round(Double(p.y))]
        }
        let pins = pinned.filter { $0 >= 0 && $0 < topology.count }.map { topology.ids[$0] }.filter { nodes[$0] != nil }
        return SavedLayout(nodes: nodes, pinned: pins.sorted())
    }

    /// Rounds to 0.1 and turns -0 into 0.
    static func round(_ v: Double) -> Double {
        (v * 10).rounded() / 10 + 0
    }

    // MARK: - Seeding

    /// Deterministic position for a node id, independent of node order and process. Spread
    /// area-uniformly in a disk of radius `10 * sqrt(count)` (d3's phyllotaxis extent).
    static func seededPosition(id: String, count: Int) -> CGPoint {
        let a = mix(hash(id))
        let b = mix(a)
        let radius = 10 * Double(max(count, 1)).squareRoot()
        let r = radius * unit(a).squareRoot()
        let t = 2 * Double.pi * unit(b)
        return CGPoint(x: r * cos(t), y: r * sin(t))
    }

    /// Offset within a disk of `radius`, seeded by id, independent of `seededPosition`.
    static func jitter(id: String, radius: Double) -> CGPoint {
        let a = mix(hash(id) ^ 0x6A09E667F3BCC908)
        let b = mix(a)
        let r = radius * unit(a).squareRoot()
        let t = 2 * Double.pi * unit(b)
        return CGPoint(x: r * cos(t), y: r * sin(t))
    }

    /// FNV-1a over the UTF-8 bytes.
    static func hash(_ id: String) -> UInt64 {
        var h: UInt64 = 0xCBF29CE484222325
        for byte in id.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001B3
        }
        return h
    }

    /// splitmix64 finalizer: spreads FNV's weak low bits across the word.
    private static func mix(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// [0, 1) from the top 53 bits.
    private static func unit(_ x: UInt64) -> Double { Double(x >> 11) * 0x1p-53 }

    // MARK: - Initial placement

    struct Initial {
        var positions: [CGPoint]
        var pinned: Set<Int>
        /// Nodes whose position came from `saved`.
        var restored: Int
        var alpha: Double
    }

    /// Saved positions where known. New nodes with placed neighbors enter near the centroid of
    /// those neighbors (plus a jitter of about half a link length, seeded by id), working
    /// outward from the restored nodes one ring at a time. When the layout is partially
    /// restored, a new node with no placed neighbors (a new orphan, or the anchor of a new
    /// component: its smallest id) enters on the outer ring of the existing layout, one link
    /// length beyond the farthest restored node from the restored centroid, at an angle seeded
    /// by id; the rest of its component grows from it. With nothing restored every node gets
    /// `seededPosition`. alpha is 1 if nothing was restored, 0 if everything was (reopening is
    /// instant and stable), 0.3 otherwise.
    static func initial(for topology: GraphTopology, saved: SavedLayout?) -> Initial {
        let n = topology.count
        var positions = [CGPoint](repeating: .zero, count: n)
        var placed = [Bool](repeating: false, count: n)
        var pinned = Set<Int>()
        var restored = 0

        if let saved {
            let savedPins = Set(saved.pinned)
            for i in 0..<n {
                let id = topology.ids[i]
                guard let xy = saved.nodes[id], xy.count >= 2, xy[0].isFinite, xy[1].isFinite else { continue }
                positions[i] = CGPoint(x: xy[0], y: xy[1])
                placed[i] = true
                restored += 1
                if savedPins.contains(id) { pinned.insert(i) }
            }
        }

        if restored > 0 && restored < n {
            let linkDistance = ForceSimulation.Parameters().linkDistance
            // Each ring only sees nodes placed in earlier rings, so the result does not depend
            // on node order.
            func grow() {
                while true {
                    var ring: [(Int, CGPoint)] = []
                    for i in 0..<n where !placed[i] {
                        var sx = 0.0, sy = 0.0, c = 0.0
                        for j in topology.neighbors[i] where placed[j] {
                            sx += Double(positions[j].x); sy += Double(positions[j].y); c += 1
                        }
                        guard c > 0 else { continue }
                        let d = jitter(id: topology.ids[i], radius: linkDistance / 2)
                        ring.append((i, CGPoint(x: sx / c + d.x, y: sy / c + d.y)))
                    }
                    if ring.isEmpty { return }
                    for (i, p) in ring { positions[i] = p; placed[i] = true }
                }
            }
            let wasRestored = placed
            grow()

            if placed.contains(false) {
                // Outer ring of the restored layout.
                var cx = 0.0, cy = 0.0
                for i in 0..<n where wasRestored[i] { cx += Double(positions[i].x); cy += Double(positions[i].y) }
                cx /= Double(restored); cy /= Double(restored)
                var extent = 0.0
                for i in 0..<n where wasRestored[i] {
                    extent = max(extent, Double(hypot(Double(positions[i].x) - cx, Double(positions[i].y) - cy)))
                }
                let radius = extent + linkDistance

                // One anchor per new component (smallest id, so independent of node order).
                var component = [Int](repeating: -1, count: n)
                var anchors: [Int] = []
                for start in 0..<n where !placed[start] && component[start] < 0 {
                    var stack = [start], anchor = start
                    component[start] = start
                    while let i = stack.popLast() {
                        if topology.ids[i] < topology.ids[anchor] { anchor = i }
                        for j in topology.neighbors[i] where !placed[j] && component[j] < 0 {
                            component[j] = start
                            stack.append(j)
                        }
                    }
                    anchors.append(anchor)
                }
                for i in anchors {
                    let t = 2 * Double.pi * unit(mix(hash(topology.ids[i]) ^ 0xBB67AE8584CAA73B))
                    positions[i] = CGPoint(x: cx + radius * cos(t), y: cy + radius * sin(t))
                    placed[i] = true
                }
                grow()
            }
        }
        for i in 0..<n where !placed[i] {
            positions[i] = seededPosition(id: topology.ids[i], count: n)
        }

        let alpha: Double = restored == n ? 0 : (restored == 0 ? 1 : 0.3)
        return Initial(positions: positions, pinned: pinned, restored: restored, alpha: alpha)
    }

    // MARK: - Cache

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var entries: [String: SavedLayout] = [:]
    }
    private static let cache = Cache()

    /// Process-wide in-memory cache so switching modes (the view is torn down and rebuilt) is
    /// instant. Key: vault root path, or "" without a vault. Thread-safe.
    static func cached(_ key: String) -> SavedLayout? {
        cache.lock.lock(); defer { cache.lock.unlock() }
        return cache.entries[key]
    }

    static func setCached(_ layout: SavedLayout, for key: String) {
        cache.lock.lock(); defer { cache.lock.unlock() }
        cache.entries[key] = layout
    }
}
