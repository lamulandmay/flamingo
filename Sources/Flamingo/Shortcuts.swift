import AppKit

/// Every key Flamingo answers to, for Help ▸ Keyboard Shortcuts (⌘/). The menu bar's own keys
/// are here too (a test holds the two together); the rest are the keys a view takes only
/// while it has focus: the graph, columns, the inbox, connect mode. Plain data, so the window
/// only draws it and the filter can be tested.
struct Shortcut: Hashable {
    /// Alternatives, each one chord or a short sequence: `["⌘K", "⌘F"]`, `["⌘K >"]`.
    var keys: [String]
    var action: String
}

struct ShortcutGroup: Hashable, Identifiable {
    var title: String
    /// Where these keys work, when that isn't everywhere.
    var context: String?
    var items: [Shortcut]
    /// Only shown while the filter is empty: a selection of keys listed again further down.
    var isPrimer = false

    var id: String { title }
}

enum ShortcutCatalog {
    static func groups(captureKeys: String = "⌃⌥Space") -> [ShortcutGroup] {
        [
            ShortcutGroup(title: "Start Here", context: "Ten keys that do most of the work", items: [
                Shortcut(keys: ["⌘K"], action: "Search everything: file names, folders, text inside files, thoughts"),
                Shortcut(keys: ["⌘K >"], action: "Run any command by name"),
                Shortcut(keys: ["⇧⌘C"], action: "Leave a thought on the page, slide or cell you're looking at"),
                Shortcut(keys: ["⌘1", "⌘2", "⌘3"], action: "Files, Graph, Trail"),
                Shortcut(keys: ["Hold ⌥⌘"], action: "Ring of recent files at the pointer: flick toward one, let go"),
                Shortcut(keys: ["⌘[", "⌘]"], action: "Back, forward (or swipe with two fingers)"),
                Shortcut(keys: ["⌘J"], action: "Connect files: click one, then another"),
                Shortcut(keys: ["⌘N"], action: "New file of any kind: type ppt, excel, 3d, py…"),
                Shortcut(keys: ["⌘\\"], action: "Two documents side by side"),
                Shortcut(keys: ["⌘/"], action: "This list"),
            ], isPrimer: true),

            ShortcutGroup(title: "Search", items: [
                Shortcut(keys: ["⌘K", "⌘F"], action: "Search file names, folders, contents and thoughts"),
                Shortcut(keys: [">"], action: "Typed first: commands instead of files"),
                Shortcut(keys: ["↑", "↓"], action: "Move through the results"),
                Shortcut(keys: ["↩"], action: "Open the highlighted result, or list everything found"),
                Shortcut(keys: ["⌘↩"], action: "Open the highlighted file in its own app"),
                Shortcut(keys: ["⌘↑", "⌘↓"], action: "First or last result"),
                Shortcut(keys: ["Esc"], action: "Close"),
                Shortcut(keys: ["⇧⌘F"], action: "Search in the sidebar: every match, grouped by file"),
                Shortcut(keys: ["⌃⌥F"], action: "Search from any app (turn on in Go ▸ Search from Any App)"),
                Shortcut(keys: ["⇧⌘J"], action: "Reveal the current file in the file explorer"),
            ]),

            ShortcutGroup(title: "Search Filters", context: "Typed in search, with or without other words", items: [
                Shortcut(keys: ["path:\"Research Lab\""], action: "Only inside that folder"),
                Shortcut(keys: ["type:pdf"], action: "pdf, deck, spreadsheet, document, image, video, audio, note, folder"),
                Shortcut(keys: ["ext:pptx,pdf"], action: "Any of these extensions"),
                Shortcut(keys: ["after:2026-10-01", "before:2026-11-01"], action: "Modified on or after, or before, a date"),
                Shortcut(keys: ["pdfs last week"], action: "Kinds and dates in plain words: today, yesterday, this week…"),
            ]),

            ShortcutGroup(title: "Search Results List", context: "After ↩ in search", items: [
                Shortcut(keys: ["↩", "⌘↓", "⌘O"], action: "Open in Flamingo"),
                Shortcut(keys: ["⌘↩"], action: "Open in its own app"),
                Shortcut(keys: ["Space", "⌘Y"], action: "Quick Look"),
                Shortcut(keys: ["⌘C"], action: "Copy the file"),
                Shortcut(keys: ["⌘⌫"], action: "Move to Trash"),
                Shortcut(keys: ["↑"], action: "From the top row: back to the search field"),
                Shortcut(keys: ["Esc"], action: "Back to where you were"),
            ]),

            ShortcutGroup(title: "Files", items: [
                Shortcut(keys: ["⌘O"], action: "Open a folder as a vault"),
                Shortcut(keys: ["⌘N"], action: "New file of any kind in the folder on screen"),
                Shortcut(keys: ["⌥⌘N"], action: "New note, named in place"),
                Shortcut(keys: ["⇧⌘N"], action: "New folder, named in place"),
                Shortcut(keys: ["⌘S"], action: "Save the built-in text editor"),
                Shortcut(keys: ["↩"], action: "Rename the current file, when nothing else has the keyboard"),
                Shortcut(keys: ["⌘D"], action: "Bookmark the current file, or remove its bookmark"),
                Shortcut(keys: ["⌘↩"], action: "Open the current file in its own app"),
                Shortcut(keys: ["⇧⌘R"], action: "Reveal in Finder"),
                Shortcut(keys: ["⌘Z"], action: "Undo: files, moves, bookmarks, thoughts, graph edits, saves"),
                Shortcut(keys: ["⇧⌘Z"], action: "Redo"),
                Shortcut(keys: ["⌘X", "⌘C", "⌘V", "⌘A"], action: "Cut, copy, paste, select all"),
                Shortcut(keys: ["⌘W"], action: "Close the tab, or the focused pane in split view"),
                Shortcut(keys: ["⇧⌘W"], action: "Hide the window (only ⌘Q quits)"),
                Shortcut(keys: ["⌘,"], action: "Settings"),
                Shortcut(keys: ["⌘/"], action: "Keyboard shortcuts: this list"),
            ]),

            ShortcutGroup(title: "Writing", context: "In a Markdown note", items: [
                Shortcut(keys: ["⌘B"], action: "Bold: the selection, the word at the caret, or what you type next"),
                Shortcut(keys: ["⌘I"], action: "Italic"),
                Shortcut(keys: ["⌘U"], action: "Underline"),
                Shortcut(keys: ["- Space", "1. Space", "- [ ] Space"], action: "Start a bulleted, numbered or checkbox list"),
                Shortcut(keys: ["↩"], action: "Next list item; on an empty item, end the list"),
                Shortcut(keys: ["Tab", "⇧Tab"], action: "Nest a list item, or bring it back out"),
                Shortcut(keys: ["⌫"], action: "Right after a bullet or checkbox: remove it"),
            ]),

            ShortcutGroup(title: "New File", context: "In the ⌘N sheet", items: [
                Shortcut(keys: ["ppt", "excel", "3d", "py"], action: "Type a kind: an extension or a word for it"),
                Shortcut(keys: ["↑", "↓", "Tab"], action: "Move through the kinds"),
                Shortcut(keys: ["↩"], action: "Pick the kind, then name it (empty means Untitled)"),
                Shortcut(keys: ["plan.pptx"], action: "Kind and name at once"),
                Shortcut(keys: ["⌫"], action: "In an empty name: back to the kinds"),
                Shortcut(keys: ["Esc"], action: "Close"),
            ]),

            ShortcutGroup(title: "File Explorer and Bookmarks", context: "In the left sidebar", items: [
                Shortcut(keys: ["⌃⌘S"], action: "Show or hide the left sidebar (the ribbon stays)"),
                Shortcut(keys: ["↩"], action: "Rename (a bookmark opens)"),
                Shortcut(keys: ["⌘⌫"], action: "Move to Trash (undo within 10 seconds)"),
                Shortcut(keys: ["⌫"], action: "Remove the bookmark"),
                Shortcut(keys: ["⌘C", "⌘V"], action: "Copy, paste files"),
                Shortcut(keys: ["⌥⌘V"], action: "Move the copied files here"),
                Shortcut(keys: ["⌘Y"], action: "Quick Look"),
                Shortcut(keys: ["Space", "Esc"], action: "Clear the selection"),
            ]),

            ShortcutGroup(title: "Folders and Columns", context: "With no file open, or after ⌥⌘3", items: [
                Shortcut(keys: ["⌥⌘1"], action: "This folder as icons"),
                Shortcut(keys: ["⌥⌘3"], action: "This folder as Finder columns, with the open file selected"),
                Shortcut(keys: ["←", "→"], action: "Walk the columns"),
                Shortcut(keys: ["↑", "↓"], action: "Move in a column; type a name to jump to it"),
                Shortcut(keys: ["Space", "⌘Y"], action: "Quick Look"),
                Shortcut(keys: ["⌘↓", "⌘O"], action: "Open"),
                Shortcut(keys: ["⌘↩"], action: "Open in its own app"),
                Shortcut(keys: ["⌘↑"], action: "Enclosing folder"),
                Shortcut(keys: ["↩"], action: "Rename"),
                Shortcut(keys: ["⌘⌫"], action: "Move to Trash"),
                Shortcut(keys: ["⌘C", "⌘V", "⌥⌘V"], action: "Copy, paste, move here"),
                Shortcut(keys: ["⇧⌘."], action: "Show or hide hidden files"),
            ]),

            ShortcutGroup(title: "Go", items: [
                Shortcut(keys: ["⌘["], action: "Back"),
                Shortcut(keys: ["⌘]"], action: "Forward"),
                Shortcut(keys: ["Two-finger swipe"], action: "Back or forward"),
                Shortcut(keys: ["Hold ⌥⌘"], action: "Recent files ring: move toward one, let go to open, Esc cancels"),
                Shortcut(keys: ["⌘↑", "⌥↑"], action: "Previous page, slide, sheet or section (video: back 10 seconds)"),
                Shortcut(keys: ["⌘↓", "⌥↓"], action: "Next page, slide, sheet or section (video: forward 10 seconds)"),
                Shortcut(keys: ["⇧⌘D"], action: "Desktop"),
                Shortcut(keys: ["⇧⌘O"], action: "Documents"),
                Shortcut(keys: ["⌥⌘L"], action: "Downloads"),
                Shortcut(keys: ["⇧⌘H"], action: "Home"),
                Shortcut(keys: ["⇧⌘A"], action: "Applications"),
            ]),

            ShortcutGroup(title: "Views and Panes", items: [
                Shortcut(keys: ["⌘1"], action: "Files"),
                Shortcut(keys: ["⌘2"], action: "Graph"),
                Shortcut(keys: ["⌘3"], action: "Trail"),
                Shortcut(keys: ["⌘4"], action: "Chat, in the inspector"),
                Shortcut(keys: ["⌘0"], action: "Inbox: today's briefing"),
                Shortcut(keys: ["⌘J"], action: "Connect files"),
                Shortcut(keys: ["⌥⌘I"], action: "Show or hide the inspector"),
                Shortcut(keys: ["⌃⌘1"], action: "Inspector: Thoughts"),
                Shortcut(keys: ["⌃⌘2"], action: "Inspector: Connections"),
                Shortcut(keys: ["⌃⌘3"], action: "Inspector: Outline"),
                Shortcut(keys: ["⌘\\"], action: "Open or close split view"),
                Shortcut(keys: ["⌥⌘→"], action: "Focus the next pane"),
                Shortcut(keys: ["⌥⌘←"], action: "Focus the previous pane"),
                Shortcut(keys: ["⌃⌥⌘1"], action: "Layout: Single"),
                Shortcut(keys: ["⌃⌥⌘2"], action: "Layout: Two Side by Side"),
                Shortcut(keys: ["⌃⌥⌘3"], action: "Layout: Three Columns"),
                Shortcut(keys: ["⌃⌥⌘4"], action: "Layout: One and Two"),
                Shortcut(keys: ["⌃⌥⌘5"], action: "Layout: Four"),
                Shortcut(keys: ["← → ↩"], action: "In the layout picker: choose, apply"),
                Shortcut(keys: ["⌃⌘F"], action: "Full screen"),
                Shortcut(keys: ["⌘M"], action: "Minimize"),
                Shortcut(keys: ["⌘H"], action: "Hide Flamingo"),
                Shortcut(keys: ["⌥⌘H"], action: "Hide other apps"),
                Shortcut(keys: ["⌘Q"], action: "Quit"),
            ]),

            ShortcutGroup(title: "Graph", context: "In ⌘2, once you've clicked the graph", items: [
                Shortcut(keys: ["←", "→", "↑", "↓"], action: "Walk to the nearest file that way"),
                Shortcut(keys: ["↩"], action: "Open the selected file"),
                Shortcut(keys: ["Type a name"], action: "Filter: ↑ ↓ walk the matches, ↩ opens the best"),
                Shortcut(keys: ["Space", "Esc"], action: "Clear the selection"),
                Shortcut(keys: ["Click", "⌘-click"], action: "Select, add to the selection"),
                Shortcut(keys: ["Double-click"], action: "Open a file; on empty space, fit everything"),
                Shortcut(keys: ["⌥-drag"], action: "From one file onto another: connect them"),
                Shortcut(keys: ["Drag"], action: "A file moves it, the background pans"),
                Shortcut(keys: ["Pinch", "⌘-scroll"], action: "Zoom"),
                Shortcut(keys: ["⌘=", "⌘-"], action: "Zoom in, out"),
                Shortcut(keys: ["⌘0", "Two-finger double-tap"], action: "Fit everything"),
            ]),

            ShortcutGroup(title: "Connect Mode", context: "After ⌘J", items: [
                Shortcut(keys: ["Click", "Click"], action: "One file, then another: connected. Keep clicking to add more"),
                Shortcut(keys: ["Click a picked file"], action: "Take it back out"),
                Shortcut(keys: ["↩", "Click empty space"], action: "Start the next connection"),
                Shortcut(keys: ["Type a name"], action: "Find any file; ↩ picks the top match"),
                Shortcut(keys: ["Esc"], action: "Leave"),
            ]),

            ShortcutGroup(title: "Thoughts", items: [
                Shortcut(keys: ["⇧⌘C"], action: "Leave a thought on the current file, at the page you're on"),
                Shortcut(keys: [captureKeys], action: "Leave a thought from any app (Settings ▸ Capture, needs Accessibility)"),
                Shortcut(keys: ["[["], action: "Link a file: ↑ ↓ and ↩ pick from the list"),
                Shortcut(keys: ["↩"], action: "Keep the thought"),
                Shortcut(keys: ["⇧↩", "⌥↩"], action: "New line"),
                Shortcut(keys: ["@ai"], action: "Ask the on-device model about it; nothing leaves your Mac"),
                Shortcut(keys: ["by friday", "tomorrow"], action: "Words like these set a due date"),
                Shortcut(keys: ["Esc"], action: "Close"),
            ]),

            ShortcutGroup(title: "Thoughts Tab", context: "In the inspector, ⌃⌘1", items: [
                Shortcut(keys: ["↑", "↓"], action: "Select a thought"),
                Shortcut(keys: ["↩"], action: "Edit it"),
                Shortcut(keys: ["R"], action: "Reply"),
                Shortcut(keys: ["E"], action: "Mark done, or open again"),
                Shortcut(keys: ["S"], action: "Snooze"),
                Shortcut(keys: ["⌫"], action: "Delete"),
                Shortcut(keys: ["Esc"], action: "Clear the selection"),
            ]),

            ShortcutGroup(title: "Inbox", context: "In ⌘0", items: [
                Shortcut(keys: ["J", "K", "↑", "↓"], action: "Next, previous"),
                Shortcut(keys: ["↩"], action: "Open"),
                Shortcut(keys: ["E"], action: "Done"),
                Shortcut(keys: ["S"], action: "Snooze"),
                Shortcut(keys: ["R"], action: "Reply"),
                Shortcut(keys: ["A"], action: "Attach to a file"),
                Shortcut(keys: ["⌫"], action: "Dismiss"),
                Shortcut(keys: ["Esc"], action: "Cancel a reply, or close the inbox"),
            ]),

            ShortcutGroup(title: "Trail", context: "In ⌘3", items: [
                Shortcut(keys: ["↑", "↓"], action: "Select a session"),
                Shortcut(keys: ["→", "←", "Space"], action: "Expand, collapse, toggle"),
                Shortcut(keys: ["↩"], action: "Name the session"),
                Shortcut(keys: ["⌘R"], action: "Resume it: reopen its files where you left them"),
                Shortcut(keys: ["Esc"], action: "Clear the selection"),
            ]),

            ShortcutGroup(title: "Wander", context: "View ▸ Wander Suggestions", items: [
                Shortcut(keys: ["→"], action: "Connect the pair"),
                Shortcut(keys: ["←"], action: "Not related"),
                Shortcut(keys: ["↓", "Space"], action: "Skip"),
                Shortcut(keys: ["↩"], action: "Open them"),
                Shortcut(keys: ["Esc"], action: "Stop"),
            ]),

            ShortcutGroup(title: "Chat", context: "In ⌘4", items: [
                Shortcut(keys: ["↑"], action: "In an empty field: your last question"),
                Shortcut(keys: ["↓"], action: "A newer question"),
                Shortcut(keys: ["Esc"], action: "Stop the answer"),
            ]),
        ]
    }

    /// The groups and rows whose action, keys or group match every word of `query`. A group
    /// whose title matches keeps all its rows. Words for keys match their symbols: `cmd` ⌘,
    /// `opt` ⌥, `shift` ⇧, `ctrl` ⌃, `return` ↩, `delete` ⌫. The primer drops out while filtering.
    static func filter(_ groups: [ShortcutGroup], _ query: String) -> [ShortcutGroup] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return groups }
        return groups.compactMap { group in
            guard !group.isPrimer else { return nil }
            let heading = [group.title, group.context ?? ""].joined(separator: " ").lowercased()
            let items = group.items.filter { item in
                let haystack = ([heading, item.action] + item.keys).joined(separator: " ").lowercased()
                return words.allSatisfy { word in
                    haystack.contains(word) || keySymbols(word).map { haystack.contains($0) } == true
                }
            }
            return items.isEmpty ? nil : ShortcutGroup(title: group.title, context: group.context, items: items)
        }
    }

    private static func keySymbols(_ word: String) -> String? {
        switch word {
        case "cmd", "command": "⌘"
        case "opt", "option", "alt": "⌥"
        case "shift": "⇧"
        case "ctrl", "control": "⌃"
        case "return", "enter": "↩"
        case "delete", "backspace": "⌫"
        case "up": "↑"
        case "down": "↓"
        case "left": "←"
        case "right": "→"
        default: nil
        }
    }

    /// A menu item's key as the catalog writes it: modifiers in Apple's order (⌃⌥⇧⌘), then the
    /// key. Nil when the item has none.
    static func symbols(of item: NSMenuItem) -> String? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        let m = item.keyEquivalentModifierMask
        var s = ""
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        switch item.keyEquivalent.unicodeScalars.first.map({ Int($0.value) }) {
        case NSUpArrowFunctionKey: s += "↑"
        case NSDownArrowFunctionKey: s += "↓"
        case NSLeftArrowFunctionKey: s += "←"
        case NSRightArrowFunctionKey: s += "→"
        case 0x0D: s += "↩"
        default: s += item.keyEquivalent.uppercased()
        }
        return s
    }
}
