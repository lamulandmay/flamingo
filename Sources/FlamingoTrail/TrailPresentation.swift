import Foundation
import FlamingoCore

/// One stop along a session's chain, in the order the user got there.
struct TrailStop: Identifiable, Equatable {
    enum Kind: Equatable {
        /// `anchor` is where the user last was in the file, if the shell recorded it.
        case file(FileRef, anchor: FileAnchor?, notes: [TrailNote])
        case search(String)
    }
    var id: String
    var kind: Kind
}

/// A thought (or a typed link) made on a file during the session.
struct TrailNote: Identifiable, Equatable {
    var id: UUID
    var anchor: FileAnchor?
    var text: String
}

enum TrailPresentation {

    /// Files in order of first appearance, de-duplicated, with the session's comments
    /// beneath their file and searches between files.
    static func stops(for session: TrailSession) -> [TrailStop] {
        var out: [TrailStop] = []
        var index: [FileRef: Int] = [:]
        var anchors: [FileRef: FileAnchor] = [:]
        var notes: [FileRef: [TrailNote]] = [:]

        func ensure(_ f: FileRef) {
            if index[f] == nil {
                index[f] = out.count
                out.append(TrailStop(id: "f:" + f.relativePath, kind: .file(f, anchor: nil, notes: [])))
            }
        }
        for e in session.events {
            switch e.kind {
            case .opened, .saved:
                guard let f = e.file else { continue }
                ensure(f)
                if let a = e.anchor { anchors[f] = a }
            case .commented:
                guard let f = e.file, let t = e.text else { continue }
                ensure(f)
                notes[f, default: []].append(TrailNote(id: e.id, anchor: e.anchor, text: t))
            case .linked:
                guard let f = e.file, let t = e.text else { continue }
                ensure(f)
                let target = t.hasPrefix("[[") ? t : "[[\(t)]]"
                notes[f, default: []].append(TrailNote(id: e.id, anchor: e.anchor, text: target))
            case .searched:
                guard let q = e.text, !q.isEmpty else { continue }
                out.append(TrailStop(id: "s:" + e.id.uuidString, kind: .search(q)))
            }
        }
        for (f, i) in index {
            out[i].kind = .file(f, anchor: anchors[f], notes: withoutEchoedLinks(notes[f] ?? []))
        }
        return out
    }

    /// A `linked` event usually repeats a `[[link]]` already visible in a comment on the same
    /// file. Show it only when it adds something.
    private static func withoutEchoedLinks(_ notes: [TrailNote]) -> [TrailNote] {
        func key(_ target: String) -> String { (target as NSString).deletingPathExtension.lowercased() }
        let isLinkOnly: (TrailNote) -> Bool = { n in
            let t = n.text.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("[[") && t.hasSuffix("]]") && Wikilink.parse(t).count == 1
                && t.dropFirst(2).dropLast(2).range(of: "]]") == nil
        }
        let mentioned = Set(notes.filter { !isLinkOnly($0) }.flatMap { Wikilink.parse($0.text) }.map(key))
        var seen = Set<String>()
        return notes.filter { n in
            guard isLinkOnly(n), let target = Wikilink.parse(n.text).first.map(key) else { return true }
            return !mentioned.contains(target) && seen.insert(target).inserted
        }
    }

    /// `Tue 14:05 – 15:40` within the last week, `Oct 3 14:05 – 15:40` this year,
    /// `Oct 3 2025 14:05 – 15:40` before that. One time when start and end share a minute.
    static func timeRange(start: Date, end: Date, now: Date = Date(), calendar: Calendar = .current,
                          locale: Locale = .current) -> String {
        let base = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar,
                                    timeZone: calendar.timeZone)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        let day: String
        if days >= 0 && days < 7 {
            day = start.formatted(base.weekday(.abbreviated))
        } else if calendar.component(.year, from: start) == calendar.component(.year, from: now) {
            day = start.formatted(base.month(.abbreviated).day())
        } else {
            day = start.formatted(base.year().month(.abbreviated).day())
        }
        func hm(_ d: Date) -> String {
            let c = calendar.dateComponents([.hour, .minute], from: d)
            return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        }
        let a = hm(start), b = hm(end)
        return a == b && calendar.isDate(start, inSameDayAs: end) ? "\(day) \(a)" : "\(day) \(a) – \(b)"
    }

    /// Splits text into plain runs and wikilinks. A link shows its alias if it has one,
    /// otherwise its target as typed.
    static func segments(_ text: String) -> [(text: String, isLink: Bool)] {
        linkSegments(text).map { ($0.text, $0.target != nil) }
    }

    /// Keep display aliases separate from their real destination.
    static func linkSegments(_ text: String) -> [(text: String, target: String?)] {
        var out: [(String, String?)] = []
        var rest = Substring(text)
        while let open = rest.range(of: "[["), let close = rest[open.upperBound...].range(of: "]]") {
            let inner = rest[open.upperBound..<close.lowerBound]
            if !rest[..<open.lowerBound].isEmpty { out.append((String(rest[..<open.lowerBound]), nil)) }
            if let bar = inner.firstIndex(of: "|") {
                out.append((String(inner[inner.index(after: bar)...]), String(inner[..<bar])))
            } else { out.append((String(inner), String(inner))) }
            rest = rest[close.upperBound...]
        }
        if !rest.isEmpty { out.append((String(rest), nil)) }
        return out
    }
}
