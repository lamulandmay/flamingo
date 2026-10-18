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
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
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
        fileMenu.addItem(withTitle: "New File…", action: #selector(AppDelegate.newFile(_:)), keyEquivalent: "n")
        let newNote = fileMenu.addItem(withTitle: "New Note", action: #selector(AppDelegate.newNote(_:)), keyEquivalent: "n")
        newNote.keyEquivalentModifierMask = [.command, .option]
        fileMenu.addItem(withTitle: "Save", action: #selector(AppDelegate.saveDocument(_:)), keyEquivalent: "s")
        let newFolder = fileMenu.addItem(withTitle: "New Folder", action: #selector(AppDelegate.newFolder(_:)), keyEquivalent: "n")
        newFolder.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "Bookmark", action: #selector(AppDelegate.toggleBookmark(_:)), keyEquivalent: "d")
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
        fileMenu.addItem(withTitle: "Copy File", action: #selector(AppDelegate.copyFile(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Reindex Vault", action: #selector(AppDelegate.reindex(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(AppDelegate.closeDocument(_:)), keyEquivalent: "w")
        let closeWindow = fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        fileItem.submenu = fileMenu

        // Edit
        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: #selector(AppDelegate.performUndo(_:)), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: #selector(AppDelegate.performRedo(_:)), keyEquivalent: "z")
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
        let inbox = viewMenu.addItem(withTitle: "Inbox", action: #selector(AppDelegate.showInbox(_:)), keyEquivalent: "0")
        inbox.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(.separator())
        for (i, style) in FolderStyle.allCases.enumerated() {
            let item = viewMenu.addItem(withTitle: style.title, action: #selector(AppDelegate.setFolderStyle(_:)), keyEquivalent: style.key)
            item.keyEquivalentModifierMask = [.command, .option]
            item.tag = i
        }
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Connect Files", action: #selector(AppDelegate.toggleConnectGrid(_:)), keyEquivalent: "j")
        viewMenu.addItem(.separator())
        let sidebar = viewMenu.addItem(withTitle: "Left Sidebar", action: #selector(AppDelegate.toggleSidebar(_:)), keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        for (i, tab) in SidebarTab.allCases.enumerated() {
            let item = viewMenu.addItem(withTitle: tab.title, action: #selector(AppDelegate.showSidebarTab(_:)), keyEquivalent: "")
            item.tag = i
            item.indentationLevel = 1
        }
        let split = viewMenu.addItem(withTitle: "Split View", action: #selector(AppDelegate.toggleSplit(_:)), keyEquivalent: "\\")
        split.keyEquivalentModifierMask = [.command]
        let layoutItem = viewMenu.addItem(withTitle: "Layout", action: nil, keyEquivalent: "")
        let layoutMenu = NSMenu(title: "Layout")
        for (i, layout) in TileLayout.allCases.enumerated() {
            let item = layoutMenu.addItem(withTitle: layout.title, action: #selector(AppDelegate.setTileLayout(_:)), keyEquivalent: layout.key)
            item.keyEquivalentModifierMask = [.control, .option, .command]
            item.tag = i
        }
        layoutItem.submenu = layoutMenu
        let focusPane = viewMenu.addItem(withTitle: "Focus Next Pane", action: #selector(AppDelegate.focusOtherPane(_:)), keyEquivalent: String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)))
        focusPane.keyEquivalentModifierMask = [.command, .option]
        let focusPrevious = viewMenu.addItem(withTitle: "Focus Previous Pane", action: #selector(AppDelegate.focusPreviousPane(_:)), keyEquivalent: String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        focusPrevious.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(withTitle: "Open Current File Beside", action: #selector(AppDelegate.openCurrentBeside(_:)), keyEquivalent: "")
        let rail = viewMenu.addItem(withTitle: "Inspector", action: #selector(AppDelegate.toggleRail(_:)), keyEquivalent: "i")
        rail.keyEquivalentModifierMask = [.command, .option]
        for (i, tab) in InspectorTab.allCases.enumerated() where tab != .chat {
            let item = viewMenu.addItem(withTitle: tab.title, action: #selector(AppDelegate.showInspectorTab(_:)), keyEquivalent: String(i + 1))
            item.keyEquivalentModifierMask = [.command, .control]
            item.tag = i
            item.indentationLevel = 1
        }
        viewMenu.addItem(withTitle: "Wander Suggestions", action: #selector(AppDelegate.startWander(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Replay Graph History", action: #selector(AppDelegate.replayGraph(_:)), keyEquivalent: "")
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
        let globalSearch = goMenu.addItem(withTitle: "Search from Any App", action: #selector(AppDelegate.toggleGlobalSearch(_:)), keyEquivalent: "")
        globalSearch.toolTip = "Show search with Control-Option-F"
        let searchAll = goMenu.addItem(withTitle: "Search in All Files", action: #selector(AppDelegate.searchInSidebar(_:)), keyEquivalent: "f")
        searchAll.keyEquivalentModifierMask = [.command, .shift]
        // ⌘⇧J, as Xcode's Reveal in Project Navigator.
        let revealInExplorer = goMenu.addItem(withTitle: "Reveal in File Explorer", action: #selector(AppDelegate.revealInExplorer(_:)), keyEquivalent: "j")
        revealInExplorer.keyEquivalentModifierMask = [.command, .shift]
        goMenu.addItem(withTitle: "Random File", action: #selector(AppDelegate.openRandomFile(_:)), keyEquivalent: "")
        let recentFiles = NSMenuItem(title: RecentFilesMenu.title, action: nil, keyEquivalent: "")
        recentFiles.submenu = NSMenu(title: RecentFilesMenu.title)   // filled when opened (RecentFilesMenu)
        goMenu.addItem(recentFiles)
        goMenu.addItem(.separator())
        goMenu.addItem(withTitle: "Back", action: #selector(AppDelegate.goBack(_:)), keyEquivalent: "[")
        goMenu.addItem(withTitle: "Forward", action: #selector(AppDelegate.goForward(_:)), keyEquivalent: "]")
        goMenu.addItem(.separator())
        // Finder's Go menu, with Finder's keys.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let places: [(String, URL, String, NSEvent.ModifierFlags)] = [
            ("Desktop", home.appendingPathComponent("Desktop"), "d", [.command, .shift]),
            ("Documents", home.appendingPathComponent("Documents"), "o", [.command, .shift]),
            ("Downloads", home.appendingPathComponent("Downloads"), "l", [.command, .option]),
            ("Home", home, "h", [.command, .shift]),
            ("Applications", URL(fileURLWithPath: "/Applications"), "a", [.command, .shift]),
        ]
        for (title, url, key, modifiers) in places {
            let item = goMenu.addItem(withTitle: title, action: #selector(AppDelegate.goToPlace(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.representedObject = url
        }
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
        let recents = Defaults.recentVaultTitles()
        for (path, title) in recents {
            let url = URL(fileURLWithPath: path)
            let item = NSMenuItem(title: title, action: #selector(AppDelegate.openRecent(_:)), keyEquivalent: "")
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

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.show(state: state) }
    @objc func openVault(_ sender: Any?) { state.openVaultDialog() }
    @objc func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { state.open(url) }
    }
    @objc func clearRecents(_ sender: Any?) {
        Defaults.recentVaults = []
        MainMenu.refreshRecents()
    }
    @objc func performUndo(_ sender: Any?) { undoRouting?.perform(.undo) }
    @objc func performRedo(_ sender: Any?) { undoRouting?.perform(.redo) }
    @objc func leaveThought(_ sender: Any?) { state.leaveThought() }
    @objc func toggleGlobalCapture(_ sender: Any?) { state.captureGlobal.toggle() }
    @objc func toggleTrailRecording(_ sender: Any?) { state.trailEnabled.toggle() }
    @objc func openExternally(_ sender: Any?) { state.openExternally() }
    @objc func revealInFinder(_ sender: Any?) { state.revealInFinder() }
    @objc func copyPath(_ sender: Any?) { state.copyPath() }
    @objc func copyFile(_ sender: Any?) { state.copyFiles() }
    @objc func toggleGlobalSearch(_ sender: Any?) {
        if globalSearchShortcut?.toggle() == false {
            state.showToast(ToastMessage(text: "Control-Option-F is already used by macOS or another app."))
        }
    }
    @objc func reindex(_ sender: Any?) { state.reindex(force: true) }
    @objc func setMode(_ sender: NSMenuItem) {
        guard let m = AppState.Mode(rawValue: sender.tag) else { return }
        // The morning inbox leaves first: ⌘1 puts everything back, ⌘2 and ⌘3 then switch.
        if state.briefing.isPresented { state.briefing.close(thenMode: m == .files ? nil : m); return }
        state.mode = m
    }
    @objc func showInbox(_ sender: Any?) { state.showBriefing() }
    @objc func setFolderStyle(_ sender: NSMenuItem) { state.showFolderStyle(FolderStyle.allCases[sender.tag]) }
    @objc func goToPlace(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { state.openFavorite(url) } }
    @objc func toggleRail(_ sender: Any?) { state.toggleRail() }
    @objc func showInspectorTab(_ sender: NSMenuItem) { state.showInspector(InspectorTab.allCases[sender.tag]) }
    @objc func startWander(_ sender: Any?) { state.startWander() }
    @objc func toggleConnectGrid(_ sender: Any?) { state.connectGridShown.toggle() }
    @objc func replayGraph(_ sender: Any?) { state.replayGraph() }
    @objc func toggleSplit(_ sender: Any?) { state.toggleSplit() }
    @objc func focusOtherPane(_ sender: Any?) { state.focusPane(step: 1) }
    @objc func focusPreviousPane(_ sender: Any?) { state.focusPane(step: -1) }
    @objc func setTileLayout(_ sender: NSMenuItem) { state.setLayout(TileLayout.allCases[sender.tag]) }
    @objc func openCurrentBeside(_ sender: Any?) { if let file = state.selected { state.openBeside(file, anchor: state.anchor) } }
    @objc func previousAnchor(_ sender: Any?) { state.stepAnchor(-1) }
    @objc func nextAnchor(_ sender: Any?) { state.stepAnchor(1) }
    @objc func showPalette(_ sender: Any?) { state.showPalette(.commands) }
    @objc func showSearch(_ sender: Any?) { state.showPalette(.search) }
    @objc func newNote(_ sender: Any?) { state.newNote() }
    @objc func newFile(_ sender: Any?) { state.showNewFile() }
    @objc func saveDocument(_ sender: Any?) { state.saveDocument() }
    /// ⌘W closes one thing: the panel or sheet that has focus, else one tab (or the focused
    /// pane in split view). It never closes the main window, so it can't quit Flamingo.
    @objc func closeDocument(_ sender: Any?) {
        if let key = NSApp.keyWindow, key !== window { key.performClose(sender); return }
        if state.canCloseDocument { state.closeCurrentDocument() } else { NSSound.beep() }
    }
    @objc func newFolder(_ sender: Any?) { state.newFolder() }
    @objc func toggleBookmark(_ sender: Any?) { state.toggleBookmarkCurrent() }
    @objc func toggleSidebar(_ sender: Any?) { state.toggleSidebar() }
    @objc func showSidebarTab(_ sender: NSMenuItem) { state.showSidebarTab(SidebarTab.allCases[sender.tag]) }
    @objc func searchInSidebar(_ sender: Any?) { state.showSidebarSearch() }
    @objc func revealInExplorer(_ sender: Any?) { state.revealCurrentFile() }
    @objc func openRandomFile(_ sender: Any?) { state.openRandomFile() }
    @objc func goBack(_ sender: Any?) { state.goBack() }
    @objc func goForward(_ sender: Any?) { state.goForward() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasVault = state.vault != nil
        let hasFile = state.selected != nil
        switch item.action {
        case #selector(performUndo(_:)), #selector(performRedo(_:)):
            let direction: UndoRouting.Direction = item.action == #selector(performUndo(_:)) ? .undo : .redo
            let status = undoRouting?.menu(direction)
            item.title = status?.title ?? (direction == .undo ? "Undo" : "Redo")
            return status?.enabled == true
        case #selector(showInbox(_:)):
            item.state = state.briefing.isPresented ? .on : .off
            return hasVault
        case #selector(setMode(_:)):
            let chat = item.tag == AppState.Mode.ask.rawValue
            item.state = chat ? (state.railShown && state.inspectorTab == .chat ? .on : .off) : (item.tag == state.mode.rawValue ? .on : .off)
            return hasVault
        case #selector(goToPlace(_:)):
            return hasVault
        case #selector(setFolderStyle(_:)):
            item.state = FolderStyle.allCases[item.tag] == state.browser.style ? .on : .off
            return hasVault
        case #selector(toggleRail(_:)):
            item.state = state.railShown ? .on : .off
            return true
        case #selector(showInspectorTab(_:)):
            item.state = state.railShown && InspectorTab.allCases[item.tag] == state.inspectorTab ? .on : .off
            return hasVault
        case #selector(toggleConnectGrid(_:)):
            item.state = state.connectGridShown ? .on : .off
            return state.vault != nil
        case #selector(startWander(_:)), #selector(replayGraph(_:)):
            return hasVault
        case #selector(toggleSplit(_:)):
            item.state = state.splitVisible ? .on : .off
            return hasFile || state.splitVisible
        case #selector(focusOtherPane(_:)), #selector(focusPreviousPane(_:)):
            return state.splitVisible
        case #selector(setTileLayout(_:)):
            item.state = TileLayout.allCases[item.tag] == state.tiling.arrangement.kind ? .on : .off
            return hasVault
        case #selector(openCurrentBeside(_:)):
            return hasFile
        case #selector(toggleGlobalCapture(_:)):
            item.state = state.captureGlobal ? .on : .off
            return true
        case #selector(toggleGlobalSearch(_:)):
            item.state = globalSearchShortcut?.isEnabled == true ? .on : .off
            return true
        case #selector(toggleTrailRecording(_:)):
            item.state = state.trailEnabled ? .on : .off
            return true
        case #selector(leaveThought(_:)), #selector(newNote(_:)), #selector(newFile(_:)), #selector(newFolder(_:)), #selector(searchInSidebar(_:)):
            return hasVault
        case #selector(saveDocument(_:)):
            return state.selected.flatMap { state.textBuffers[$0.relativePath] }?.dirty == true
        case #selector(closeDocument(_:)):
            if let key = NSApp.keyWindow, key !== window { item.title = "Close"; return true }
            item.title = state.splitVisible ? "Close Pane" : "Close Tab"
            // Always enabled, so ⌘W with nothing to close beeps instead of reaching the window.
            return true
        case #selector(toggleBookmark(_:)):
            item.title = state.selected.map { state.isBookmarked($0.relativePath, folder: false) } == true ? "Remove Bookmark" : "Bookmark"
            return hasFile || !(state.selectedFolder ?? "").isEmpty
        case #selector(toggleSidebar(_:)):
            item.state = state.sidebarCollapsed ? .off : .on
            return true
        case #selector(showSidebarTab(_:)):
            item.state = !state.sidebarCollapsed && SidebarTab.allCases[item.tag] == state.sidebarTab ? .on : .off
            return hasVault
        case #selector(revealInExplorer(_:)):
            return hasFile
        case #selector(openRandomFile(_:)):
            return !state.files.isEmpty
        case #selector(revealInFinder(_:)), #selector(copyPath(_:)):
            return hasFile
        case #selector(copyFile(_:)):
            item.title = hasFile ? "Copy File" : "Copy Folder"
            return hasFile || state.selectedFolder != nil
        case #selector(openExternally(_:)):
            item.title = "Open in " + (state.defaultAppName(for: state.selected) ?? "Default App")
            return hasFile
        case #selector(reindex(_:)):
            return hasVault && state.indexStatus == nil
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
