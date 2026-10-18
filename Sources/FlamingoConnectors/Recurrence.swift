import Foundation

/// The `RRULE` subset school and work calendars use: FREQ DAILY/WEEKLY/MONTHLY/YEARLY with
/// INTERVAL, COUNT, UNTIL and WKST; BYDAY (a filter when daily, the days when weekly, `2TU` or
/// `-1FR` style when monthly); BYMONTHDAY (monthly and yearly, negative from the month's end);
/// BYMONTH (yearly months, a filter otherwise). Anything else that would move the dates
/// (BYSETPOS, BYHOUR, HOURLY…) makes the rule unsupported, and the event keeps only its first date.
struct RecurrenceRule: Equatable, Sendable {
    enum Frequency: String, Sendable { case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY" }

    struct Day: Equatable, Sendable {
        /// 0 for every such day; 1 the first, -1 the last (monthly only).
        var ordinal: Int
        /// Calendar weekday: 1 Sunday … 7 Saturday.
        var weekday: Int
    }

    var frequency: Frequency
    var interval = 1
    var count: Int?
    /// Raw `UNTIL`, read in the event's zone when expanding.
    var until: String?
    var byDay: [Day] = []
    var byMonthDay: [Int] = []
    var byMonth: [Int] = []
    /// Calendar weekday the week starts on (`WKST`, Monday by default).
    var weekStart = 2

    static let weekdays = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    /// Nil when the rule is malformed or uses a part this subset doesn't handle.
    init?(_ value: String) {
        var fields: [String: String] = [:]
        for part in value.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            guard pair.count == 2 else { continue }
            fields[pair[0]] = pair[1]
        }
        let handled: Set<String> = ["FREQ", "INTERVAL", "COUNT", "UNTIL", "WKST", "BYDAY", "BYMONTHDAY", "BYMONTH"]
        guard fields.keys.allSatisfy(handled.contains), let freq = fields["FREQ"].flatMap(Frequency.init(rawValue:)) else { return nil }
        frequency = freq
        if let raw = fields["INTERVAL"] { guard let n = Int(raw), n >= 1 else { return nil }; interval = n }
        if let raw = fields["COUNT"] { guard let n = Int(raw), n >= 1 else { return nil }; count = n }
        until = fields["UNTIL"]
        if let raw = fields["WKST"] { guard let day = Self.weekdays[raw] else { return nil }; weekStart = day }
        if let raw = fields["BYDAY"] {
            for item in raw.split(separator: ",") {
                let code = String(item.suffix(2))
                guard let weekday = Self.weekdays[code] else { return nil }
                let prefix = item.dropLast(2)
                guard let ordinal = prefix.isEmpty ? 0 : Int(prefix.hasPrefix("+") ? String(prefix.dropFirst()) : String(prefix)),
                      abs(ordinal) <= 5 else { return nil }
                byDay.append(Day(ordinal: freq == .monthly ? ordinal : 0, weekday: weekday))
            }
        }
        func ints(_ key: String, _ range: ClosedRange<Int>) -> [Int]? {
            guard let raw = fields[key] else { return [] }
            let list = raw.split(separator: ",").compactMap { Int($0) }
            guard !list.isEmpty, list.allSatisfy({ range.contains(abs($0)) }) else { return nil }
            return list
        }
        guard let monthDays = ints("BYMONTHDAY", 1...31), let months = ints("BYMONTH", 1...12),
              months.allSatisfy({ $0 > 0 }) else { return nil }
        byMonthDay = monthDays
        byMonth = months
        switch freq {
        case .weekly: if !byMonthDay.isEmpty { return nil }
        case .monthly: if !byDay.isEmpty && !byMonthDay.isEmpty { return nil }
        case .yearly: if !byDay.isEmpty { return nil }
        case .daily: break
        }
    }
}

enum Recurrence {
    /// At most this many occurrences of one event, whatever the window.
    static let cap = 500

    /// Starts of the occurrences that begin in `from..<to`, in order. The first is always the
    /// event's own start; COUNT counts from there, excluded dates included (as RFC 5545 says).
    /// The wall clock is kept in the start's zone, so a 9:00 class stays at 9:00 across DST.
    static func occurrences(of rule: RecurrenceRule, start: ICalDate, from: Date, to: Date,
                            excluding: [ICalDate] = [], cap: Int = cap) -> [Date] {
        var cal = feedCalendar(start.timeZone)
        cal.firstWeekday = rule.weekStart
        let parts = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: start.date)
        guard let y0 = parts.year, let m0 = parts.month, let d0 = parts.day else { return [] }
        let clock = (parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)

        func noon(_ y: Int, _ m: Int, _ d: Int) -> Date? { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12)) }
        func daysIn(_ y: Int, _ m: Int) -> Int {
            guard let first = noon(y, m, 1), let range = cal.range(of: .day, in: .month, for: first) else { return 0 }
            return range.count
        }
        func at(_ y: Int, _ m: Int, _ d: Int) -> Date? {
            guard (1...daysIn(y, m)).contains(d) else { return nil }
            return cal.date(from: DateComponents(year: y, month: m, day: d, hour: clock.0, minute: clock.1, second: clock.2))
        }
        func shifted(by days: Int) -> (Int, Int, Int)? {
            guard let base = noon(y0, m0, d0), let date = cal.date(byAdding: .day, value: days, to: base) else { return nil }
            let c = cal.dateComponents([.year, .month, .day], from: date)
            guard let y = c.year, let m = c.month, let d = c.day else { return nil }
            return (y, m, d)
        }
        func weekday(_ y: Int, _ m: Int, _ d: Int) -> Int { noon(y, m, d).map { cal.component(.weekday, from: $0) } ?? 0 }
        func resolve(_ days: [Int], in count: Int) -> [Int] {
            Set(days.map { $0 < 0 ? count + $0 + 1 : $0 }.filter { $0 >= 1 && $0 <= count }).sorted()
        }
        let weekday0 = weekday(y0, m0, d0)
        let byDays = Set(rule.byDay.map(\.weekday))

        func candidates(_ period: Int) -> [Date] {
            let n = period * rule.interval
            switch rule.frequency {
            case .daily:
                guard let day = shifted(by: n) else { return [] }
                let (y, m, d) = day
                if !rule.byMonth.isEmpty && !rule.byMonth.contains(m) { return [] }
                if !rule.byMonthDay.isEmpty && !resolve(rule.byMonthDay, in: daysIn(y, m)).contains(d) { return [] }
                if !byDays.isEmpty && !byDays.contains(weekday(y, m, d)) { return [] }
                return at(y, m, d).map { [$0] } ?? []
            case .weekly:
                let offset = (weekday0 - rule.weekStart + 7) % 7
                let days = (byDays.isEmpty ? [weekday0] : Array(byDays)).map { ($0 - rule.weekStart + 7) % 7 }.sorted()
                return days.compactMap { day in
                    guard let date = shifted(by: n * 7 - offset + day) else { return nil }
                    let (y, m, d) = date
                    if !rule.byMonth.isEmpty && !rule.byMonth.contains(m) { return nil }
                    return at(y, m, d)
                }
            case .monthly:
                let total = (m0 - 1) + n
                let (y, m) = (y0 + total / 12, total % 12 + 1)
                if !rule.byMonth.isEmpty && !rule.byMonth.contains(m) { return [] }
                let count = daysIn(y, m)
                var days: [Int] = []
                if rule.byDay.isEmpty {
                    days = resolve(rule.byMonthDay.isEmpty ? [d0] : rule.byMonthDay, in: count)
                } else {
                    let first = weekday(y, m, 1)
                    for item in rule.byDay {
                        let all = Array(stride(from: 1 + (item.weekday - first + 7) % 7, through: count, by: 7))
                        if item.ordinal == 0 { days += all }
                        else if item.ordinal > 0, item.ordinal <= all.count { days.append(all[item.ordinal - 1]) }
                        else if item.ordinal < 0, -item.ordinal <= all.count { days.append(all[all.count + item.ordinal]) }
                    }
                    days = Set(days).sorted()
                }
                return days.compactMap { at(y, m, $0) }
            case .yearly:
                let y = y0 + n
                return Set(rule.byMonth.isEmpty ? [m0] : rule.byMonth).sorted().flatMap { m in
                    resolve(rule.byMonthDay.isEmpty ? [d0] : rule.byMonthDay, in: daysIn(y, m)).compactMap { at(y, m, $0) }
                }
            }
        }

        var until: Date?
        if let raw = rule.until, let parsed = ICalendar.date(raw, tzid: nil, isDate: raw.count == 8, local: start.timeZone) {
            // A date-only UNTIL includes that whole day.
            until = parsed.allDay ? (cal.date(byAdding: .day, value: 1, to: parsed.date) ?? parsed.date).addingTimeInterval(-1) : parsed.date
        }
        let excludedTimes = Set(excluding.filter { !$0.allDay || start.allDay }.map { Int($0.date.timeIntervalSince1970) })
        func dayKey(_ date: Date, _ calendar: Calendar) -> Int {
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            return (c.year ?? 0) * 10_000 + (c.month ?? 0) * 100 + (c.day ?? 0)
        }
        let excludedDays = Set(excluding.filter { $0.allDay && !start.allDay }.map { dayKey($0.date, feedCalendar($0.timeZone)) })
        func isExcluded(_ date: Date) -> Bool {
            if excludedTimes.contains(Int(date.timeIntervalSince1970)) { return true }
            return !excludedDays.isEmpty && excludedDays.contains(dayKey(date, cal))
        }

        var out: [Date] = []
        var produced = 0
        var done = false
        func consider(_ date: Date) {
            if let until, date > until { done = true; return }
            if let count = rule.count, produced >= count { done = true; return }
            produced += 1
            if date >= to { done = true; return }
            if date >= from && !isExcluded(date) {
                out.append(date)
                if out.count >= cap { done = true }
            }
        }

        consider(start.date)
        // Without COUNT nothing before the window matters, so jump close to it (a period early).
        var period = 0
        if rule.count == nil, from > start.date {
            let days = Int(from.timeIntervalSince(start.date) / 86_400)
            let span: Int
            switch rule.frequency {
            case .daily: span = 1
            case .weekly: span = 7
            case .monthly: span = 31
            case .yearly: span = 366
            }
            period = max(0, days / (span * rule.interval) - 1)
        }
        var steps = 0
        while !done && steps < 50_000 {
            for date in candidates(period) where date > start.date {
                consider(date)
                if done { break }
            }
            period += 1
            steps += 1
        }
        return out
    }
}
