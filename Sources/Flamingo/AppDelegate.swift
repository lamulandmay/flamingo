import AppKit
import SwiftUI
import FlamingoCore
import FlamingoCapture
import FlamingoDesign
import FlamingoExtract

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let state = AppState()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // QA hook: `-FlamingoAppearance dark|light` pins the appearance for screenshots.
        if let a = UserDefaults.standard.string(forKey: "FlamingoAppearance") {
            NSApp.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua)
        }
        Extract.registerDefaults()
        MainMenu.install()
        AppIcon.installFallbackIfNeeded()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
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
        w.backgroundColor = Theme.NS.bg
        w.contentView = NSHostingView(rootView: RootView().environmentObject(state))
        if !w.setFrameUsingName("FlamingoMain") { w.center() }
        w.setFrameAutosaveName("FlamingoMain")
        w.delegate = self
        window = w
        state.hostWindow = w
        state.windowWidth = w.frame.width
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        CaptureController.shared.installInAppHotkey()
        CaptureController.shared.installGlobalHotkey()   // stays off until the captureGlobal default is on
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--vault"), i + 1 < args.count {
            state.open(URL(fileURLWithPath: args[i + 1]))
        } else {
            state.restoreLastVault()
        }
    }

    // Dock drops and `open -a Flamingo <folder>`.
    func application(_ application: NSApplication, open urls: [URL]) {
        state.handleDropped(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
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
            NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius).fill()
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
