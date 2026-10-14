import Foundation
import FlamingoCore

/// Back/forward over (file, anchor) selections. ⌘[ ⌘]. Plan 01 owns.
struct History {
    struct Entry: Equatable {
        var file: FileRef
        var anchor: FileAnchor?
    }

    private(set) var entries: [Entry] = []
    private(set) var index: Int = -1
    private let cap = 200

    var current: Entry? { entries.indices.contains(index) ? entries[index] : nil }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < entries.count - 1 }

    /// Records a new place. Drops any forward entries. Consecutive duplicates collapse.
    mutating func push(_ entry: Entry) {
        if let c = current, c.file == entry.file {
            entries[index].anchor = entry.anchor ?? c.anchor
            return
        }
        if index < entries.count - 1 { entries.removeSubrange((index + 1)...) }
        entries.append(entry)
        if entries.count > cap { entries.removeFirst(entries.count - cap) }
        index = entries.count - 1
    }

    /// Keeps the current entry's anchor fresh without creating a new entry.
    mutating func updateAnchor(_ anchor: FileAnchor?) {
        guard entries.indices.contains(index) else { return }
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
