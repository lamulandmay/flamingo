import Foundation

/// A due date read from a thought's words.
public struct ParsedDue: Hashable, Sendable {
    /// The start of the day, or the exact minute when `hasTime`.
    public var date: Date
    public var hasTime: Bool
    /// The words that said it, lowercased (`"before friday"` reads as `"friday"`).
    public var matched: String

    /// `yyyy-MM-dd` or `yyyy-MM-dd HH:mm`, local, as stored in `ThoughtMeta.due`.
    public func string(calendar: Calendar = .current) -> String {
        ThoughtDates.string(from: date, hasTime: hasTime, calendar: calendar)
    }
}

/// Reads "tomorrow", "by friday", "next week", "in 3 days", "下周", "October 20" and the like.
///
/// Relative words are anchored at the moment the thought was written (`reference`), not at
/// today: "tomorrow" in a thought from last Tuesday means last Wednesday. `NSDataDetector`
/// cannot take a reference date, so it is used only for absolute dates it is better at than
/// the patterns here, and the year of a date written without one comes from `reference`.
public enum DueParser {
    public static func parse(_ text: String, relativeTo reference: Date, calendar: Calendar = .current) -> ParsedDue? {
        let source = clean(text)
        guard !source.isEmpty else { return nil }
        let ns = source as NSString
        let today = calendar.startOfDay(for: reference)
        var found: [(location: Int, length: Int, day: Date, text: String)] = []

        func add(_ range: NSRange, _ day: Date?) {
            guard let day, range.location != NSNotFound else { return }
            found.append((range.location, range.length, day, ns.substring(with: range)))
        }
        func addDays(_ n: Int) -> Date? { calendar.date(byAdding: .day, value: n, to: today) }

        // today, tomorrow
        for m in matches(#"\b(today|tonight|eod|end of (?:the )?day|this (?:morning|afternoon|evening))\b|今天|今晚|今日|今早"#, in: source) { add(m.range, today) }
        for m in matches(#"\b(day after tomorrow)\b|后天|後天"#, in: source) { add(m.range, addDays(2)) }
        for m in matches(#"\b(tomorrow|tomorow|tmrw|tmr)\b|明天|明日|明早|明晚"#, in: source) { add(m.range, addDays(1)) }

        // in N days / weeks
        for m in matches(#"\b(?:in|within) (\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten) (day|days|week|weeks)\b"#, in: source) {
            guard let n = number(m.group(1, in: ns)) else { continue }
            let unit = m.group(2, in: ns)?.hasPrefix("week") == true ? 7 : 1
            add(m.range, addDays(n * unit))
        }
        for m in matches(#"(\d+|[一二两三四五六七八九十])\s*(天|日|周|个星期|星期)\s*(?:后|內|内|之后|以后)"#, in: source) {
            guard let n = number(m.group(1, in: ns)) else { continue }
            let unit = ["天", "日"].contains(m.group(2, in: ns) ?? "") ? 1 : 7
            add(m.range, addDays(n * unit))
        }

        // weeks and weekdays
        let weekdayNames = "monday|tuesday|wednesday|thursday|friday|saturday|sunday"
        let monday = mondayOnOrBefore(today, calendar)
        for m in matches(#"\bnext (?:week|wk)\b(?! ?(?:"# + weekdayNames + #"))|下(?:个)?(?:周|星期|礼拜)(?![一二三四五六日天])"#, in: source) {
            add(m.range, calendar.date(byAdding: .day, value: 7, to: monday))
        }
        for m in matches(#"\bnext (monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)\b"#, in: source) {
            guard let w = weekday(m.group(1, in: ns)) else { continue }
            add(m.range, calendar.date(byAdding: .day, value: 7 + offsetFromMonday(w), to: monday))
        }
        for m in matches(#"下(?:个)?(?:周|星期|礼拜)([一二三四五六日天])"#, in: source) {
            guard let w = weekday(m.group(1, in: ns)) else { continue }
            add(m.range, calendar.date(byAdding: .day, value: 7 + offsetFromMonday(w), to: monday))
        }
        for m in matches(#"(?:本|这|這)(?:周|星期|礼拜)([一二三四五六日天])"#, in: source) {
            guard let w = weekday(m.group(1, in: ns)) else { continue }
            add(m.range, calendar.date(byAdding: .day, value: offsetFromMonday(w), to: monday))
        }
        // A bare weekday is the next one strictly after the day the thought was written.
        let sure = "monday|tuesday|wednesday|thursday|friday|saturday|sunday|tues|tue|thurs|thur|thu|fri"
        for m in matches(#"\b("# + sure + #")\b"#, in: source) {
            guard let w = weekday(m.group(1, in: ns)), !isPrecededByNext(source, m.range) else { continue }
            add(m.range, nextWeekday(w, after: today, calendar))
        }
        // "mon", "wed", "sat" and "sun" are also ordinary words: only after a word that says "by then".
        for m in matches(#"\b(?:by|on|before|until|till|due|this|for) (mon|wed|sat|sun)\b"#, in: source) {
            guard let w = weekday(m.group(1, in: ns)) else { continue }
            add(m.range, nextWeekday(w, after: today, calendar))
        }
        for m in matches(#"(?<![本这這下])(?:周|星期|礼拜)([一二三四五六日天])"#, in: source) {
            guard let w = weekday(m.group(1, in: ns)) else { continue }
            add(m.range, nextWeekday(w, after: today, calendar))
        }
        for m in matches(#"\b(eow|end of (?:the )?week)\b"#, in: source) {
            // This week's Friday; on a weekend, the coming one.
            var friday = calendar.date(byAdding: .day, value: 4, to: monday)
            if let f = friday, f < today { friday = nextWeekday(6, after: today, calendar) }
            add(m.range, friday)
        }
        for m in matches(#"\b(this weekend)\b|本周末|这周末"#, in: source) {
            add(m.range, nextWeekday(7, after: calendar.date(byAdding: .day, value: -1, to: today) ?? today, calendar))
        }
        for m in matches(#"\b(eom|end of (?:the )?month)\b"#, in: source) {
            if let interval = calendar.dateInterval(of: .month, for: today), let last = calendar.date(byAdding: .day, value: -1, to: interval.end) {
                add(m.range, max(last, today))
            }
        }

        // Absolute dates.
        let monthNames = "jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?"
        for m in matches(#"\b("# + monthNames + #")\.? (\d{1,2})(?:st|nd|rd|th)?(?:,? (\d{4}))?\b"#, in: source) {
            add(m.range, absolute(month: monthNumber(m.group(1, in: ns)), day: Int(m.group(2, in: ns) ?? ""), year: Int(m.group(3, in: ns) ?? ""), reference: today, calendar))
        }
        for m in matches(#"\b(\d{1,2})(?:st|nd|rd|th)? (?:of )?("# + monthNames + #")\b\.?(?:,? (\d{4}))?"#, in: source) {
            add(m.range, absolute(month: monthNumber(m.group(2, in: ns)), day: Int(m.group(1, in: ns) ?? ""), year: Int(m.group(3, in: ns) ?? ""), reference: today, calendar))
        }
        for m in matches(#"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#, in: source) {
            add(m.range, absolute(month: Int(m.group(2, in: ns) ?? ""), day: Int(m.group(3, in: ns) ?? ""), year: Int(m.group(1, in: ns) ?? ""), reference: today, calendar))
        }
        for m in matches(#"(?<![\d/.])\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b(?![\d/])"#, in: source) {
            var year = Int(m.group(3, in: ns) ?? "")
            if let y = year, y < 100 { year = 2000 + y }
            // Month first, as written in the US; a first number past 12 can only be a day.
            let a = Int(m.group(1, in: ns) ?? ""), b = Int(m.group(2, in: ns) ?? "")
            let (month, day) = (a ?? 0) > 12 ? (b, a) : (a, b)
            add(m.range, absolute(month: month, day: day, year: year, reference: today, calendar))
        }
        for m in matches(#"(?:(\d{4})年)?(\d{1,2})月(\d{1,2})[日号號]"#, in: source) {
            add(m.range, absolute(month: Int(m.group(2, in: ns) ?? ""), day: Int(m.group(3, in: ns) ?? ""), year: Int(m.group(1, in: ns) ?? ""), reference: today, calendar))
        }
        if found.isEmpty, let detected = detectAbsolute(source, reference: today, calendar: calendar) {
            found.append(detected)
        }

        guard let first = found.min(by: { $0.location != $1.location ? $0.location < $1.location : $0.length > $1.length }) else { return nil }
        var date = first.day
        var hasTime = false
        if let time = time(in: source, near: NSRange(location: first.location, length: first.length)),
           let withTime = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: first.day) {
            date = withTime; hasTime = true
        }
        return ParsedDue(date: date, hasTime: hasTime, matched: first.text)
    }

    // MARK: Helpers

    /// Lowercased, quote lines and `[[links]]` removed (a link's `#time 0:39` is not a time of day).
    static func clean(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix(">") }
        let joined = lines.joined(separator: "\n")
        return joined.replacingOccurrences(of: #"!?\[\[[^\]]*\]\]"#, with: " ◻ ", options: .regularExpression).lowercased()
    }

    struct Match {
        let result: NSTextCheckingResult
        var range: NSRange { result.range }
        func group(_ i: Int, in ns: NSString) -> String? {
            let r = result.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    private static var cache: [String: NSRegularExpression] = [:]
    private static let cacheLock = NSLock()

    static func matches(_ pattern: String, in text: String) -> [Match] {
        cacheLock.lock()
        let regex = cache[pattern] ?? (try? NSRegularExpression(pattern: pattern, options: []))
        if let regex { cache[pattern] = regex }
        cacheLock.unlock()
        guard let regex else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(Match.init)
    }

    private static let words = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
                                "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10]

    private static func number(_ text: String?) -> Int? {
        guard let text else { return nil }
        return Int(text) ?? words[text]
    }

    /// Calendar weekday numbers: 1 = Sunday … 7 = Saturday.
    private static func weekday(_ text: String?) -> Int? {
        guard let text else { return nil }
        switch text {
        case "monday", "mon", "一": return 2
        case "tuesday", "tue", "tues", "二": return 3
        case "wednesday", "wed", "三": return 4
        case "thursday", "thu", "thur", "thurs", "四": return 5
        case "friday", "fri", "五": return 6
        case "saturday", "sat", "六": return 7
        case "sunday", "sun", "日", "天": return 1
        default: return nil
        }
    }

    private static func offsetFromMonday(_ weekday: Int) -> Int { (weekday + 5) % 7 }

    private static func mondayOnOrBefore(_ day: Date, _ calendar: Calendar) -> Date {
        let w = calendar.component(.weekday, from: day)
        return calendar.date(byAdding: .day, value: -offsetFromMonday(w), to: day) ?? day
    }

    private static func nextWeekday(_ weekday: Int, after day: Date, _ calendar: Calendar) -> Date? {
        let current = calendar.component(.weekday, from: day)
        var delta = (weekday - current + 7) % 7
        if delta == 0 { delta = 7 }
        return calendar.date(byAdding: .day, value: delta, to: day)
    }

    private static func isPrecededByNext(_ text: String, _ range: NSRange) -> Bool {
        let ns = text as NSString
        let start = max(0, range.location - 5)
        return ns.substring(with: NSRange(location: start, length: range.location - start)).hasSuffix("next ")
    }

    private static func monthNumber(_ text: String?) -> Int? {
        guard let prefix = text?.prefix(3) else { return nil }
        return ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].firstIndex(of: String(prefix)).map { $0 + 1 }
    }

    /// A date written with or without a year. Without one, the first such day on or after the
    /// day the thought was written.
    private static func absolute(month: Int?, day: Int?, year: Int?, reference: Date, _ calendar: Calendar) -> Date? {
        guard let month, let day, (1...12).contains(month), (1...31).contains(day) else { return nil }
        func make(_ y: Int) -> Date? {
            guard let date = calendar.date(from: DateComponents(year: y, month: month, day: day)) else { return nil }
            let c = calendar.dateComponents([.month, .day], from: date)
            return c.month == month && c.day == day ? date : nil
        }
        if let year { return make(year) }
        let y = calendar.component(.year, from: reference)
        if let this = make(y), this >= reference { return this }
        return make(y + 1)
    }

    /// `NSDataDetector` for absolute dates the patterns above do not cover ("the 20th of
    /// October"). Only a match that names a month or a numeric date counts: it also reads
    /// "tomorrow" and "next week", relative to now instead of `reference`.
    private static func detectAbsolute(_ text: String, reference: Date, calendar: Calendar) -> (location: Int, length: Int, day: Date, text: String)? {
        guard text.range(of: #"jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|\d{1,4}[/.-]\d{1,2}"#, options: .regularExpression) != nil,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let ns = text as NSString
        for result in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let matched = ns.substring(with: result.range)
            guard matched.range(of: #"jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|\d{1,4}[/.-]\d{1,2}"#, options: .regularExpression) != nil,
                  let date = result.date else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            let explicitYear = matched.range(of: #"\b\d{4}\b"#, options: .regularExpression) != nil
            if let day = absolute(month: c.month, day: c.day, year: explicitYear ? c.year : nil, reference: reference, calendar) {
                return (result.range.location, result.range.length, day, matched)
            }
        }
        return nil
    }

    /// A time of day within 30 characters of the date words: `3pm`, `at 9`, `15:30`.
    private static func time(in text: String, near range: NSRange) -> (hour: Int, minute: Int)? {
        let ns = text as NSString
        let candidates = matches(#"\b(\d{1,2})(?::(\d{2}))?\s?(am|pm)\b|(?:\bat |@ ?)(\d{1,2})(?::(\d{2}))?\b|\b([01]?\d|2[0-3]):([0-5]\d)\b"#, in: text)
        for m in candidates {
            let distance = m.range.location >= NSMaxRange(range) ? m.range.location - NSMaxRange(range) : range.location - NSMaxRange(m.range)
            guard distance < 30 else { continue }
            if let h = m.group(1, in: ns).flatMap(Int.init), let meridiem = m.group(3, in: ns) {
                guard (1...12).contains(h) else { continue }
                return (h % 12 + (meridiem == "pm" ? 12 : 0), m.group(2, in: ns).flatMap(Int.init) ?? 0)
            }
            if let h = m.group(4, in: ns).flatMap(Int.init), (0..<24).contains(h) {
                return (h, m.group(5, in: ns).flatMap(Int.init) ?? 0)
            }
            if let h = m.group(6, in: ns).flatMap(Int.init) { return (h, m.group(7, in: ns).flatMap(Int.init) ?? 0) }
        }
        return nil
    }
}
