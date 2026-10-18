import Foundation

/// What one refresh did.
public struct SyncReport: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Disabled, or not due yet.
        case skipped
        case unchanged
        case updated
        case failed(ConnectorError)
    }

    public var id: String
    public var outcome: Outcome
    public var added = 0
    public var removed = 0
    public var changed = 0

    public init(id: String, outcome: Outcome, added: Int = 0, removed: Int = 0, changed: Int = 0) {
        self.id = id; self.outcome = outcome; self.added = added; self.removed = removed; self.changed = changed
    }
}

/// Brings connectors up to date. Items stay on this Mac; nothing here talks to Claude.
public struct ConnectorSync: Sendable {
    public typealias EventKitFetch = @Sendable (PurposeCard, Date, TimeZone) async throws -> [ConnectorItem]

    public let store: ConnectorStore
    let transport: any FeedTransport
    let secret: @Sendable (String) -> String?
    let eventKit: EventKitFetch
    let timeZone: TimeZone
    let clock: @Sendable () -> Date

    public init(store: ConnectorStore,
                transport: any FeedTransport = URLSessionFeedTransport(),
                secret: @escaping @Sendable (String) -> String? = { ConnectorSecrets.secret(for: $0) },
                eventKit: @escaping EventKitFetch = { card, now, zone in
                    try await EventKitSource.shared.items(for: card, now: now, timeZone: zone)
                },
                timeZone: TimeZone = .current,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.transport = transport; self.secret = secret
        self.eventKit = eventKit; self.timeZone = timeZone; self.clock = now
    }

    /// Refreshes one card when it is enabled and due. `force` ignores the timer and the feed's
    /// version tag (after the card was edited). A failure keeps the old items and records the
    /// error; a transient one (offline, 5xx) retries after 2, 4, 8… minutes, anything else after
    /// the card's interval. A feed that answers "not modified" still has its stored items
    /// re-filtered, so items that left the window go.
    public func refresh(_ card: PurposeCard, force: Bool = false) async -> SyncReport {
        let card = card.clamped()
        guard card.enabled else { return SyncReport(id: card.id, outcome: .skipped) }
        let now = clock()
        var state = store.state(card.id)
        guard force || state.isStale(for: card, now: now) else { return SyncReport(id: card.id, outcome: .skipped) }
        let range = card.window.range(now: now, timeZone: timeZone)
        let old = store.items(card.id)
        do {
            let next: [ConnectorItem]
            switch card.adapter {
            case .ical:
                switch try await fetchFeed(card, state: state, force: force, now: now) {
                case .notModified:
                    next = old.filter { $0.falls(in: range) && card.keeps($0) }
                case .items(let items, let etag, let lastModified):
                    next = items
                    state.etag = etag
                    state.lastModified = lastModified
                }
            case .eventkit:
                next = try await eventKit(card, now, timeZone)
            case .imap, .json:
                throw ConnectorError.unsupported(card.adapter)
            }
            var report = Self.diff(old: old, new: next, id: card.id)
            if report.outcome == .updated { try store.saveItems(next, for: card.id) }
            state.refreshedAt = now
            state.lastError = nil
            state.failures = 0
            try store.saveState(state, for: card.id)
            report.id = card.id
            return report
        } catch {
            let failure = error as? ConnectorError ?? .network
            state.refreshedAt = now
            state.lastError = failure
            state.failures = failure.isTransient ? state.failures + 1 : 0
            try? store.saveState(state, for: card.id)
            return SyncReport(id: card.id, outcome: .failed(failure))
        }
    }

    /// Every enabled card that is due, at most `limit` (1 to 4) at a time so one slow feed
    /// doesn't hold up the rest. Reports come back in the store's card order.
    public func refreshStale(limit: Int = 4) async -> [SyncReport] {
        let now = clock()
        let due = store.cards().filter { $0.enabled && store.state($0.id).isStale(for: $0, now: now) }
        guard !due.isEmpty else { return [] }
        let width = min(max(limit, 1), 4)
        var reports: [(Int, SyncReport)] = []
        await withTaskGroup(of: (Int, SyncReport).self) { group in
            var next = 0
            while next < min(width, due.count) {
                let index = next, card = due[index]
                next += 1
                group.addTask { let report = await self.refresh(card); return (index, report) }
            }
            while let done = await group.next() {
                reports.append(done)
                guard next < due.count else { continue }
                let index = next, card = due[index]
                next += 1
                group.addTask { let report = await self.refresh(card); return (index, report) }
            }
        }
        return reports.sorted { $0.0 < $1.0 }.map(\.1)
    }

    // MARK: Feeds

    enum FeedResult {
        case notModified
        case items([ConnectorItem], etag: String?, lastModified: String?)
    }

    /// The card's address comes from the Keychain or the environment, never from `source`
    /// (which is only the host): without it the refresh fails as `missingSecret`.
    func fetchFeed(_ card: PurposeCard, state: ConnectorState, force: Bool, now: Date) async throws -> FeedResult {
        guard let address = secret(card.id)?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else {
            throw ConnectorError.missingSecret
        }
        guard let url = ICalAdapter.feedURL(address) else { throw ConnectorError.invalidSource }
        let answer: FeedFetch
        do {
            answer = try await transport.fetch(url, etag: force ? nil : state.etag, lastModified: force ? nil : state.lastModified)
        } catch let error as ConnectorError {
            throw error
        } catch {
            throw ConnectorError.network
        }
        switch answer {
        case .notModified:
            return .notModified
        case .fetched(let data, let etag, let lastModified):
            let items = try ICalAdapter.items(from: data, card: card, now: now, timeZone: timeZone)
            return .items(items, etag: etag, lastModified: lastModified)
        }
    }

    /// Added, removed and changed ids; a newer fetch time alone is not a change.
    static func diff(old: [ConnectorItem], new: [ConnectorItem], id: String) -> SyncReport {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Set(new.map(\.id))
        var report = SyncReport(id: id, outcome: .unchanged)
        for item in new {
            if let previous = before[item.id] {
                if !previous.sameContent(as: item) { report.changed += 1 }
            } else {
                report.added += 1
            }
        }
        report.removed = before.keys.filter { !after.contains($0) }.count
        if report.added + report.removed + report.changed > 0 || old.count != new.count { report.outcome = .updated }
        return report
    }
}
