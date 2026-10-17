import AppKit
import Carbon.HIToolbox
import FlamingoCore
import FlamingoTrail

/// Registers the capture hotkeys and shows `CommentPanel` as a floating panel. Plan 03 owns.
///
/// The shell sets `currentTarget`, `onComment` and `vaults`, then calls `installInAppHotkey()`
/// and `installGlobalHotkey()` once. The global hotkey stays off until the `captureGlobal`
/// default is true; flipping the default (e.g. from an `@AppStorage` toggle) takes effect live.
@MainActor
public final class CaptureController {
    public static let shared = CaptureController()
    /// Called when a comment is submitted. The shell sets this.
    public var onComment: ((FileRef, Comment) -> Void)?
    /// Preferred shell callback: returns only after the sidecar write is committed.
    public var onSaveComment: ((FileRef, Comment) async throws -> Void)?
    /// Reuses the shell's current catalog instead of rescanning the vault for capture.
    public var availableFiles: ((Vault) -> [FileRef])?
    /// The shell keeps this current so the panel knows what to attach to.
    public var currentTarget: (() -> (FileRef, FileAnchor?)?)?
    /// The folder selected in the shell when no file is: `show()` then leaves the thought on that
    /// folder's note (`.flamingo/notes/<folder>.md`, `subject: folder`) instead of the inbox.
    public var currentFolder: (() -> FileRef?)?
    /// Like `onSaveComment`, for a thought on a note with no file behind it that may not exist
    /// yet (a folder, a web page). Receives the front matter a new note starts with. Without it
    /// such thoughts are written straight through `SidecarStore`.
    public var onSaveNoteComment: ((FileRef, Comment, [String: String]) async throws -> Void)?
    /// Earlier thoughts like a draft, best first, for the echo rows above the field. Nil turns
    /// the rows off. The shell backs it with `IndexStore.similarThoughts`.
    public var similarThoughts: ((String) async -> [EchoHit])?
    /// An echo row was clicked: the shell brings Flamingo forward and shows the thought. The
    /// panel closes first, keeping its draft.
    public var onJumpToThought: ((EchoHit) -> Void)?
    /// Open vaults, the current one first. Global capture only lands in these; `[[`
    /// completion and the inbox fallback use the first. Falls back to the shell's
    /// `lastVault` default when unset.
    public var vaults: (() -> [Vault])?

    /// UserDefaults key gating the global hotkey.
    public static let globalDefaultsKey = "captureGlobal"

    public var isShowing: Bool { host.isVisible }

    /// The `captureGlobal` default. Turning it on registers the hotkey and asks for
    /// Accessibility (the system prompt is the only UI).
    public var isGlobalCaptureEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.globalDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.globalDefaultsKey); applyGlobalSetting() }
    }

    /// The global shortcuts actually registered, for menus: `["⌃⌥Space"]`, plus `⌃⌥⌘Space`
    /// when macOS already uses ⌃⌥Space ("Select next source in Input menu"). Empty when off.
    public private(set) var globalShortcuts: [String] = []

    private let host = CapturePanelHost()
    private var presentation: Presentation?
    private var localMonitor: Any?
    private var globalHotkeys: [GlobalHotkey] = []
    private var defaultsObserver: NSObjectProtocol?
    private var globalApplied: Bool?
    private var candidateCache: [Vault: (files: [FileRef], recent: [FileRef])] = [:]
    private var scanning: Set<Vault> = []
    private var saving = false
    /// "Saving…" shows only when a save is slow enough to notice.
    private var savingShown = false
    private var saveError: String?
    private var draftText = ""
    private var draftCommitted = false
    private var hasDraftSnapshot = false

    private init() {
        host.window.onCancel = { [weak self] in self?.cancel() }
        // Clicking away from an empty panel dismisses it; typed text is never thrown away.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: host.window,
                                               queue: .main) { _ in
            MainActor.assumeIsolated {
                let c = CaptureController.shared
                if c.host.isVisible, c.host.isEmpty { c.cancel() }
            }
        }
    }

    // MARK: Hotkeys

    /// ⌘⇧C inside the app. Pressing it again while the panel is up dismisses it.
    public func installInAppHotkey() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "c",
                  NSApp.modalWindow == nil else { return event }
            MainActor.assumeIsolated { CaptureController.shared.toggle() }
            return nil
        }
    }

    /// ⌃⌥Space from any app, via Carbon (no Accessibility needed for the key itself).
    /// Does nothing until the `captureGlobal` default is true, and follows the default live.
    public func installGlobalHotkey() {
        if defaultsObserver == nil {
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { CaptureController.shared.applyGlobalSetting() }
            }
        }
        applyGlobalSetting()
    }

    private func applyGlobalSetting() {
        guard defaultsObserver != nil else { return }
        let on = isGlobalCaptureEnabled
        guard on != globalApplied else { return }
        let atLaunch = globalApplied == nil
        globalApplied = on
        globalHotkeys.forEach { $0.unregister() }
        globalHotkeys = []
        globalShortcuts = []
        guard on else { return }

        // Leave the Carbon callback before probing: AppleScript waits on replies.
        let fire = { DispatchQueue.main.async { CaptureController.shared.captureFromFrontmost() } }
        let primary = GlobalHotkey.capture(fire)
        if primary.register() { globalHotkeys.append(primary); globalShortcuts.append("⌃⌥Space") }
        if !primary.isRegistered
            || GlobalHotkey.conflictsWithSystemShortcut(keyCode: primary.keyCode, modifiers: primary.modifiers) {
            let fallback = GlobalHotkey(keyCode: GlobalHotkey.captureKeyCode,
                                        modifiers: GlobalHotkey.captureModifiers | UInt32(cmdKey), handler: fire)
            if fallback.register() { globalHotkeys.append(fallback); globalShortcuts.append("⌃⌥⌘Space") }
        }
        if !atLaunch { FrontmostContext.requestAccessibilityIfNeeded() }
    }

    // MARK: Showing

    /// Leaves a thought on the shell's current file and anchor. With no file selected the
    /// thought goes to today's inbox note in the current vault. With the panel already up this
    /// only brings it forward, so a menu item can call it alongside the ⌘⇧C monitor.
    public func show() { showTarget(folder: nil) }

    /// Leaves a thought on a folder's note (`.flamingo/notes/<folder>.md`), for a folder
    /// selected with no file. `folder` is relative to the vault root.
    public func show(folder: FileRef) { showTarget(folder: folder) }

    private func showTarget(folder explicit: FileRef?) {
        if host.isVisible { return host.refocus() }
        let vault = knownVaults().first
        let target: Target
        if let explicit, let vault, let note = ThoughtNote.folder(explicit) {
            target = Target(vault: vault, note: note)
        } else if let (file, anchor) = currentTarget?() {
            target = Target(vault: vault, file: file, anchor: anchor)
        } else if let vault, let note = currentFolder?().flatMap(ThoughtNote.folder) {
            target = Target(vault: vault, note: note)
        } else if let vault {
            target = .inbox(in: vault)
        } else {
            NSSound.beep(); return
        }
        let over = (NSApp.keyWindow ?? NSApp.mainWindow)?.frame
            ?? NSScreen.main?.visibleFrame ?? .zero
        present(target, over: over, level: .floating, returnTo: nil)
    }

    /// Leaves a thought on whatever is frontmost in another app: the document in its focused
    /// window and, where the app says, the slide, page, cell or time. Documents outside every
    /// vault go to today's inbox note in the current vault. Focus returns to that app after.
    public func captureFromFrontmost() {
        if host.isVisible { return hotkeyWhileVisible() }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return show() }
        FrontmostContext.requestAccessibilityIfNeeded()
        let vaults = knownVaults()
        let candidates = Dictionary(uniqueKeysWithValues: vaults.map { ($0, availableFiles?($0) ?? candidateCache[$0]?.files ?? []) })
        let ctx = FrontmostContext.current(in: vaults, candidates: candidates)
        if ctx?.isFlamingo == true { return show() }

        guard let target = Target.forFrontmost(ctx, vaults: vaults) else { NSSound.beep(); return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let over = ctx?.windowFrame ?? screen?.visibleFrame ?? .zero
        present(target, over: over, level: .modalPanel, returnTo: front)
    }

    /// What ⌘⇧C does: refocuses a panel that lost focus, dismisses a focused one, else `show()`.
    public func toggle() { host.isVisible ? hotkeyWhileVisible() : show() }

    /// The hotkey on a panel that's already up: bring it back if focus wandered off (the
    /// thought is still there), otherwise dismiss it like Esc.
    private func hotkeyWhileVisible() {
        if host.window.isKeyWindow { cancel() } else { host.refocus() }
    }

    /// Dismisses the panel after preserving its draft for recovery.
    public func cancel() {
        guard !saving else { return }
        guard preserveDraft() else { return }
        let p = presentation
        presentation = nil
        host.dismiss { [weak self] in self?.restoreFocus(p) }
    }

    /// Synchronous window/termination checkpoint; serialization runs on the recovery queue.
    @discardableResult
    public func preserveDraft() -> Bool {
        guard let target = presentation?.target, !draftCommitted else { return true }
        guard hasDraftSnapshot || !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        guard let vault = target.vault else {
            guard !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
            saveError = "Choose a workspace before closing, or copy this thought. No draft location is available."
            host.update(panel(for: target)); return false
        }
        draftChanged(draftText)
        if let failure = ThoughtDraftCheckpoint.flush(key: CaptureDraftStore.recoveryKey(for: target.file, in: vault)) {
            saveError = "Draft recovery unavailable: " + failure
            host.update(panel(for: target)); return false
        }
        return true
    }

    // MARK: Internals

    struct Target: Equatable {
        var vault: Vault?
        var file: FileRef
        var anchor: FileAnchor?
        var label: String?
        var provenance: CommentProvenance?
        /// Front matter for a note that may not exist yet (folder, web page).
        var frontmatter: [String: String] = [:]
        var isFolder = false
        /// Selected text from another app, as `> ` lines. Shown above the field and saved with the thought.
        var quote: String?
        /// The uid of the thought the draft answers.
        var replyParent: String?

        init(vault: Vault?, file: FileRef, anchor: FileAnchor? = nil, label: String? = nil, provenance: CommentProvenance? = nil) {
            self.vault = vault; self.file = file; self.anchor = anchor; self.label = label; self.provenance = provenance
        }

        init(vault: Vault?, note: ThoughtNote) {
            self.init(vault: vault, file: note.file, label: note.name)
            frontmatter = note.frontmatter; isFolder = note.isFolder
        }

        /// What a capture from another app lands on. A document in a vault gets its anchor; a web
        /// page no vault file stands behind gets a `_web/` note; anything else, today's inbox. The
        /// selected text becomes the quote in each case. Nil with no vault to write to.
        static func forFrontmost(_ ctx: FrontmostContext?, vaults: [Vault], date: Date = Date()) -> Target? {
            var target: Target
            if let v = ctx?.vault, let f = ctx?.file {
                target = Target(vault: v, file: f, anchor: ctx?.anchor)
            } else if let v = vaults.first {
                if let url = ctx?.sourceURL?.absoluteString, let web = ThoughtNote.web(url: url, title: ctx?.windowTitle) {
                    target = Target(vault: v, note: web)
                } else {
                    target = .inbox(in: v, on: date)
                }
            } else {
                return nil
            }
            target.quote = ThoughtQuote.lines(from: ctx?.selectedText)
            target.provenance = CommentProvenance(origin: .human, appBundleID: ctx?.appBundleID,
                appName: ctx?.appName, windowTitle: ctx?.windowTitle,
                sourceURL: ctx?.sourceURL?.absoluteString ?? ctx?.documentURL?.absoluteString)
            return target
        }

        static let inboxFolder = "_inbox"

        /// `.flamingo/notes/_inbox/<yyyy-MM-dd>.md` via `SidecarStore`'s path mapping.
        static func inbox(in vault: Vault, on date: Date = Date()) -> Target {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            let day = f.string(from: date)
            return Target(vault: vault, file: FileRef(relativePath: "\(inboxFolder)/\(day)"), label: "inbox · \(day)")
        }
    }

    private struct Presentation {
        var target: Target
        /// Window to make key again after an in-app capture.
        weak var previousKeyWindow: NSWindow?
        /// App to hand focus back to after a global capture.
        var returnTo: NSRunningApplication?
    }

    func knownVaults() -> [Vault] {
        if let vs = vaults?(), !vs.isEmpty { return vs }
        if let p = UserDefaults.standard.string(forKey: "lastVault") { return [Vault(root: URL(fileURLWithPath: p))] }
        return []
    }

    func present(_ target: Target, over frame: NSRect, level: NSWindow.Level, returnTo app: NSRunningApplication?) {
        var target = target
        let restored = target.vault.flatMap { CaptureDraftStore.drafts(in: $0).last { $0.file == target.file } }
        if let restored {
            target.anchor = restored.anchor; target.provenance = restored.provenance
            // The draft already holds what was quoted when it was written.
            target.quote = nil; target.replyParent = restored.replyParent
            if let fm = restored.frontmatter { target.frontmatter = fm; target.isFolder = restored.isFolder ?? false
                target.label = target.label ?? fm["title"] ?? fm["url"].flatMap { URL(string: $0)?.host } ?? restored.file.name }
        }
        draftText = restored?.text ?? ""
        hasDraftSnapshot = restored != nil
        saveError = nil
        saving = false
        draftCommitted = false
        presentation = Presentation(target: target, previousKeyWindow: NSApp.keyWindow, returnTo: app)
        host.present(panel(for: target), over: frame, level: level)
        if let vault = target.vault { loadCandidates(for: vault) }
    }

    private func panel(for target: Target) -> CommentPanel {
        let cached = target.vault.flatMap { candidateCache[$0] }
        var panel = CommentPanel(target: target.file, anchor: target.anchor,
                                 candidates: cached?.files ?? [], recent: cached?.recent ?? [],
                                 onSubmit: { [weak self] c in self?.submit(c) },
                                 onCancel: { [weak self] in self?.cancel() })
        panel.label = target.label
        panel.isFolder = target.isFolder
        panel.quote = target.quote
        panel.replyParent = target.replyParent
        panel.similar = similarThoughts
        panel.onJumpEcho = { [weak self] hit in self?.jumpToThought(hit) }
        panel.onReplyEcho = { [weak self] hit in self?.replyTo(hit) }
        panel.initialText = draftText
        panel.saving = saving
        panel.showsSaving = savingShown
        panel.error = saveError
        panel.onTextChange = { [weak self] text in self?.draftChanged(text) }
        panel.onDiscard = { [weak self] in self?.discardDraft() }
        return panel
    }

    /// Opens the most recently edited unsaved thought in the active vault.
    public func recoverDraft() {
        guard !host.isVisible, let vault = knownVaults().first,
              let draft = CaptureDraftStore.drafts(in: vault).max(by: { $0.updatedAt < $1.updatedAt }) else { return }
        var target = Target(vault: vault, file: draft.file, anchor: draft.anchor, provenance: draft.provenance)
        if let fm = draft.frontmatter { target.frontmatter = fm; target.isFolder = draft.isFolder ?? false; target.label = fm["title"] ?? fm["url"].flatMap { URL(string: $0)?.host } ?? draft.file.name }
        present(target,
                over: (NSApp.keyWindow ?? NSApp.mainWindow)?.frame ?? NSScreen.main?.visibleFrame ?? .zero,
                level: .floating, returnTo: nil)
    }

    private func draftChanged(_ text: String) {
        draftText = text
        guard hasDraftSnapshot || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        hasDraftSnapshot = true
        guard let target = presentation?.target, let vault = target.vault else { return }
        var draft = CaptureDraft(file: target.file, anchor: target.anchor, text: text, provenance: target.provenance)
        draft.replyParent = target.replyParent
        if !target.frontmatter.isEmpty { draft.frontmatter = target.frontmatter; draft.isFolder = target.isFolder }
        CaptureDraftStore.checkpoint(draft, in: vault) { [weak self] failure in
            guard let failure else { return }
            Task { @MainActor in
                guard let self, self.presentation?.target.file == target.file else { return }
                self.saveError = "Draft recovery unavailable: " + failure
                self.host.update(self.panel(for: target))
            }
        }
    }

    private func discardDraft() {
        guard let p = presentation, let vault = p.target.vault, !saving else { return }
        saving = true; saveError = nil
        host.update(panel(for: p.target))
        let key = CaptureDraftStore.recoveryKey(for: p.target.file, in: vault)
        ThoughtDraftCheckpoint.enqueue(key: key, operation: { try CaptureDraftStore.remove(p.target.file, in: vault) })
        Task {
            if let failure = await ThoughtDraftCheckpoint.flushAsync(key: key) {
                saving = false; saveError = "Draft was not discarded: " + failure
                host.update(panel(for: p.target))
            } else {
                saving = false; draftText = ""; hasDraftSnapshot = false; presentation = nil
                host.dismiss { self.restoreFocus(p) }
            }
        }
    }

    private func submit(_ comment: Comment) {
        guard let p = presentation, !saving else { return }
        saving = true
        savingShown = false
        saveError = nil
        var comment = comment
        comment.provenance = p.target.provenance
        comment.text = ThoughtQuote.compose(quote: p.target.quote, text: comment.text)
        comment = comment.stamped()
        if let parent = p.target.replyParent { comment = comment.replying(toUID: parent) }
        host.update(panel(for: p.target))
        draftChanged(comment.text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.saving, self.presentation?.target == p.target else { return }
            self.savingShown = true
            self.host.update(self.panel(for: p.target))
        }
        Task {
            if let vault = p.target.vault {
                _ = await ThoughtDraftCheckpoint.flushAsync(key: CaptureDraftStore.recoveryKey(for: p.target.file, in: vault))
            }
            do {
                try await save(comment, to: p.target)
                draftCommitted = true
                if let vault = p.target.vault {
                    let key = CaptureDraftStore.recoveryKey(for: p.target.file, in: vault)
                    ThoughtDraftCheckpoint.enqueue(key: key, required: false, operation: {
                        try CaptureDraftStore.remove(p.target.file, in: vault)
                    })
                    _ = await ThoughtDraftCheckpoint.flushAsync(key: key)
                }
                saving = false
                savingShown = false
                presentation = nil
                host.dismiss { self.restoreFocus(p) }
            } catch {
                saving = false
                savingShown = false
                saveError = "Not saved: " + error.localizedDescription
                draftChanged(comment.text)
                host.update(panel(for: p.target))
            }
        }
    }

    /// The shell's `onComment` handles the current vault (it refreshes the rail and records
    /// the trail). Thoughts for another open vault, or before the shell is wired, go
    /// straight through that vault's `SidecarStore` and `TrailStore`.
    private func save(_ comment: Comment, to target: Target) async throws {
        let comment = comment.stamped()
        let current = knownVaults().first
        if target.vault == nil || target.vault == current {
            if !target.frontmatter.isEmpty, let onSaveNoteComment {
                try await onSaveNoteComment(target.file, comment, target.frontmatter)
                return
            }
            if target.frontmatter.isEmpty, let onSaveComment {
                try await onSaveComment(target.file, comment)
                return
            }
        }
        // Legacy callbacks cannot acknowledge writes. Commit here when no acknowledged
        // callback is installed; the watcher refreshes the shell from the actual write.
        guard let vault = target.vault else { throw CocoaError(.fileNoSuchFile) }
        try await Task.detached {
            let store = SidecarStore(vault: vault)
            if target.frontmatter.isEmpty { try store.append(comment, to: target.file) }
            else { try store.append(comment, to: target.file, frontmatter: target.frontmatter) }
            TrailStore(vault: vault).recordComment(comment, on: target.file)
        }.value
    }

    // MARK: Echo

    /// An echo row was clicked: close the panel, keeping the draft, and let the shell show the thought.
    private func jumpToThought(_ hit: EchoHit) {
        cancel()
        onJumpToThought?(hit)
    }

    /// An echo row was ⌥-clicked: the draft now answers that thought, in its note.
    private func replyTo(_ hit: EchoHit) {
        guard var p = presentation, !saving, let uid = hit.uid, let vault = p.target.vault else { return }
        let old = p.target
        guard old.file != hit.file else {
            presentation?.target.replyParent = uid
            presentation?.target.quote = old.quote
            host.update(panel(for: presentation!.target)); return
        }
        var target = Target(vault: vault, file: hit.file, label: hit.file.name)
        target.replyParent = uid
        target.quote = old.quote
        target.provenance = old.provenance
        p.target = target
        presentation = p
        // The draft belongs to the new note now; the old note keeps no stray copy.
        let oldKey = CaptureDraftStore.recoveryKey(for: old.file, in: vault)
        ThoughtDraftCheckpoint.enqueue(key: oldKey, required: false, operation: { try CaptureDraftStore.remove(old.file, in: vault) })
        draftChanged(draftText)
        host.update(panel(for: target))
    }

    /// A non-activating panel hands key focus back to the frontmost app on its own; this is
    /// the safety net if Flamingo is somehow still active a beat later.
    private func restoreFocus(_ p: Presentation?) {
        guard let p else { return }
        if let app = p.returnTo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, NSApp.isActive, !self.host.isVisible, !app.isTerminated else { return }
                NSApp.yieldActivation(to: app)
                app.activate()
            }
        } else if let w = p.previousKeyWindow, w.isVisible {
            w.makeKey()
        }
    }

    /// Scans the vault off the main thread; the panel picks up the result when it lands.
    private func loadCandidates(for vault: Vault) {
        guard !scanning.contains(vault) else { return }
        scanning.insert(vault)
        let supplied = availableFiles?(vault)
        Task.detached(priority: .userInitiated) {
            let files = supplied ?? VaultScanner.files(in: vault)
            let since = Date().addingTimeInterval(-14 * 86_400)
            let events = (try? TrailStore(vault: vault).events(since: since)) ?? []
            var seen = Set<FileRef>(), recent: [FileRef] = []
            for e in events.sorted(by: { $0.at > $1.at }) {
                if let f = e.file, seen.insert(f).inserted { recent.append(f) }
            }
            let found = recent
            await MainActor.run {
                let c = CaptureController.shared
                c.scanning.remove(vault)
                c.candidateCache[vault] = (files, found)
                if let p = c.presentation, p.target.vault == vault { c.host.update(c.panel(for: p.target)) }
            }
        }
    }
}
