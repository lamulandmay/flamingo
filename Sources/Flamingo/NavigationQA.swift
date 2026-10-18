import AppKit
import FlamingoCore

/// QA verbs for navigation, the file explorer's follow and swipes (QAHook, FLAMINGO_DEBUG only).
///
///     nav graph decks/q3.pptx       what a click on that node in the graph does
///     nav link q3-model.xlsx        a clicked [[wikilink]] in a thought or a note
///     nav browse decks/q3.pptx      a file opened from the columns or an icon tile
///     nav favorite /Applications    a Finder favorite (outside the vault)
///     nav recent decks/q3.pptx      the recent-files ring and Go → Recent Files
///     nav pane 2 decks/q3.pptx      a launcher's pick, opened in the pane in slot 2
///     nav reveal                    the explorer header's "reveal current file"
///     nav back | nav forward        ⌘[ ⌘]
///     nav status                    logs history: index, count, the current entry
///     sidebar status                logs the explorer's selected row and whether it shows
///     sidebar tab files|search|bookmarks, sidebar fold, sidebar unfold, sidebar idle, sidebar scroll 0
///     swipe sim back 0.3,0.7,1.05 ended    AppKit's side of a swipe: amounts with the fingers
///                                           down, then the lift (ended, cancelled, or hold)
///     swipe lift ended|cancelled           lifts a held one
///
/// Real gestures can be posted with build/qa-scroll (scripts/nav-qa.sh); those go through the
/// monitor, the decision and `trackSwipeEvent` itself.
@MainActor
enum NavigationQA {
    static func run(_ verb: String, _ rest: String) {
        guard let state = (NSApp.delegate as? AppDelegate)?.state else { return }
        let args = rest.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = args.count > 1 ? args[1] : ""
        switch (verb, args.first ?? "") {
        case ("nav", "graph"): state.select(FileRef(relativePath: arg), source: .graph)
        case ("nav", "link"): state.openLink(arg)
        case ("nav", "browse"):
            guard let root = state.vault?.root else { return }
            let url = root.appendingPathComponent(arg)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            state.openFromBrowser(url, isFolder: isDir.boolValue)
        case ("nav", "favorite"): state.openFavorite(URL(fileURLWithPath: arg))
        case ("nav", "recent"): state.reveal(FileRef(relativePath: arg))
        case ("nav", "pane"):
            let more = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard more.count == 2, let n = Int(more[0]), state.tiling.arrangement.visible.indices.contains(n - 1) else { return }
            state.open(FileRef(relativePath: more[1]), inPane: state.tiling.arrangement.visible[n - 1])
        case ("nav", "reveal"): state.revealCurrentFile()
        case ("nav", "back"): state.goBack()
        case ("nav", "forward"): state.goForward()
        case ("nav", "status"):
            let h = state.history
            Log.debug("qa: nav status index=\(h.index) count=\(h.entries.count) back=\(h.canGoBack) forward=\(h.canGoForward) file=\(h.current?.file?.relativePath ?? "-") selected=\(state.selected?.relativePath ?? "-")")
        case ("sidebar", "status"):
            Log.debug("qa: sidebar tab=\(state.sidebarTab.rawValue) folded=\(state.sidebarCollapsed) selected=\(state.selected?.relativePath ?? "-") \(FileExplorerQA.status?() ?? "unmounted")")
        case ("sidebar", "tab"): if let tab = SidebarTab(rawValue: arg) { state.sidebarTab = tab }
        case ("sidebar", "fold"): state.sidebarCollapsed = true
        case ("sidebar", "unfold"): state.sidebarCollapsed = false
        case ("sidebar", "idle"): FileExplorerQA.collapseIdle?()
        case ("sidebar", "scroll"): FileExplorerQA.scroll?(CGFloat(Double(arg) ?? 0))
        case ("swipe", "sim"):
            let more = arg.split(separator: " ").map(String.init)
            guard more.count >= 2 else { return }
            let amounts = more[1].split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
            let lift: SwipeGate.Phase? = more.count > 2 ? (more[2] == "ended" ? .ended : more[2] == "cancelled" ? .cancelled : nil) : .ended
            SwipeNavigator.shared?.qaSimulate(back: more[0] == "back", amounts: amounts, lift: lift)
        case ("swipe", "lift"): SwipeNavigator.shared?.qaLift(arg == "cancelled" ? .cancelled : .ended)
        default: Log.debug("qa: \(verb): unknown \(rest)")
        }
    }
}
