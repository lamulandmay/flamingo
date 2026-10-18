import Foundation

/// The answer to a conditional download.
public enum FeedFetch: Equatable, Sendable {
    case notModified
    case fetched(Data, etag: String?, lastModified: String?)
}

/// Downloads a feed. Tests use a fake; the app uses `URLSessionFeedTransport`.
public protocol FeedTransport: Sendable {
    /// Sends `etag` and `lastModified` back so an unchanged feed can answer "not modified".
    /// Throws `ConnectorError` only, never an error that carries the URL.
    func fetch(_ url: URL, etag: String?, lastModified: String?) async throws -> FeedFetch
}

/// HTTP(S) with no disk cache and no cookies, 30 seconds to answer, 20 MB at most. Any status
/// other than 2xx and 304 is an error.
public struct URLSessionFeedTransport: FeedTransport {
    public static let maxBytes = 20 * 1024 * 1024
    let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }

    public func fetch(_ url: URL, etag: String?, lastModified: String?) async throws -> FeedFetch {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("text/calendar, text/plain;q=0.8, */*;q=0.5", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw ConnectorError.network }
            if http.statusCode == 304 { return .notModified }
            guard (200..<300).contains(http.statusCode) else { throw ConnectorError.httpStatus(http.statusCode) }
            if http.expectedContentLength > Int64(Self.maxBytes) { throw ConnectorError.tooLarge }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > Self.maxBytes { throw ConnectorError.tooLarge }
            }
            return .fetched(data, etag: http.value(forHTTPHeaderField: "ETag"),
                            lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
        } catch let error as ConnectorError {
            throw error
        } catch {
            // A URLError carries the URL, and the URL carries the feed's token: keep the kind only.
            throw ConnectorError.network
        }
    }
}

/// iCalendar feeds (ManageBac, Google, Outlook, iCloud published calendars) → items.
public enum ICalAdapter {
    /// `webcal://` and `webcals://` become `https://`; only http(s) with a host is accepted.
    public static func feedURL(_ string: String) -> URL? {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.hasPrefix("webcals://") { text = "https://" + text.dropFirst("webcals://".count) }
        else if lower.hasPrefix("webcal://") { text = "https://" + text.dropFirst("webcal://".count) }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// UTF-8, else Latin-1 (which reads any bytes).
    public static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    public static func items(from data: Data, card: PurposeCard, now: Date, timeZone: TimeZone) throws -> [ConnectorItem] {
        items(from: try ICalendar(parsing: text(data)), card: card, now: now, timeZone: timeZone)
    }

    /// The card's items, soonest first, undated last.
    ///
    /// - A to-do is a deadline (due at DUE, else DTSTART); an event is one too when the card's
    ///   role is `deadlines`, due at its start. Other events keep start and end (DTEND, else
    ///   DURATION, else a day for an all-day event).
    /// - Cancelled, completed and untitled entries, events without a date, and anything outside
    ///   the window or refused by the card's words are dropped. A to-do without a date stays.
    /// - Repeating entries are expanded inside the window (`Recurrence`), minus EXDATE, with each
    ///   RECURRENCE-ID override replacing its occurrence.
    /// - Ids: the UID; `uid@<epoch>` for every occurrence of a repeating entry (an override uses
    ///   the epoch of the occurrence it replaces) and for every use of a UID that appears more
    ///   than once, so ids don't depend on the feed's order; `#2` on exact duplicates; a stable
    ///   hash of title and time when there is no UID.
    public static func items(from calendar: ICalendar, card: PurposeCard, now: Date, timeZone: TimeZone) -> [ConnectorItem] {
        let card = card.clamped()
        let range = card.window.range(now: now, timeZone: timeZone)
        let fetchedAt = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))

        var uses: [String: Int] = [:]
        var overridden: [String: [ICalDate]] = [:]
        for c in calendar.components {
            guard let uid = c.text("UID") else { continue }
            uses[uid, default: 0] += 1
            if let rid = c.first("RECURRENCE-ID"), let date = ICalendar.date(rid, local: timeZone) {
                overridden[uid, default: []].append(date)
            }
        }

        var out: [ConnectorItem] = []
        var taken = Set<String>()
        for c in calendar.components {
            let status = c.text("STATUS")?.uppercased()
            guard status != "CANCELLED", let title = cleanTitle(c) else { continue }
            let isTodo = c.kind == .todo
            if isTodo && (status == "COMPLETED" || c.first("COMPLETED") != nil) { continue }
            let uid = c.text("UID")
            let start = c.first("DTSTART").flatMap { ICalendar.date($0, local: timeZone) }
            let due = isTodo ? c.first("DUE").flatMap { ICalendar.date($0, local: timeZone) } : nil
            let anchor = isTodo ? (due ?? start) : start
            if !isTodo && anchor == nil { continue }
            let span = isTodo ? nil : length(of: c, start: start, local: timeZone)
            let replaces = c.first("RECURRENCE-ID").flatMap { ICalendar.date($0, local: timeZone) }

            // (when, epoch for the id) for each occurrence.
            var instances: [(date: Date?, key: Int?)] = []
            if let anchor, replaces == nil, let rrule = c.first("RRULE") {
                let lookback = span.map { TimeInterval(max(0, $0.days * 86_400 + $0.seconds + 3_600)) } ?? 0
                let excluded = c.all("EXDATE").flatMap { ICalendar.dates($0, local: timeZone) } + (uid.flatMap { overridden[$0] } ?? [])
                let starts = RecurrenceRule(rrule.value).map {
                    Recurrence.occurrences(of: $0, start: anchor, from: range.lowerBound.addingTimeInterval(-lookback),
                                           to: range.upperBound, excluding: excluded)
                } ?? [anchor.date]
                instances = starts.map { date -> (date: Date?, key: Int?) in (date, epoch(date)) }
            } else if let replaces {
                instances = [(anchor?.date ?? replaces.date, epoch(replaces.date))]
            } else {
                instances = [(anchor?.date, anchor.map { epoch($0.date) })]
            }
            let repeating = c.first("RRULE") != nil || replaces != nil

            let categories = unique(c.all("CATEGORIES").flatMap { ICalendar.list($0.value) })
            let link = c.text("URL").flatMap { ICalAdapter.feedURL($0) != nil && !$0.lowercased().hasPrefix("webcal") ? $0 : nil }
            let summary = c.text("DESCRIPTION").map { String($0.prefix(1_000)) }
            let zone = anchor?.timeZone ?? timeZone

            for instance in instances {
                let id: String
                if let uid {
                    if let key = instance.key, repeating || uses[uid, default: 0] > 1 { id = "\(uid)@\(key)" } else { id = uid }
                } else {
                    id = "h-" + stableHash(title + "|" + (instance.key.map(String.init) ?? "-"))
                }
                var item = ConnectorItem(id: id, connector: card.id, kind: isTodo || card.role == .deadlines ? .deadline : .event,
                                         title: title, allDay: anchor?.allDay ?? false, categories: categories,
                                         link: link, summary: summary, fetchedAt: fetchedAt)
                if isTodo {
                    item.due = instance.date
                } else if let date = instance.date {
                    item.start = date
                    item.end = span.map { $0.added(to: date, in: zone) }
                    if card.role == .deadlines { item.due = date }
                }
                guard item.falls(in: range), card.keeps(item) else { continue }
                if taken.contains(item.id) {
                    var n = 2
                    while taken.contains("\(item.id)#\(n)") { n += 1 }
                    item.id = "\(item.id)#\(n)"
                }
                taken.insert(item.id)
                out.append(item)
            }
        }
        return out.sorted(by: ConnectorItem.ordered)
    }

    /// An event's length: DTEND − DTSTART (whole days for an all-day event), else DURATION,
    /// else one day for an all-day event and nothing for a timed one.
    static func length(of c: ICalendar.Component, start: ICalDate?, local: TimeZone) -> ICalDuration? {
        guard let start else { return nil }
        if let end = c.first("DTEND").flatMap({ ICalendar.date($0, local: local) }), end.date >= start.date {
            if start.allDay {
                let days = feedCalendar(start.timeZone).dateComponents([.day], from: start.date, to: end.date).day ?? 0
                return ICalDuration(days: days, seconds: 0)
            }
            return ICalDuration(days: 0, seconds: Int(end.date.timeIntervalSince(start.date)))
        }
        if let raw = c.first("DURATION")?.value, let duration = ICalendar.duration(raw), duration.days >= 0, duration.seconds >= 0 {
            return duration
        }
        return start.allDay ? ICalDuration(days: 1, seconds: 0) : nil
    }

    static func cleanTitle(_ c: ICalendar.Component) -> String? {
        guard let raw = c.text("SUMMARY") else { return nil }
        let title = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return title.isEmpty ? nil : title
    }

    static func epoch(_ date: Date) -> Int { Int(date.timeIntervalSince1970.rounded(.down)) }

    /// FNV-1a, 64 bits, as 16 hex digits: the same in every process (unlike `Hasher`).
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash ^= UInt64(byte); hash = hash &* 0x0000_0100_0000_01b3 }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    private static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.lowercased()).inserted }
    }
}
