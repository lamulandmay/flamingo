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
    /// The shell keeps this current so the panel knows what to attach to.
    public var currentTarget: (() -> (FileRef, FileAnchor?)?)?
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

    private init() {
        host.window.onCancel = { [weak self] in self?.cancel() }
    }

    // MARK: Hotkeys

    /// ⌘⇧C inside the app. Pressing it again while the panel is up dismisses it.
    public func installInAppHotkey() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "c" else { return event }
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
    /// thought goes to today's inbox note in the current vault.
    public func show() {
        if host.isVisible { return cancel() }
        let vault = knownVaults().first
        let target: Target
        if let (file, anchor) = currentTarget?() {
            target = Target(vault: vault, file: file, anchor: anchor)
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
        if host.isVisible { return cancel() }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return show() }
        FrontmostContext.requestAccessibilityIfNeeded()
        let vaults = knownVaults()
        let ctx = FrontmostContext.current(in: vaults)
        if ctx?.isFlamingo == true { return show() }

        let target: Target
        if let v = ctx?.vault, let f = ctx?.file {
            target = Target(vault: v, file: f, anchor: ctx?.anchor)
        } else if let v = vaults.first {
            target = .inbox(in: v)
        } else {
            NSSound.beep(); return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let over = ctx?.windowFrame ?? screen?.visibleFrame ?? .zero
        present(target, over: over, level: .modalPanel, returnTo: front)
    }

    /// Toggles the panel: dismisses it if up, otherwise `show()`.
    public func toggle() { host.isVisible ? cancel() : show() }

    /// Dismisses the panel without saving.
    public func cancel() {
        let p = presentation
        presentation = nil
        host.dismiss { [weak self] in self?.restoreFocus(p) }
    }

    // MARK: Internals

    struct Target: Equatable {
        var vault: Vault?
        var file: FileRef
        var anchor: FileAnchor?
        var label: String?

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
        return panel
    }

    private func submit(_ comment: Comment) {
        guard let p = presentation else { return }
        presentation = nil
        save(comment, to: p.target)
        host.dismiss { [weak self] in self?.restoreFocus(p) }
    }

    /// The shell's `onComment` handles the current vault (it refreshes the rail and records
    /// the trail). Thoughts for another open vault, or before the shell is wired, go
    /// straight through that vault's `SidecarStore` and `TrailStore`.
    private func save(_ comment: Comment, to target: Target) {
        let current = knownVaults().first
        if let onComment, target.vault == nil || target.vault == current {
            onComment(target.file, comment)
            return
        }
        guard let vault = target.vault else { return }
        do {
            try SidecarStore(vault: vault).append(comment, to: target.file)
            TrailStore(vault: vault).record(TrailEvent(kind: .commented, file: target.file,
                                                       anchor: comment.anchor, text: comment.text))
        } catch {
            NSSound.beep()
        }
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
        Task.detached(priority: .userInitiated) {
            let files = VaultScanner.files(in: vault)
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
