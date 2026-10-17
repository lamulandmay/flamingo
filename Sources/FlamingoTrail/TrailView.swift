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
    var linkAction: ((String, FileRef) -> Void)?
    var history: ActionHistory?
    @StateObject private var live = TrailLiveSessions()
    @State private var query = ""
    /// `query` once typing pauses; filtering every session per keystroke is what lags.
    @State private var settledQuery = ""
    @State private var onlyNamed = false
    @State private var activity = "all"
    @State private var renameError: String?
    @State private var renameRevision = 0
    @State private var correctionBusy = false
    @State private var failedCorrection: (TrailSession, TrailCorrectionAction)?

    public init(sessions: [TrailSession], onSelect: @escaping (FileRef, FileAnchor?) -> Void) {
        self.sessions = sessions; self.onSelect = onSelect
    }

    /// Live timeline over `store`. `onResume` receives the session; reopen its
    /// `filesToReopen` as history.
    public init(store: TrailStore, onSelect: @escaping (FileRef, FileAnchor?) -> Void,
                onResume: ((TrailSession) -> Void)? = nil,
                onOpenLink: ((String, FileRef) -> Void)? = nil) {
        self.sessions = []
        self.onSelect = onSelect
        self.store = store
        self.resumeAction = onResume
        self.linkAction = onOpenLink
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

    public func actionHistory(_ history: ActionHistory?) -> TrailView {
        var v = self; v.history = history; return v
    }

    public var body: some View {
      VStack(spacing: 0) {
        HStack(spacing: Theme.Space.xs) {
            SearchField(text: $query).frame(maxWidth: 260)
                .task(id: query) {
                    if !query.isEmpty { try? await Task.sleep(nanoseconds: 150_000_000) }
                    guard !Task.isCancelled else { return }
                    settledQuery = query
                }
            Spacer(minLength: Theme.Space.s)
            Menu {
                Picker("Show", selection: $activity) {
                    Text("All Activity").tag("all")
                    Text("Thoughts").tag("thoughts")
                    Text("Edits").tag("edits")
                }.pickerStyle(.inline)
                Divider()
                Toggle("Named Sessions Only", isOn: $onlyNamed)
            } label: {
                Image(systemName: activity == "all" && !onlyNamed ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                    .font(.system(size: Theme.Size.iconSmall))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(activity == "all" && !onlyNamed ? Theme.Color.textSecondary : Theme.Color.accent)
            .fixedSize()
            .frame(width: 24, height: 24)
            .help("Filter")
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 40)
        if let error = renameError ?? live.error {
            HStack {
                Text(error).font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary).textSelection(.enabled)
                Button(failedCorrection == nil ? "Reload" : "Retry correction") {
                    if let failedCorrection {
                        correctSession(failedCorrection.0, action: failedCorrection.1)
                        return
                    }
                    Task {
                        if let store { await Task.detached(priority: .utility) { store.flush() }.value }
                        live.reload()
                    }
                }
            }.padding(.horizontal, Theme.Space.m)
        }
        TrailTimeline(
            sessions: filteredSessions,
            vaultRoot: store?.vault.root,
            showsPaused: !TrailStore.isEnabled,
            onOpen: onSelect,
            onResume: resumeAction,
            onRename: store == nil && renameAction == nil ? nil : { session, title in
                if let store {
                    let historyContext = history?.contextID
                    // The row already shows the new name; the file write needn't block the UI.
                    Task {
                        let result = await Task.detached(priority: .utility) { Result { try store.renameSession(session, to: title) } }.value
                        guard live.isAttached(to: store), history?.contextID == historyContext else { return }
                        switch result {
                        case .success(let change):
                            renameError = nil
                            if change.before != change.after {
                                history?.register(name: "Rename session", undo: { [live, renameAction, revision = $renameRevision] in
                                    try store.restoreTitle(change.before, for: change.sessionID, expecting: change.after)
                                    renameAction?(session, change.before)
                                    revision.wrappedValue += 1; live.reload()
                                }, redo: { [live, renameAction, revision = $renameRevision] in
                                    try store.restoreTitle(change.after, for: change.sessionID, expecting: change.before)
                                    renameAction?(session, change.after)
                                    revision.wrappedValue += 1; live.reload()
                                })
                            }
                        case .failure(let error): renameError = "Could not save session name: " + error.localizedDescription
                        }
                        failedCorrection = nil
                        renameRevision += 1
                        live.reload()
                    }
                }
                renameAction?(session, title)
            },
            renameRevision: renameRevision,
            isFiltered: !settledQuery.isEmpty || onlyNamed || activity != "all",
            previousSessionNames: previousSessionNames,
            correctionBusy: correctionBusy,
            onCorrection: store == nil ? nil : correctSession
        )
        .environment(\.trailOpenLink, linkAction)
      }
        .task(id: store.map(ObjectIdentifier.init)) {
            correctionBusy = false; renameError = nil; failedCorrection = nil
            live.attach(store)
        }
    }

    private var filteredSessions: [TrailSession] {
        let all = store == nil ? sessions : live.sessions
        return all.filter { session in
            (!onlyNamed || session.title != nil) &&
            (activity == "all" || session.events.contains { $0.kind == (activity == "edits" ? .saved : .commented) }) && (settledQuery.isEmpty ||
                ([session.title ?? ""] + session.files.map(\.relativePath) + session.events.compactMap(\.text))
                    .contains { $0.localizedCaseInsensitiveContains(settledQuery) })
        }
    }

    private var previousSessionNames: [UUID: String] {
        let all = store == nil ? sessions : live.sessions
        var names: [UUID: String] = [:]
        for index in all.indices where index > 0 {
            let previous = all[index - 1]
            names[all[index].id] = previous.title ?? previous.files.first?.relativePath ?? "earlier activity"
        }
        return names
    }

    private func correctSession(_ session: TrailSession, action: TrailCorrectionAction) {
        guard let store, !correctionBusy else { return }
        let historyContext = history?.contextID
        correctionBusy = true
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try store.applyCorrection(action, to: session) }
            }.value
            guard live.isAttached(to: store), history?.contextID == historyContext else { return }
            correctionBusy = false
            switch result {
            case .success(let change):
                renameError = nil; failedCorrection = nil
                if change.before != change.after {
                    history?.register(name: action.undoName, undo: { [live] in
                        try store.restoreCorrections(change.before, expecting: change.after)
                        live.reload()
                    }, redo: { [live] in
                        try store.restoreCorrections(change.after, expecting: change.before)
                        live.reload()
                    })
                }
            case .failure(let error):
                renameError = "Could not save session correction: " + error.localizedDescription
                failedCorrection = (session, action)
            }
            live.reload()
        }
    }
}

private struct TrailOpenLinkKey: EnvironmentKey {
    static let defaultValue: ((String, FileRef) -> Void)? = nil
}
extension EnvironmentValues {
    var trailOpenLink: ((String, FileRef) -> Void)? {
        get { self[TrailOpenLinkKey.self] }
        set { self[TrailOpenLinkKey.self] = newValue }
    }
}

/// Keeps `sessions()` current for the live view: reloads off the main thread whenever the
/// store records something, coalescing bursts.
@MainActor
final class TrailLiveSessions: ObservableObject {
    @Published private(set) var sessions: [TrailSession] = []
    @Published private(set) var error: String?
    private var store: TrailStore?
    private var observer: NSObjectProtocol?
    private var scheduled: Task<Void, Never>?
    private var generation = 0

    func isAttached(to store: TrailStore) -> Bool { self.store === store }

    func attach(_ store: TrailStore?) {
        if store === self.store, observer != nil { reload(); return }
        generation += 1
        scheduled?.cancel(); scheduled = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        self.store = store
        sessions = []
        error = nil
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
            let result = await Task.detached(priority: .userInitiated) {
                Result { () -> ([TrailSession], String?) in
                    do {
                        return (try store.sessions(), store.persistenceError.map { "Trail changes are waiting to save: " + $0 } ?? store.namesError)
                    } catch {
                        // Keep the unmodified history readable if correction metadata needs repair.
                        return (try store.sessions(ignoringCorrections: true), "Session corrections could not be loaded: " + error.localizedDescription)
                    }
                }
            }.value
            guard let self, g == self.generation else { return }
            switch result {
            case .success(let snapshot):
                if snapshot.0 != self.sessions { self.sessions = snapshot.0 }
                self.error = snapshot.1
            case .failure(let error): self.error = "Could not load Trail: " + error.localizedDescription
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
