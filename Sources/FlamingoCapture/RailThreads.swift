import Foundation
import FlamingoCore

/// A thought and the answers to it, as the rail lays them out.
struct RailThread: Identifiable, Equatable {
    var root: Comment
    /// Every thought answering the root, directly or through other replies, in time order.
    /// Rails show two levels at most, so a reply to a reply sits here too.
    var replies: [Comment]
    /// Streaming AI answers not yet saved, keyed by the uid of the thought they answer.
    var pending: [RailPending] = []

    var id: UUID { root.id }
    /// The root, then its replies.
    var comments: [Comment] { [root] + replies }
}

struct RailPending: Identifiable, Equatable {
    /// The uid of the thought being answered.
    var parentUID: String
    var text: String
    var id: String { "pending." + parentUID }
}

enum RailThreads {
    /// Roots in time order, each with its replies. A reply whose parent is not in `comments`
    /// (deleted, or in another note) is shown as a root. Ties keep the order given.
    static func build(_ comments: [Comment], pending: [String: String] = [:]) -> [RailThread] {
        let sorted = comments.enumerated()
            .sorted { ($0.element.timestamp, $0.offset) < ($1.element.timestamp, $1.offset) }
            .map(\.element)
        var indexByUID: [String: Int] = [:]
        for (i, c) in sorted.enumerated() { if let uid = c.uid, indexByUID[uid] == nil { indexByUID[uid] = i } }

        var parent = [Int?](repeating: nil, count: sorted.count)
        for (i, c) in sorted.enumerated() {
            if let p = c.meta?.parent, let j = indexByUID[p], j != i { parent[i] = j }
        }
        // A loop (a answers b answers a) would hide both: the earlier one becomes the root.
        for i in sorted.indices {
            var steps = 0, at = parent[i]
            while let a = at, a != i, steps <= sorted.count { at = parent[a]; steps += 1 }
            if at == i { parent[i] = nil }
        }
        func root(of i: Int) -> Int {
            var at = i
            while let p = parent[at] { at = p }
            return at
        }

        var threads: [RailThread] = []
        var threadOfRoot: [Int: Int] = [:]
        for i in sorted.indices where parent[i] == nil {
            threadOfRoot[i] = threads.count
            threads.append(RailThread(root: sorted[i], replies: []))
        }
        for i in sorted.indices where parent[i] != nil {
            if let t = threadOfRoot[root(of: i)] { threads[t].replies.append(sorted[i]) }
        }
        for (uid, text) in pending.sorted(by: { $0.key < $1.key }) {
            guard let j = indexByUID[uid], let t = threadOfRoot[root(of: j)] else { continue }
            threads[t].pending.append(RailPending(parentUID: uid, text: text))
        }
        return threads
    }

    /// The rows top to bottom.
    static func order(_ comments: [Comment]) -> [Comment] {
        build(comments).flatMap(\.comments)
    }
}
