import Foundation
import Observation
import Security
import FlamingoAsk
import FlamingoConnectors

/// A card with what its last refresh left behind, for the Connectors pane.
struct ConnectorRow: Identifiable, Equatable {
    var card: PurposeCard
    var state: ConnectorState
    var id: String { card.id }
}

/// The app's connectors: app-wide, not per vault, in `ConnectorStore.defaultRoot()` with feed
/// addresses in the Keychain. Items stay on this Mac: never a thought or a sidecar, never sent to
/// Claude or into Chat's retrieval. Claude sees a new card's description, link host and feed shape
/// once, to draft it (`ConnectorDrafting`).
///
/// Refreshes stale cards at launch, then on one timer set for the soonest card due, never sooner
/// than five minutes and with generous tolerance. No enabled card, no timer.
@MainActor @Observable
final class ConnectorsModel {
    static let shared = ConnectorsModel()

    private(set) var rows: [ConnectorRow] = []
    /// Enabled connectors' items, soonest first. The inbox's agenda reads it.
    private(set) var items: [ConnectorItem] = []
    private(set) var refreshing: Set<String> = []

    let store: ConnectorStore
    private let sync: ConnectorSync
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var sweeping = false

    static let minimumWait: TimeInterval = 5 * 60

    init(store: ConnectorStore = ConnectorStore(root: ConnectorStore.defaultRoot())) {
        self.store = store
        sync = ConnectorSync(store: store)
    }

    /// AppDelegate, at launch.
    func start() {
        guard !started else { return }
        started = true
        Task { await refreshStale(reloadAlways: true) }
    }

    /// Cards, states and items from disk, off the main thread; then the timer is set again.
    func reload() async {
        let store = store
        let loaded = await Task.detached(priority: .utility) { () -> ([ConnectorRow], [ConnectorItem]) in
            (store.cards().map { ConnectorRow(card: $0, state: store.state($0.id)) }, store.allItems())
        }.value
        if rows != loaded.0 { rows = loaded.0 }
        if items != loaded.1 { items = loaded.1 }
        schedule()
    }

    private func refreshStale(reloadAlways: Bool = false) async {
        guard !sweeping else { return }
        sweeping = true
        let sync = sync
        let reports = await Task.detached(priority: .utility) { await sync.refreshStale() }.value
        sweeping = false
        if reloadAlways || !reports.isEmpty { await reload() } else { schedule() }
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        let now = Date()
        guard let due = rows.filter(\.card.enabled).map({ $0.state.nextRefresh(for: $0.card) ?? now }).min() else { return }
        let wait = max(Self.minimumWait, due.timeIntervalSince(now))
        let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.refreshStale() }
        }
        timer.tolerance = max(60, wait / 5)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Pane actions

    /// Ignores the card's timer and the feed's version tag.
    func refresh(_ card: PurposeCard) {
        guard !refreshing.contains(card.id) else { return }
        refreshing.insert(card.id)
        let sync = sync
        Task {
            _ = await Task.detached(priority: .userInitiated) { await sync.refresh(card, force: true) }.value
            refreshing.remove(card.id)
            await reload()
        }
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard var card = store.card(id), card.enabled != enabled else { return }
        card.enabled = enabled
        try? store.save(card)
        if enabled { refresh(card) } else { Task { await reload() } }
    }

    /// The card, its items and state, and its Keychain address.
    func delete(_ id: String) throws {
        try store.delete(id)
        try ConnectorSecrets.remove(for: id)
        Task { await reload() }
    }

    /// Under a free id: the address goes to the Keychain first so the first refresh finds it,
    /// then the card, then a forced refresh.
    func add(_ draft: ConnectorDraft) throws {
        var card = draft.finished
        card.id = store.freshID(for: card.name)
        if let secret = draft.secret { try ConnectorSecrets.save(secret, for: card.id) }
        do { try store.save(card) } catch {
            try? ConnectorSecrets.remove(for: card.id)
            throw error
        }
        refresh(card)
    }
}

/// A drafted card while its fields are edited in the pane.
struct ConnectorDraft: Equatable {
    var card: PurposeCard
    /// The full feed address, for the Keychain; nil for Apple Calendar.
    var secret: String?
    /// Comma-separated, as typed.
    var include: String
    var exclude: String

    init(card: PurposeCard, secret: String?) {
        self.card = card; self.secret = secret
        include = card.include.joined(separator: ", ")
        exclude = card.exclude.joined(separator: ", ")
    }

    var finished: PurposeCard {
        var card = card
        card.include = include.split(separator: ",").map(String.init)
        card.exclude = exclude.split(separator: ",").map(String.init)
        return card.clamped()
    }
}

/// Description → card. With an Anthropic key Claude drafts it from the description, the link's
/// host and the feed's shape (counts and property names, never items); without one, or when the
/// reply has no card, `CardDrafting.heuristicCard` guesses.
enum ConnectorDrafting {
    static func draft(adapter: ConnectorAdapter, pasted: String, description: String) async throws -> ConnectorDraft {
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let source: String, secret: String?, host: String?, shape: FeedShape?
        switch adapter {
        case .eventkit:
            guard try await EventKitSource.shared.requestAccess(for: EventKitAdapter.Selection()) else {
                throw ConnectorError.accessDenied
            }
            source = "all"; secret = nil; host = nil; shape = nil
        default:
            let link = try ConnectorSecrets.feedLink(pasted)
            source = link.source; secret = link.secret
            host = URL(string: link.source)?.host
            shape = try await probe(link.secret)
        }
        let prompt = CardDrafting.prompt(description: description, host: host, shape: shape)
        if let key = anthropicKey(), let reply = try? await ask(prompt, key: key),
           let card = try? CardDrafting.card(fromReply: reply, description: description, source: source, adapter: adapter) {
            return ConnectorDraft(card: card, secret: secret)
        }
        let card = CardDrafting.heuristicCard(description: description, source: source, adapter: adapter, shape: shape)
        return ConnectorDraft(card: card, secret: secret)
    }

    /// One download for the shape; the items are dropped here.
    private static func probe(_ address: String) async throws -> FeedShape? {
        guard let url = URL(string: address) else { throw ConnectorError.invalidSource }
        guard case .fetched(let data, _, _) = try await URLSessionFeedTransport().fetch(url, etag: nil, lastModified: nil)
        else { return nil }
        return FeedShape(try ICalendar(parsing: ICalAdapter.text(data)), timeZone: .current)
    }

    /// One Messages call with the Chat pane's model; the reply's text.
    private static func ask(_ prompt: CardPrompt, key: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": AskEngine.preferredModel, "max_tokens": 800, "system": prompt.system,
            "messages": [["role": "user", "content": prompt.user]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["content"] as? [[String: Any]] else { throw ConnectorError.badDraft }
        return content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
    }

    /// `KeyStore`'s key, read its way: `ANTHROPIC_API_KEY`, else the Keychain item, which only the
    /// app itself reads so a QA copy never raises the Keychain prompt.
    private static func anthropicKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty { return env }
        guard NSClassFromString("XCTestCase") == nil, Bundle.main.bundleIdentifier == "com.flamingo.app" else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.flamingo.anthropic",
            kSecAttrAccount as String: "api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }
}
