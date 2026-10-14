import SwiftUI
import FlamingoCore
import FlamingoDesign

/// Timeline of sessions and the files and thoughts inside them. Plan 07 owns.
///
/// Prefer `TrailView(store:onSelect:onResume:)`: it loads sessions itself, follows new
/// events as they're recorded, shows thumbnails, and saves chain names.
public struct TrailView: View {
    public var sessions: [TrailSession]
    public var onSelect: (FileRef, FileAnchor?) -> Void
    var store: TrailStore?
    var resumeAction: ((TrailSession) -> Void)?
    var renameAction: ((TrailSession, String?) -> Void)?
    @StateObject private var live = TrailLiveSessions()

    public init(sessions: [TrailSession], onSelect: @escaping (FileRef, FileAnchor?) -> Void) {
        self.sessions = sessions; self.onSelect = onSelect
    }

    /// Live timeline over `store`. `onResume` receives the session; reopen its
    /// `filesToReopen` as history.
    public init(store: TrailStore, onSelect: @escaping (FileRef, FileAnchor?) -> Void,
                onResume: ((TrailSession) -> Void)? = nil) {
        self.sessions = []
        self.onSelect = onSelect
        self.store = store
        self.resumeAction = onResume
    }

    /// Called for ⌘R or the ↻ glyph on a session.
    public func onResume(_ action: @escaping (TrailSession) -> Void) -> TrailView {
        var v = self; v.resumeAction = action; return v
    }

    /// Called when the user names (or un-names, with nil) a session. With a store, the name is
    /// also saved to `.flamingo/trail-names.json`. Without a store or this, renaming is off,
    /// since a name would be lost on the next redraw.
    public func onRename(_ action: @escaping (TrailSession, String?) -> Void) -> TrailView {
        var v = self; v.renameAction = action; return v
    }

    public var body: some View {
        TrailTimeline(
            sessions: store == nil ? sessions : live.sessions,
            vaultRoot: store?.vault.root,
            showsPaused: !TrailStore.isEnabled,
            onOpen: onSelect,
            onResume: resumeAction,
            onRename: store == nil && renameAction == nil ? nil : { session, title in
                if let store {
                    // The row already shows the new name; the file write needn't block the UI.
                    Task.detached(priority: .utility) { try? store.setTitle(title, for: session) }
                }
                renameAction?(session, title)
            }
        )
        .task(id: store.map(ObjectIdentifier.init)) { live.attach(store) }
    }
}

/// Keeps `sessions()` current for the live view: reloads off the main thread whenever the
/// store records something, coalescing bursts.
@MainActor
final class TrailLiveSessions: ObservableObject {
    @Published private(set) var sessions: [TrailSession] = []
    private var store: TrailStore?
    private var observer: NSObjectProtocol?
    private var scheduled: Task<Void, Never>?
    private var generation = 0

    func attach(_ store: TrailStore?) {
        if store === self.store, observer != nil { reload(); return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        self.store = store
        sessions = []
        guard let store else { return }
        observer = NotificationCenter.default.addObserver(
            forName: TrailStore.didChangeNotification, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        reload()
    }

    private func scheduleReload() {
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    func reload() {
        guard let store else { return }
        generation += 1
        let g = generation
        Task { [weak self] in
            let s = await Task.detached(priority: .userInitiated) { (try? store.sessions()) ?? [] }.value
            guard let self, g == self.generation else { return }
            if s != self.sessions { self.sessions = s }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
