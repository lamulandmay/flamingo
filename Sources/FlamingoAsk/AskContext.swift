import Foundation
import FlamingoCore

/// What the user is doing when they ask: the file and place open beside the chat, the folder
/// they're in, and what they opened lately. A few hundred tokens that answer "this", "what was
/// I working on" and "the folder I just used", which no passage can.
public struct AskContext: Sendable, Equatable {
    public struct Visit: Sendable, Equatable {
        public var file: FileRef
        public var anchor: FileAnchor?
        public var at: Date
        public init(file: FileRef, anchor: FileAnchor? = nil, at: Date) { self.file = file; self.anchor = anchor; self.at = at }
    }

    public var openFile: FileRef?
    public var anchor: FileAnchor?
    public var folder: String?
    /// Newest first.
    public var recent: [Visit]

    public init(openFile: FileRef? = nil, anchor: FileAnchor? = nil, folder: String? = nil, recent: [Visit] = []) {
        self.openFile = openFile; self.anchor = anchor; self.folder = folder; self.recent = recent
    }

    public static let empty = AskContext()
    var isEmpty: Bool { openFile == nil && folder == nil && recent.isEmpty }

    /// The block the model reads before the passages. Recent visits are collapsed to one line
    /// per file, at most `maxRecent`.
    func prompt(maxRecent: Int = 15) -> String {
        guard !isEmpty else { return "" }
        var lines: [String] = []
        if let openFile {
            lines.append("open: " + openFile.relativePath + (anchor.map { " at " + $0.label } ?? ""))
        }
        if let folder, !folder.isEmpty { lines.append("folder: " + folder) }
        var seen = Set<FileRef>()
        let visits = recent.filter { seen.insert($0.file).inserted }.prefix(maxRecent)
        if !visits.isEmpty {
            lines.append("recently opened, newest first:")
            for v in visits {
                lines.append("- " + Self.time.string(from: v.at) + "  " + v.file.relativePath + (v.anchor.map { " (" + $0.label + ")" } ?? ""))
            }
        }
        return "<context>\n" + lines.map(Passage.body).joined(separator: "\n") + "\n</context>\n\n"
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}
