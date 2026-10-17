import Foundation

/// The briefing's day starts at 04:00 on the wall clock: `startOfDay(now - 4h)`. 03:59 still
/// belongs to yesterday, so working past midnight doesn't make a new day. The four hours are
/// taken off the clock, not off the timeline, so a day with a daylight saving change still
/// begins at 04:00.
public enum BriefingDay {
    public static let boundaryHours = 4

    public static func start(of now: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: shifted(now, calendar))
    }

    /// `yyyy-MM-dd` of the briefing day `now` belongs to.
    public static func key(_ now: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: shifted(now, calendar))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 04:00 on the briefing day `now` belongs to, the moment the day began.
    public static func begin(of now: Date, calendar: Calendar = .current) -> Date {
        let start = start(of: now, calendar: calendar)
        return calendar.date(bySettingHour: boundaryHours, minute: 0, second: 0, of: start) ?? start.addingTimeInterval(Double(boundaryHours) * 3600)
    }

    /// `now`, or the same moment yesterday when the clock reads before 04:00.
    private static func shifted(_ now: Date, _ calendar: Calendar) -> Date {
        guard calendar.component(.hour, from: now) < boundaryHours else { return now }
        return calendar.date(byAdding: .day, value: -1, to: now) ?? now.addingTimeInterval(-86_400)
    }
}
