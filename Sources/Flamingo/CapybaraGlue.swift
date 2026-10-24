import AppKit
import Observation
import FlamingoCore
import FlamingoLink

/// The link to Capybara on another Mac (plan 20), wired to the shell: the vault it shows, where
/// Open on MacBook lands, thoughts marked done from a Capybara task, and the toasts.
@MainActor
enum CapybaraGlue {
    static private(set) var link: CapybaraLink?
    static private(set) var ui: CapybaraLinkUI?

    static func install(state: AppState, window: NSWindow) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let link = CapybaraLink(name: Host.current().localizedName ?? "Flamingo",
                                directory: support.appendingPathComponent("Flamingo", isDirectory: true),
                                keychainService: "com.flamingo.app.link")
        let ui = CapybaraLinkUI(link: link)
        link.onChange = { [weak ui] in ui?.refresh() }
        link.revealFolder = { [weak state] path in
            guard let state else { return }
            state.hostWindow?.makeKeyAndOrderFront(nil)
            state.revealFolder(path)
        }
        link.revealThought = { [weak state] file, uid in state?.revealThought(in: file, uid: uid) }
        link.applyThoughtState = { [weak state] file, uid, newState in
            // Through the shell when the thought's vault is open: one undo step, the rail redraws.
            guard let state, let session = state.session else { return false }
            Task { @MainActor in
                guard let c = await session.comments(for: file).first(where: { $0.uid == uid }) else { return }
                state.setThoughtState(c, to: newState, in: file)
            }
            return true
        }
        link.notify = { [weak state] text in state?.showToast(ToastMessage(text: text)) }
        ui.attach(to: window)
        ui.installMenu()
        follow(state, link)
        link.start()
        ui.refresh()
        self.link = link
        self.ui = ui
    }

    static func stop() { link?.stop() }

    /// The vault Flamingo shows is the one Capybara sees, through every change.
    private static func follow(_ state: AppState, _ link: CapybaraLink) {
        withObservationTracking {
            link.setVault(state.vault)
        } onChange: {
            DispatchQueue.main.async { MainActor.assumeIsolated { follow(state, link) } }
        }
    }
}

extension AppState {
    /// Send to Capybara in a thought's menu: the thought goes to the paired Capybara as a card
    /// to accept or reject. Only this thought, only when chosen (CONTRACT.md, privacy).
    func sendToCapybara(_ comment: Comment, in file: FileRef) {
        guard let link = CapybaraGlue.link else { return }
        Task {
            guard let uid = try? await thoughtUID(for: comment, in: file) else {
                showToast(ToastMessage(text: "Not sent · the thought couldn't be saved"))
                return
            }
            let folder = isFolderNote(file) ? file.relativePath : file.directory
            switch link.send(text: comment.text, uid: uid, file: file, folder: folder, anchor: comment.anchor?.displayLabel, due: comment.meta?.due) {
            case .sent:
                showToast(ToastMessage(text: "Sent to Capybara"))
            case .queued:
                showToast(ToastMessage(text: "Capybara gets it when it's back on the network"))
            case .notPaired:
                showToast(ToastMessage(text: "Pair with Capybara first", action: "Pair…", perform: { CapybaraGlue.ui?.panel.show() }))
            }
        }
    }
}
