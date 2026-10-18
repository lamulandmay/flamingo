import Foundation

/// The parts of iCalendar (RFC 5545) a feed needs: the events and to-dos directly inside the
/// calendar, with their properties. Alarms inside an event and time-zone definitions are
/// skipped; zones are resolved by name instead (`zone(named:)`).
public struct ICalendar: Sendable {
    public struct Property: Equatable, Sendable {
        /// Uppercased.
        public var name: String
        /// Uppercased names, values with their quotes removed.
        public var params: [String: String]
        /// Raw: still escaped.
        public var value: String

        public init(name: String, params: [String: String] = [:], value: String) {
            self.name = name; self.params = params; self.value = value
        }
    }

    public struct Component: Equatable, Sendable {
        public enum Kind: String, Sendable { case event = "VEVENT", todo = "VTODO" }

        public var kind: Kind
        public var properties: [Property]

        public init(kind: Kind, properties: [Property] = []) { self.kind = kind; self.properties = properties }

        public func first(_ name: String) -> Property? { properties.first { $0.name == name } }
        public func all(_ name: String) -> [Property] { properties.filter { $0.name == name } }

        /// Unescaped and trimmed; nil when missing or blank.
        public func text(_ name: String) -> String? {
            guard let p = first(name) else { return nil }
            let text = ICalendar.unescape(p.value).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    public var components: [Component]

    public init(components: [Component]) { self.components = components }

    /// Throws `ConnectorError.notCalendar` without a `BEGIN:VCALENDAR`, which is what an expired
    /// feed link answering with a login page looks like.
    public init(parsing text: String) throws {
        var stack: [String] = []
        var sawCalendar = false
        var current: Component?
        var out: [Component] = []
        for line in Self.unfold(text) {
            guard let p = Self.property(line) else { continue }
            switch p.name {
            case "BEGIN":
                let kind = p.value.trimmingCharacters(in: .whitespaces).uppercased()
                if kind == "VCALENDAR" && stack.isEmpty { sawCalendar = true }
                stack.append(kind)
                if stack.count == 2, stack[0] == "VCALENDAR", let k = Component.Kind(rawValue: kind) {
                    current = Component(kind: k)
                }
            case "END":
                let kind = p.value.trimmingCharacters(in: .whitespaces).uppercased()
                // Tolerates a missing END inside: closing an outer component closes what it holds.
                guard let index = stack.lastIndex(of: kind) else { continue }
                if index == 1, let c = current { out.append(c) }
                if index <= 1 { current = nil }
                stack.removeSubrange(index...)
            default:
                if stack.count == 2, current != nil { current?.properties.append(p) }
            }
        }
        guard sawCalendar else { throw ConnectorError.notCalendar }
        components = out
    }

    // MARK: Lines

    /// Logical lines: CRLF, CR or LF endings; a line starting with a space or tab continues the
    /// previous one (that one character is dropped).
    static func unfold(_ text: String) -> [String] {
        var text = text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else if !raw.isEmpty {
                lines.append(String(raw))
            }
        }
        return lines
    }

    /// `NAME;PARAM=a;PARAM="b;c:d":value`. Quotes protect `;` and `:` in parameter values; the
    /// value is everything after the first unquoted colon.
    static func property(_ line: String) -> Property? {
        var segments: [String] = []
        var current = ""
        var inQuotes = false
        var valueStart: String.Index?
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if c == "\"" {
                inQuotes.toggle()
                current.append(c)
            } else if !inQuotes && c == ";" {
                segments.append(current); current = ""
            } else if !inQuotes && c == ":" {
                segments.append(current)
                valueStart = line.index(after: i)
                break
            } else {
                current.append(c)
            }
            i = line.index(after: i)
        }
        guard let valueStart, let name = segments.first?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        var params: [String: String] = [:]
        for segment in segments.dropFirst() {
            guard let eq = segment.firstIndex(of: "=") else { continue }
            let key = segment[..<eq].trimmingCharacters(in: .whitespaces).uppercased()
            params[key] = segment[segment.index(after: eq)...].replacingOccurrences(of: "\"", with: "")
        }
        return Property(name: name.uppercased(), params: params, value: String(line[valueStart...]))
    }

    /// Text escapes: `\n` `\N` → newline; `\,` `\;` `\\` (and Outlook's `\:`) → the character.
    public static func unescape(_ value: String) -> String {
        var out = ""
        var escaping = false
        for c in value {
            if escaping {
                switch c {
                case "n", "N": out.append("\n")
                case ",", ";", "\\", ":": out.append(c)
                default: out.append("\\"); out.append(c)
                }
                escaping = false
            } else if c == "\\" {
                escaping = true
            } else {
                out.append(c)
            }
        }
        if escaping { out.append("\\") }
        return out
    }

    /// A comma list (`CATEGORIES`), split on unescaped commas, each item unescaped and trimmed.
    public static func list(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var escaping = false
        for c in value {
            if escaping { current.append("\\"); current.append(c); escaping = false }
            else if c == "\\" { escaping = true }
            else if c == "," { parts.append(current); current = "" }
            else { current.append(c) }
        }
        if escaping { current.append("\\") }
        parts.append(current)
        return parts.map { unescape($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

// MARK: - Dates

/// A date from a feed, with the zone its wall clock is in (what repeating events advance in).
public struct ICalDate: Equatable, Sendable {
    public var date: Date
    public var allDay: Bool
    public var timeZone: TimeZone

    public init(date: Date, allDay: Bool, timeZone: TimeZone) {
        self.date = date; self.allDay = allDay; self.timeZone = timeZone
    }
}

/// `DURATION`: whole days (calendar days, so they keep the wall clock across DST) and seconds.
public struct ICalDuration: Equatable, Sendable {
    public var days: Int
    public var seconds: Int

    public init(days: Int, seconds: Int) { self.days = days; self.seconds = seconds }

    public func added(to date: Date, in zone: TimeZone) -> Date {
        let shifted = days == 0 ? date : (feedCalendar(zone).date(byAdding: .day, value: days, to: date) ?? date)
        return shifted.addingTimeInterval(TimeInterval(seconds))
    }
}

extension ICalendar {
    /// A `DTSTART`/`DTEND`/`DUE`-style property. `VALUE=DATE` or 8 digits is all day at midnight
    /// in `local`; a trailing `Z` is UTC; `TZID=` is that zone (`local` when it can't be
    /// resolved); anything else is floating, read in `local`. Impossible dates give nil.
    public static func date(_ p: Property, local: TimeZone) -> ICalDate? {
        date(p.value, tzid: p.params["TZID"], isDate: p.params["VALUE"]?.uppercased() == "DATE", local: local)
    }

    /// Every date of a list property (`EXDATE`, `RDATE`), each read like `date(_:local:)`.
    public static func dates(_ p: Property, local: TimeZone) -> [ICalDate] {
        p.value.split(separator: ",").compactMap {
            date(String($0), tzid: p.params["TZID"], isDate: p.params["VALUE"]?.uppercased() == "DATE", local: local)
        }
    }

    static func date(_ raw: String, tzid: String?, isDate: Bool, local: TimeZone) -> ICalDate? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let chars = Array(value)
        func number(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= chars.count else { return nil }
            let slice = chars[range]
            guard slice.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(String(slice))
        }
        guard let year = number(0..<4), let month = number(4..<6), let day = number(6..<8),
              (1...12).contains(month), day >= 1 else { return nil }
        if isDate || chars.count == 8 {
            guard chars.count == 8 else { return nil }
            return make(year, month, day, 0, 0, 0, zone: local, allDay: true)
        }
        guard chars.count == 15 || (chars.count == 16 && (chars[15] == "Z" || chars[15] == "z")), chars[8] == "T" || chars[8] == "t",
              let hour = number(9..<11), let minute = number(11..<13), let second = number(13..<15),
              hour < 24, minute < 60, second <= 60 else { return nil }
        let zone: TimeZone
        if chars.count == 16 { zone = TimeZone(identifier: "UTC")! }
        else if let tzid, let named = Self.zone(named: tzid) { zone = named }
        else { zone = local }
        return make(year, month, day, hour, minute, min(second, 59), zone: zone, allDay: false)
    }

    private static func make(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int, zone: TimeZone, allDay: Bool) -> ICalDate? {
        let cal = feedCalendar(zone)
        guard let monthStart = cal.date(from: DateComponents(year: y, month: m, day: 1, hour: 12)),
              let days = cal.range(of: .day, in: .month, for: monthStart), days.contains(d),
              let date = cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi, second: s))
        else { return nil }
        return ICalDate(date: date, allDay: allDay, timeZone: zone)
    }

    /// `P1W`, `P2D`, `PT1H30M`, `-PT15M`, `P1DT12H`. Nil for anything else.
    public static func duration(_ raw: String) -> ICalDuration? {
        var chars = Substring(raw.trimmingCharacters(in: .whitespaces).uppercased())
        var sign = 1
        if chars.first == "-" { sign = -1; chars = chars.dropFirst() } else if chars.first == "+" { chars = chars.dropFirst() }
        guard chars.first == "P" else { return nil }
        chars = chars.dropFirst()
        var days = 0, seconds = 0, digits = "", inTime = false, units = 0
        for c in chars {
            if c.isASCII && c.isNumber { digits.append(c); continue }
            if c == "T" { guard digits.isEmpty, !inTime else { return nil }; inTime = true; continue }
            guard let n = Int(digits) else { return nil }
            digits = ""
            switch (c, inTime) {
            case ("W", false): days += 7 * n
            case ("D", false): days += n
            case ("H", true): seconds += 3600 * n
            case ("M", true): seconds += 60 * n
            case ("S", true): seconds += n
            default: return nil
            }
            units += 1
        }
        guard digits.isEmpty, units > 0 else { return nil }
        return ICalDuration(days: sign * days, seconds: sign * seconds)
    }
}

// MARK: - Time zones

extension ICalendar {
    /// A `TZID`: a Windows name Outlook sends, an IANA name, or a `/mozilla.org/…/Europe/Amsterdam`
    /// style prefixed name. Nil when none of those resolve.
    public static func zone(named raw: String) -> TimeZone? {
        let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespaces))
        guard !name.isEmpty else { return nil }
        if let iana = windowsZones[name], let zone = TimeZone(identifier: iana) { return zone }
        if let zone = TimeZone(identifier: name) { return zone }
        let parts = name.split(separator: "/").map(String.init)
        for length in stride(from: min(3, parts.count), through: 1, by: -1) {
            if let zone = TimeZone(identifier: parts.suffix(length).joined(separator: "/")) { return zone }
        }
        return nil
    }

    /// Windows zone names → IANA (CLDR's windowsZones, the default territory of each).
    static let windowsZones: [String: String] = [
        "Dateline Standard Time": "Etc/GMT+12",
        "UTC-11": "Etc/GMT+11",
        "Hawaiian Standard Time": "Pacific/Honolulu",
        "Alaskan Standard Time": "America/Anchorage",
        "Pacific Standard Time (Mexico)": "America/Tijuana",
        "Pacific Standard Time": "America/Los_Angeles",
        "US Mountain Standard Time": "America/Phoenix",
        "Mountain Standard Time (Mexico)": "America/Mazatlan",
        "Mountain Standard Time": "America/Denver",
        "Central America Standard Time": "America/Guatemala",
        "Central Standard Time": "America/Chicago",
        "Central Standard Time (Mexico)": "America/Mexico_City",
        "Canada Central Standard Time": "America/Regina",
        "SA Pacific Standard Time": "America/Bogota",
        "Eastern Standard Time": "America/New_York",
        "US Eastern Standard Time": "America/Indiana/Indianapolis",
        "Atlantic Standard Time": "America/Halifax",
        "Venezuela Standard Time": "America/Caracas",
        "SA Western Standard Time": "America/La_Paz",
        "Pacific SA Standard Time": "America/Santiago",
        "Newfoundland Standard Time": "America/St_Johns",
        "E. South America Standard Time": "America/Sao_Paulo",
        "Argentina Standard Time": "America/Argentina/Buenos_Aires",
        "SA Eastern Standard Time": "America/Cayenne",
        "Greenland Standard Time": "America/Nuuk",
        "UTC-02": "Etc/GMT+2",
        "Azores Standard Time": "Atlantic/Azores",
        "Cape Verde Standard Time": "Atlantic/Cape_Verde",
        "UTC": "Etc/UTC",
        "GMT Standard Time": "Europe/London",
        "Greenwich Standard Time": "Atlantic/Reykjavik",
        "Morocco Standard Time": "Africa/Casablanca",
        "W. Europe Standard Time": "Europe/Berlin",
        "Central Europe Standard Time": "Europe/Budapest",
        "Romance Standard Time": "Europe/Paris",
        "Central European Standard Time": "Europe/Warsaw",
        "W. Central Africa Standard Time": "Africa/Lagos",
        "GTB Standard Time": "Europe/Bucharest",
        "E. Europe Standard Time": "Europe/Chisinau",
        "FLE Standard Time": "Europe/Kiev",
        "Egypt Standard Time": "Africa/Cairo",
        "South Africa Standard Time": "Africa/Johannesburg",
        "Israel Standard Time": "Asia/Jerusalem",
        "Jordan Standard Time": "Asia/Amman",
        "Turkey Standard Time": "Europe/Istanbul",
        "Arabic Standard Time": "Asia/Baghdad",
        "Arab Standard Time": "Asia/Riyadh",
        "Russian Standard Time": "Europe/Moscow",
        "E. Africa Standard Time": "Africa/Nairobi",
        "Iran Standard Time": "Asia/Tehran",
        "Arabian Standard Time": "Asia/Dubai",
        "Azerbaijan Standard Time": "Asia/Baku",
        "Georgian Standard Time": "Asia/Tbilisi",
        "Caucasus Standard Time": "Asia/Yerevan",
        "Afghanistan Standard Time": "Asia/Kabul",
        "Pakistan Standard Time": "Asia/Karachi",
        "West Asia Standard Time": "Asia/Tashkent",
        "Ekaterinburg Standard Time": "Asia/Yekaterinburg",
        "India Standard Time": "Asia/Kolkata",
        "Sri Lanka Standard Time": "Asia/Colombo",
        "Nepal Standard Time": "Asia/Kathmandu",
        "Central Asia Standard Time": "Asia/Almaty",
        "Bangladesh Standard Time": "Asia/Dhaka",
        "Myanmar Standard Time": "Asia/Yangon",
        "SE Asia Standard Time": "Asia/Bangkok",
        "China Standard Time": "Asia/Shanghai",
        "North Asia East Standard Time": "Asia/Irkutsk",
        "Singapore Standard Time": "Asia/Singapore",
        "W. Australia Standard Time": "Australia/Perth",
        "Taipei Standard Time": "Asia/Taipei",
        "Tokyo Standard Time": "Asia/Tokyo",
        "Korea Standard Time": "Asia/Seoul",
        "Cen. Australia Standard Time": "Australia/Adelaide",
        "AUS Central Standard Time": "Australia/Darwin",
        "E. Australia Standard Time": "Australia/Brisbane",
        "AUS Eastern Standard Time": "Australia/Sydney",
        "West Pacific Standard Time": "Pacific/Port_Moresby",
        "Tasmania Standard Time": "Australia/Hobart",
        "Vladivostok Standard Time": "Asia/Vladivostok",
        "UTC+12": "Etc/GMT-12",
        "New Zealand Standard Time": "Pacific/Auckland",
        "Fiji Standard Time": "Pacific/Fiji",
        "Tonga Standard Time": "Pacific/Tongatapu",
        "Samoa Standard Time": "Pacific/Apia",
    ]
}
