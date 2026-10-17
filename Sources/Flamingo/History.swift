import Foundation
import FlamingoCore

/// Back/forward over places: a file (with anchor), the mode it was seen in, and the sidebar
/// folder. ⌘[ ⌘] and two-finger swipes. Plan 01 owns.
struct History {
    struct Entry: Equatable {
        var file: FileRef?
        var anchor: FileAnchor?
        var mode: AppState.Mode = .files
        var folder: String?
        /// A folder outside the vault the folder surface showed (a Finder favorite such as
        /// /Applications), when that is where the user was.
        var place: URL?
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
        if let c = current, c.file == entry.file, c.mode == entry.mode, c.folder == entry.folder, c.place == entry.place {
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
        entries.removeAll { $0.file.map { !files.contains($0) } ?? false }
        if let cur, let i = entries.firstIndex(of: cur) { index = i } else { index = entries.count - 1 }
    }

    /// Replaces the whole history, e.g. when resuming a trail session.
    mutating func replace(with files: [FileRef]) {
        entries = files.map { Entry(file: $0, anchor: nil) }
        index = entries.count - 1
    }

    mutating func restore(entries: [Entry], index: Int) {
        self.entries = Array(entries.suffix(cap))
        self.index = min(max(-1, index - max(0, entries.count - cap)), self.entries.count - 1)
    }

    mutating func relocate(_ old: String, to new: String) {
        for i in entries.indices {
            if let path = entries[i].file?.relativePath, path == old || path.hasPrefix(old + "/") {
                entries[i].file = FileRef(relativePath: new + path.dropFirst(old.count))
            }
            if let path = entries[i].folder, path == old || path.hasPrefix(old + "/") {
                entries[i].folder = new + path.dropFirst(old.count)
            }
        }
    }

    mutating func remove(_ path: String) {
        let cur = current
        func contains(_ candidate: String) -> Bool { candidate == path || candidate.hasPrefix(path + "/") }
        entries.removeAll { entry in
            entry.file.map { contains($0.relativePath) }
                ?? entry.folder.map { contains($0) } ?? false
        }
        index = cur.flatMap { entries.firstIndex(of: $0) } ?? (entries.count - 1)
    }
}
