import Foundation

/// The briefing's day starts at 04:00: `startOfDay(now - 4h)`. 03:59 still belongs to yesterday,
/// so working past midnight doesn't make a new day.
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
        calendar.date(byAdding: .hour, value: boundaryHours, to: start(of: now, calendar: calendar)) ?? start(of: now, calendar: calendar)
    }

    private static func shifted(_ now: Date, _ calendar: Calendar) -> Date {
        calendar.date(byAdding: .hour, value: -boundaryHours, to: now) ?? now.addingTimeInterval(-Double(boundaryHours) * 3600)
    }
}
