import AppKit
import SwiftUI
import FlamingoCore
import FlamingoCapture
import FlamingoDesign
import FlamingoExtract

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    private var swipes: SwipeNavigator?
    private var radialRecents: RadialRecentsController?
    private let recentsMenu = RecentFilesMenu()
    var undoRouting: UndoRouting?
    var globalSearchShortcut: GlobalSearchShortcut?
    let state = AppState()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Settings ▸ Appearance; `-FlamingoAppearance dark|light` pins it for screenshots.
        Defaults.appearance.apply()
        Extract.registerDefaults()
        MainMenu.install()
        AppIcon.installFallbackIfNeeded()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        QAHook.install()
        MainWindow.isGraphMode = { [weak self] in self?.state.mode == .graph }
        MainWindow.unclaimedReturn = { [weak self] in self?.state.renameInTitle() ?? false }
        let w = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Flamingo"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.titlebarSeparatorStyle = .none
        // An empty unified toolbar gives the taller title bar with centred traffic lights;
        // the shell draws the mode switcher in that strip itself.
        let toolbar = NSToolbar(identifier: "com.flamingo.main")
        toolbar.showsBaselineSeparator = false
        w.toolbar = toolbar
        w.toolbarStyle = .unifiedCompact
        w.isMovableByWindowBackground = true
        w.minSize = NSSize(width: 820, height: 480)
        w.tabbingMode = .disallowed
        // Closing only hides it, so the Dock icon can show it again.
        w.isReleasedWhenClosed = false
        w.backgroundColor = Theme.NS.bg
        w.contentView = NSHostingView(rootView: RootView().environmentObject(state))
        if !w.setFrameUsingName("FlamingoMain") { w.center() }
        w.setFrameAutosaveName("FlamingoMain")
        w.delegate = self
        window = w
        state.hostWindow = w
        undoRouting = UndoRouting(window: w, history: state.actionHistory,
                                  undo: { [weak self] in self?.state.undoAction() },
                                  redo: { [weak self] in self?.state.redoAction() })
        swipes = SwipeNavigator(state: state, window: w)
        radialRecents = RadialRecentsController(state: state, window: w)
        recentsMenu.install(state: state)
        state.windowWidth = w.frame.width
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        CaptureController.shared.installInAppHotkey()
        CaptureController.shared.installGlobalHotkey()   // stays off until the captureGlobal default is on
        globalSearchShortcut = GlobalSearchShortcut { [weak self] in
            // Leave the Carbon callback before showing the nonactivating search panel.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.state.briefing.noteGlobalPalette()
                PaletteController.shared.showFromAnyApp(state: self.state)
            }
        }
        globalSearchShortcut?.install()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--vault"), i + 1 < args.count {
            state.open(URL(fileURLWithPath: args[i + 1]))
        } else {
            state.restoreLastVault()
        }
        state.briefing.recoverInterruptedZoom()
        state.briefing.install()
        state.briefing.catchUp = { [weak state] onEvent in _ = await state?.nightShiftCatchUp(onEvent: onEvent) }
        state.briefing.now = { AppState.now }
        // The rail's local graph takes first responder as it appears; keys start in the sidebar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let w = self.window, !(w.firstResponder is NSText) else { return }
            self.state.focusSidebar?()
        }
    }

    // Dock drops and `open -a Flamingo <folder>`.
    func application(_ application: NSApplication, open urls: [URL]) {
        state.briefing.noteOpenFileRequest()
        state.handleDropped(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    /// ⌘Q is the only way to quit. Closing the window leaves Flamingo running; the Dock icon
    /// brings the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard state.preserveOpenDrafts() else { window?.makeKeyAndOrderFront(nil); return .terminateCancel }
        return .terminateNow
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { state.preserveOpenDrafts() }

    func applicationWillTerminate(_ notification: Notification) {
        globalSearchShortcut?.uninstall()
        state.persistWorkspace()
        _ = state.preserveOpenDrafts()
        state.session?.trail.flush()
        state.session?.stop()
    }

    func windowDidResize(_ notification: Notification) {
        if let w = window, state.windowWidth != w.frame.width { state.windowWidth = w.frame.width }
    }

    /// Keyboard focus starts in the sidebar, but a field or preview the user clicked keeps it.
    func windowDidBecomeKey(_ notification: Notification) {
        guard let w = window, w.firstResponder === w || w.firstResponder === w.contentView else { return }
        state.focusSidebar?()
    }
}

/// Until plan 08's icns lands in the bundle, the Dock shows a drawn mark instead of the generic app icon.
enum AppIcon {
    @MainActor
    static func installFallbackIfNeeded() {
        let info = Bundle.main.infoDictionary ?? [:]
        if info["CFBundleIconFile"] != nil || info["CFBundleIconName"] != nil { return }
        let side: CGFloat = 512
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let inset = rect.insetBy(dx: side * 0.1, dy: side * 0.1)
            let radius = inset.width * 0.225
            Theme.NS.accent.setFill()
            NSBezierPath(squircleIn: inset, radius: radius).fill()
            let config = NSImage.SymbolConfiguration(pointSize: side * 0.46, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let symbol = (NSImage(systemSymbolName: "bird.fill", accessibilityDescription: nil)
                             ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil))?
                .withSymbolConfiguration(config) {
                let s = symbol.size
                let origin = NSPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2)
                symbol.draw(in: NSRect(origin: origin, size: s))
            }
            return true
        }
        NSApp.applicationIconImage = image
    }
}

/// The main window. Plan 06's graph canvas takes first responder whenever it enters a window,
/// and the rail rebuilds its local graph on every selection, so the sidebar would lose the
/// keyboard after one arrow press. Outside Graph mode the canvas gets focus only by a click.
final class MainWindow: NSWindow {
    static var isGraphMode: () -> Bool = { false }
    /// ↩ that nothing on screen took: true when it started a rename (`AppState.renameInTitle`).
    static var unclaimedReturn: () -> Bool = { false }
    /// Set around a `setFrame(animate: true)` that should take this long (the briefing's zoom).
    static var animationDuration: TimeInterval?

    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        Self.animationDuration ?? super.animationResizeTime(newFrame)
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let view = responder as? NSView, String(describing: type(of: view)) == "GraphInputNSView",
           !Self.isGraphMode(), !Self.isClick(in: view) {
            return false
        }
        return super.makeFirstResponder(responder)
    }

    // ↩ reaches the window only when no text, list or preview used it: a key a view passed
    // on, or the command a view's key bindings made of it. Either renames the current file.
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if [36, 76].contains(event.keyCode), modifiers.isEmpty, attachedSheet == nil, Self.unclaimedReturn() { return }
        super.keyDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        guard let event = NSApp.currentEvent, event.type == .keyDown, [36, 76].contains(event.keyCode),
              attachedSheet == nil, Self.unclaimedReturn() else { NSSound.beep(); return }
    }

    private static func isClick(in view: NSView) -> Bool {
        guard let e = NSApp.currentEvent, [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(e.type),
              e.window === view.window else { return false }
        return view.bounds.contains(view.convert(e.locationInWindow, from: nil))
    }
}
