import AppKit
import FlamingoCore
import FlamingoDesign

/// The menu bar. Every action goes through the responder chain to `AppDelegate`,
/// which forwards to `AppState`. Key hints live here and in the palette only. Plan 01 owns.
@MainActor
enum MainMenu {
    private static var recentMenu: NSMenu?

    static func install() {
        let main = NSMenu()

        // Flamingo
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Flamingo", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Flamingo", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Flamingo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // File
        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open Vault…", action: #selector(AppDelegate.openVault(_:)), keyEquivalent: "o")
        let recentItem = fileMenu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        let recent = NSMenu(title: "Open Recent")
        recentItem.submenu = recent
        recentMenu = recent
        fileMenu.addItem(.separator())
        let thought = fileMenu.addItem(withTitle: "Leave a Thought", action: #selector(AppDelegate.leaveThought(_:)), keyEquivalent: "c")
        thought.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "Capture from Any App", action: #selector(AppDelegate.toggleGlobalCapture(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        let openWith = fileMenu.addItem(withTitle: "Open in Default App", action: #selector(AppDelegate.openExternally(_:)), keyEquivalent: "\r")
        openWith.keyEquivalentModifierMask = [.command]
        let reveal = fileMenu.addItem(withTitle: "Reveal in Finder", action: #selector(AppDelegate.revealInFinder(_:)), keyEquivalent: "r")
        reveal.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "Copy Path", action: #selector(AppDelegate.copyPath(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Reindex Vault", action: #selector(AppDelegate.reindex(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        // Edit
        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        // View
        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        for m in FlamingoMode.allCases {
            let item = viewMenu.addItem(withTitle: m.title, action: #selector(AppDelegate.setMode(_:)), keyEquivalent: String(m.rawValue + 1))
            item.tag = m.rawValue
        }
        viewMenu.addItem(.separator())
        let rail = viewMenu.addItem(withTitle: "Comments", action: #selector(AppDelegate.toggleRail(_:)), keyEquivalent: "i")
        rail.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(withTitle: "Record Trail", action: #selector(AppDelegate.toggleTrailRecording(_:)), keyEquivalent: "")
        viewMenu.addItem(.separator())
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        let prev = viewMenu.addItem(withTitle: "Previous Page", action: #selector(AppDelegate.previousAnchor(_:)), keyEquivalent: up)
        prev.keyEquivalentModifierMask = [.command]
        let prevAlt = viewMenu.addItem(withTitle: "Previous Page", action: #selector(AppDelegate.previousAnchor(_:)), keyEquivalent: up)
        prevAlt.keyEquivalentModifierMask = [.option]
        prevAlt.isAlternate = true
        let next = viewMenu.addItem(withTitle: "Next Page", action: #selector(AppDelegate.nextAnchor(_:)), keyEquivalent: down)
        next.keyEquivalentModifierMask = [.command]
        let nextAlt = viewMenu.addItem(withTitle: "Next Page", action: #selector(AppDelegate.nextAnchor(_:)), keyEquivalent: down)
        nextAlt.keyEquivalentModifierMask = [.option]
        nextAlt.isAlternate = true
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu

        // Go
        let goItem = NSMenuItem(); main.addItem(goItem)
        let goMenu = NSMenu(title: "Go")
        goMenu.addItem(withTitle: "Open Quickly…", action: #selector(AppDelegate.showPalette(_:)), keyEquivalent: "k")
        goMenu.addItem(withTitle: "Search…", action: #selector(AppDelegate.showSearch(_:)), keyEquivalent: "f")
        goMenu.addItem(.separator())
        goMenu.addItem(withTitle: "Back", action: #selector(AppDelegate.goBack(_:)), keyEquivalent: "[")
        goMenu.addItem(withTitle: "Forward", action: #selector(AppDelegate.goForward(_:)), keyEquivalent: "]")
        goItem.submenu = goMenu

        // Window
        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
        refreshRecents()
    }

    static func refreshRecents() {
        guard let menu = recentMenu else { return }
        menu.removeAllItems()
        let recents = Defaults.recentVaults
        for path in recents {
            let url = URL(fileURLWithPath: path)
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(AppDelegate.openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.toolTip = url.path
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if !recents.isEmpty { menu.addItem(.separator()) }
        let clear = menu.addItem(withTitle: "Clear Menu", action: #selector(AppDelegate.clearRecents(_:)), keyEquivalent: "")
        clear.isEnabled = !recents.isEmpty
    }
}

extension AppDelegate: NSMenuItemValidation {
    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Flamingo",
            .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1",
        ])
    }

    @objc func openVault(_ sender: Any?) { state.openVaultDialog() }
    @objc func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { state.open(url) }
    }
    @objc func clearRecents(_ sender: Any?) {
        Defaults.recentVaults = []
        MainMenu.refreshRecents()
    }
    @objc func leaveThought(_ sender: Any?) { state.leaveThought() }
    @objc func toggleGlobalCapture(_ sender: Any?) { state.captureGlobal.toggle() }
    @objc func toggleTrailRecording(_ sender: Any?) { state.trailEnabled.toggle() }
    @objc func openExternally(_ sender: Any?) { state.openExternally() }
    @objc func revealInFinder(_ sender: Any?) { state.revealInFinder() }
    @objc func copyPath(_ sender: Any?) { state.copyPath() }
    @objc func reindex(_ sender: Any?) { state.reindex() }
    @objc func setMode(_ sender: NSMenuItem) {
        if let m = AppState.Mode(rawValue: sender.tag) { state.mode = m }
    }
    @objc func toggleRail(_ sender: Any?) { state.toggleRail() }
    @objc func previousAnchor(_ sender: Any?) { state.stepAnchor(-1) }
    @objc func nextAnchor(_ sender: Any?) { state.stepAnchor(1) }
    @objc func showPalette(_ sender: Any?) { state.showPalette(.commands) }
    @objc func showSearch(_ sender: Any?) { state.showPalette(.search) }
    @objc func goBack(_ sender: Any?) { state.goBack() }
    @objc func goForward(_ sender: Any?) { state.goForward() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasVault = state.vault != nil
        let hasFile = state.selected != nil
        switch item.action {
        case #selector(setMode(_:)):
            item.state = item.tag == state.mode.rawValue ? .on : .off
            return hasVault
        case #selector(toggleRail(_:)):
            item.state = state.railVisible ? .on : .off
            return true
        case #selector(toggleGlobalCapture(_:)):
            item.state = state.captureGlobal ? .on : .off
            return true
        case #selector(toggleTrailRecording(_:)):
            item.state = state.trailEnabled ? .on : .off
            return true
        case #selector(leaveThought(_:)):
            return hasVault
        case #selector(revealInFinder(_:)), #selector(copyPath(_:)):
            return hasFile
        case #selector(openExternally(_:)):
            item.title = "Open in " + (state.defaultAppName(for: state.selected) ?? "Default App")
            return hasFile
        case #selector(reindex(_:)):
            return hasVault && state.indexProgress == nil
        case #selector(previousAnchor(_:)), #selector(nextAnchor(_:)):
            let prev = item.action == #selector(previousAnchor(_:))
            let kind = state.navigator?.anchorKind ?? state.sections.first?.anchor.kind
            switch kind {
            case .time: item.title = prev ? "Back 10 Seconds" : "Forward 10 Seconds"
            case .slide: item.title = prev ? "Previous Slide" : "Next Slide"
            case .sheet: item.title = prev ? "Previous Sheet" : "Next Sheet"
            case .node, .region, .cell, .line: item.title = prev ? "Previous Section" : "Next Section"
            case .page, .none: item.title = prev ? "Previous Page" : "Next Page"
            }
            return hasFile && state.hasAnchors
        case #selector(showPalette(_:)):
            return true
        case #selector(showSearch(_:)):
            return hasVault
        case #selector(goBack(_:)):
            return state.canGoBack
        case #selector(goForward(_:)):
            return state.canGoForward
        default:
            return true
        }
    }
}
