import Foundation
import FlamingoCore

/// Back/forward over (file, anchor) selections. ⌘[ ⌘]. Plan 01 owns.
struct History {
    struct Entry: Equatable {
        var file: FileRef
        var anchor: FileAnchor?
        /// When it was pushed and whether it came from scrubbing the sidebar, so a run of
        /// arrow-key hops collapses into the file the user rested on.
        var pushedAt = Date()
        var transient = false
    }

    /// Sidebar hops closer together than this replace the previous hop instead of stacking.
    static let coalesceWindow: TimeInterval = 0.7

    private(set) var entries: [Entry] = []
    private(set) var index: Int = -1
    private let cap = 200

    var current: Entry? { entries.indices.contains(index) ? entries[index] : nil }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < entries.count - 1 }

    /// Records a new place. Drops any forward entries. Consecutive duplicates collapse, and a
    /// transient entry that was pushed moments ago is replaced rather than kept.
    mutating func push(_ entry: Entry) {
        if let c = current, c.file == entry.file {
            entries[index].anchor = entry.anchor ?? c.anchor
            entries[index].transient = false
            return
        }
        if index < entries.count - 1 { entries.removeSubrange((index + 1)...) }
        if entry.transient, let c = current, c.transient, index > 0,
           entry.pushedAt.timeIntervalSince(c.pushedAt) < History.coalesceWindow {
            entries[index] = entry
            return
        }
        entries.append(entry)
        if entries.count > cap { entries.removeFirst(entries.count - cap) }
        index = entries.count - 1
    }

    /// Keeps the current entry's anchor fresh without creating a new entry. A nil only
    /// happens while the selection is changing, so it never erases what was there.
    mutating func updateAnchor(_ anchor: FileAnchor?) {
        guard let anchor, entries.indices.contains(index) else { return }
        entries[index].anchor = anchor
    }

    mutating func goBack() -> Entry? {
        guard canGoBack else { return nil }
        index -= 1
        return entries[index]
    }

    mutating func goForward() -> Entry? {
        guard canGoForward else { return nil }
        index += 1
        return entries[index]
    }

    /// Drops entries whose file no longer exists.
    mutating func prune(keeping files: Set<FileRef>) {
        let cur = current
        entries.removeAll { !files.contains($0.file) }
        if let cur, let i = entries.firstIndex(of: cur) { index = i } else { index = entries.count - 1 }
    }

    /// Replaces the whole history, e.g. when resuming a trail session.
    mutating func replace(with files: [FileRef]) {
        entries = files.map { Entry(file: $0, anchor: nil) }
        index = entries.count - 1
    }
}
