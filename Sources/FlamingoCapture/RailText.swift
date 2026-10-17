import Foundation
import SwiftUI
import FlamingoCore
import FlamingoDesign

/// One run of comment text as the rail draws it: plain text, or a wikilink.
struct RailSegment: Equatable {
    /// What is drawn. For a link, the alias if there is one, else the file name (and anchor).
    var text: String
    /// The link target with any `#anchor` kept and the `|alias` dropped. `nil` for plain text.
    var target: String?
}

/// Pure text logic behind `CommentsRail`: wikilink runs, link URLs, timestamps.
enum RailText {
    static let linkScheme = "flamingo-wikilink"

    /// Splits `text` into plain runs and `[[wikilink]]` runs. Brackets are dropped from links.
    /// A `[[` with no closing `]]` on the same line stays literal.
    static func segments(_ text: String) -> [RailSegment] {
        var out: [RailSegment] = []
        var plain = ""
        var i = text.startIndex
        while i < text.endIndex {
            if text[i...].hasPrefix("[["),
               let close = text[text.index(i, offsetBy: 2)...].range(of: "]]") {
                let inner = text[text.index(i, offsetBy: 2)..<close.lowerBound]
                if let link = link(from: inner) {
                    if !plain.isEmpty { out.append(RailSegment(text: plain, target: nil)); plain = "" }
                    out.append(link)
                    i = close.upperBound
                    continue
                }
            }
            plain.append(text[i])
            i = text.index(after: i)
        }
        if !plain.isEmpty { out.append(RailSegment(text: plain, target: nil)) }
        return out
    }

    private static func link(from inner: Substring) -> RailSegment? {
        // `[[a [[b]]`: the first `[[` is literal; the scan will find the second.
        guard !inner.contains("[["), !inner.contains("\n") else { return nil }
        let bar = inner.firstIndex(of: "|")
        let target = (bar.map { inner[..<$0] } ?? inner).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        let alias = bar.map { inner[inner.index(after: $0)...].trimmingCharacters(in: .whitespaces) } ?? ""
        return RailSegment(text: alias.isEmpty ? displayName(of: target) : alias, target: target)
    }

    /// What a link reads as: the file name without its folders, then " › anchor" if it has one.
    /// `decks/q3.pptx#slide 7` reads `q3.pptx › slide 7`. The stored text keeps the full path.
    static func displayName(of target: String) -> String {
        let parts = Wikilink.components(of: target)
        let name = parts.target.isEmpty ? "" : (parts.target as NSString).lastPathComponent
        guard let anchor = parts.anchor, !anchor.isEmpty else { return name.isEmpty ? target : name }
        return name.isEmpty ? anchor : name + " › " + anchor
    }

    /// Comment text with wikilinks as accent-colored links the rail's `openURL` handler resolves.
    static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString()
        for seg in segments(text) {
            var run = AttributedString(seg.text)
            if let target = seg.target, let url = linkURL(for: target) {
                run.link = url
                run.foregroundColor = Theme.Color.accent
            }
            out.append(run)
        }
        return out
    }

    static func linkURL(for target: String) -> URL? {
        guard let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "\(linkScheme):\(encoded)")
    }

    static func linkTarget(from url: URL) -> String? {
        guard url.scheme == linkScheme else { return nil }
        let raw = url.absoluteString.dropFirst(linkScheme.count + 1)
        return String(raw).removingPercentEncoding
    }

    /// `slide 7`, `cell Q3!B12`. The sidecar's `(slide 7)` without the parentheses.
    static func anchorLabel(_ anchor: FileAnchor) -> String { "\(anchor.kind.rawValue) \(anchor.value)" }

    /// `22:05` today, `Oct 12` earlier this year, `Oct 12, 2025` before that.
    static func timestamp(_ date: Date, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent,
                          locale: Locale = .autoupdatingCurrent) -> String {
        let template: String
        if calendar.isDate(date, inSameDayAs: now) {
            template = "HH:mm"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            template = "MMMd"
        } else {
            template = "yMMMd"
        }
        return formatter(template, calendar: calendar, locale: locale).string(from: date)
    }

    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]
    private static let formattersLock = NSLock()

    private static func formatter(_ template: String, calendar: Calendar, locale: Locale) -> DateFormatter {
        let key = "\(template)|\(locale.identifier)|\(calendar.identifier)|\(calendar.timeZone.identifier)"
        formattersLock.lock(); defer { formattersLock.unlock() }
        if let f = formatters[key] { return f }
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        // Times match the sidecar's 24-hour clock; dates follow the locale.
        if template == "HH:mm" { f.dateFormat = template } else { f.setLocalizedDateFormatFromTemplate(template) }
        formatters[key] = f
        return f
    }
}
