import Foundation
import FlamingoCore

/// A file ranked by how recently and how much the user worked with it.
public struct RecentFile: Sendable, Equatable, Identifiable {
    public var file: FileRef
    public var score: Double
    /// The latest event of any kind.
    public var lastTouched: Date
    public var lastOpened: Date?
    /// The latest `saved` or `commented` event.
    public var lastEdited: Date?
    /// The anchor of the latest event that has one.
    public var lastAnchor: FileAnchor?
    /// How many comments were recorded on it inside the window.
    public var thoughts: Int
    public var id: String { file.relativePath }

    public init(file: FileRef, score: Double, lastTouched: Date, lastOpened: Date? = nil, lastEdited: Date? = nil,
                lastAnchor: FileAnchor? = nil, thoughts: Int = 0) {
        self.file = file; self.score = score; self.lastTouched = lastTouched; self.lastOpened = lastOpened
        self.lastEdited = lastEdited; self.lastAnchor = lastAnchor; self.thoughts = thoughts
    }
}

/// The knobs of the frecency score.
public struct RecentsTuning: Sendable, Equatable {
    /// Events older than this are ignored.
    public var window: TimeInterval = 30 * 86_400
    public var recencyHalfLife: TimeInterval = 6 * 3600
    public var recencyWeight = 4.0
    public var frequencyHalfLife: TimeInterval = 3 * 86_400
    /// At most one event per kind per file per burst counts.
    public var burst: TimeInterval = 30 * 60
    public var weights: [TrailEvent.Kind: Double] = [.opened: 1, .saved: 2, .commented: 2.5, .linked: 1.5]
    /// Multiplier when the file was saved or commented on in the last `editedWithin`.
    public var editedBoost = 1.25
    public var editedWithin: TimeInterval = 7 * 86_400
    public init() {}
}

/// Frecency over trail events: `recencyWeight * 2^(-age/recencyHalfLife)` for the latest touch,
/// plus the sum of `weight(kind) * 2^(-age/frequencyHalfLife)` over burst-merged events, times
/// `editedBoost` for files edited lately. `.searched` events, events with no file and paths
/// under `.flamingo/` never count.
public enum TrailRecents {
    public static func rank(_ events: [TrailEvent], now: Date, limit: Int, tuning: RecentsTuning = .init()) -> [RecentFile] {
        guard limit > 0 else { return [] }
        let oldest = now.addingTimeInterval(-tuning.window)
        var byFile: [String: [TrailEvent]] = [:]
        for e in events {
            guard let path = e.file?.relativePath, e.kind != .searched, e.at >= oldest,
                  path != ".flamingo", !path.hasPrefix(".flamingo/") else { continue }
            byFile[path, default: []].append(e)
        }
        var ranked: [RecentFile] = []
        ranked.reserveCapacity(byFile.count)
        for (path, list) in byFile {
            let sorted = list.sorted { $0.at > $1.at }   // newest first
            let touched = sorted[0].at
            let opened = sorted.first { $0.kind == .opened }?.at
            let edited = sorted.first { $0.kind == .saved || $0.kind == .commented }?.at
            let anchor = sorted.first { $0.anchor != nil }?.anchor

            var frequency = 0.0
            var keptAt: [TrailEvent.Kind: Date] = [:]   // the last (newest) counted event per kind
            for e in sorted {
                if let last = keptAt[e.kind], last.timeIntervalSince(e.at) < tuning.burst { continue }
                keptAt[e.kind] = e.at
                let age = max(0, now.timeIntervalSince(e.at))
                frequency += (tuning.weights[e.kind] ?? 0) * pow(2, -age / tuning.frequencyHalfLife)
            }
            let touchAge = max(0, now.timeIntervalSince(touched))
            var score = tuning.recencyWeight * pow(2, -touchAge / tuning.recencyHalfLife) + frequency
            if let edited, now.timeIntervalSince(edited) <= tuning.editedWithin { score *= tuning.editedBoost }
            ranked.append(RecentFile(file: FileRef(relativePath: path), score: score, lastTouched: touched,
                                     lastOpened: opened, lastEdited: edited, lastAnchor: anchor,
                                     thoughts: sorted.filter { $0.kind == .commented }.count))
        }
        ranked.sort { $0.score != $1.score ? $0.score > $1.score : $0.file.relativePath < $1.file.relativePath }
        return Array(ranked.prefix(limit))
    }
}

extension TrailStore {
    /// The most relevant files, best first. Reads and ranks on the calling thread, so call it
    /// off the main thread. Drops events outside the window before anything is sorted.
    public func recentFiles(now: Date = Date(), limit: Int = 24, tuning: RecentsTuning = .init()) throws -> [RecentFile] {
        TrailRecents.rank(try unsortedEvents(), now: now, limit: limit, tuning: tuning)
    }
}
