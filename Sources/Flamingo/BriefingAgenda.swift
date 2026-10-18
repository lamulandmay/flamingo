import AppKit
import SwiftUI
import FlamingoConnectors
import FlamingoDesign

/// Connector deadlines and events on the inbox page: overdue first, then the next seven days.
/// Read from `ConnectorsModel`; they are not thoughts, so the page's keys and triage pass them by.
struct BriefingAgenda: View {
    let now: Date
    let visible: Bool

    var body: some View {
        let entries = Self.entries(ConnectorsModel.shared.items, now: now)
        if !entries.isEmpty {
            VStack(spacing: 2) {
                ForEach(entries) { BriefingAgendaRow(item: $0, now: now) }
            }
            .padding(.horizontal, -Theme.Space.s)
            .fadesIn(visible, delay: 0.08)
            .padding(.bottom, Theme.Space.xxl)
        }
    }

    /// Deadlines not yet due and overdue ones (an all-day one only once its day is past), and
    /// events not over, up to the end of the seventh day ahead. Messages are the inbox's own.
    static func entries(_ items: [ConnectorItem], now: Date, calendar: Calendar = .current) -> [ConnectorItem] {
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 8, to: today) ?? now
        return items.filter { item in
            guard let when = item.when, when < end else { return false }
            switch item.kind {
            case .deadline: return true
            case .event: return max(item.end ?? when, when) > now
            case .message: return false
            }
        }
    }

    static func overdue(_ item: ConnectorItem, now: Date, calendar: Calendar = .current) -> Bool {
        guard item.kind == .deadline, let when = item.when else { return false }
        return item.allDay ? when < calendar.startOfDay(for: now) : when < now
    }
}

private struct BriefingAgendaRow: View {
    let item: ConnectorItem
    let now: Date
    @State private var hovering = false

    var body: some View {
        let overdue = BriefingAgenda.overdue(item, now: now)
        HStack(spacing: Theme.Space.s) {
            Image(systemName: item.kind == .deadline ? "flag" : "calendar")
                .font(.system(size: Theme.Size.iconSmall))
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 16)
            Text(item.title)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Theme.Space.s)
            Text(when)
                .font(Theme.Font.monoSmall)
                .foregroundStyle(overdue ? Theme.Color.accent : Theme.Color.textTertiary)
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(maxWidth: .infinity, minHeight: Theme.Size.row, alignment: .leading)
        .background(Squircle(radius: Theme.Radius.s).fill(hovering && link != nil ? Theme.Color.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if let link { NSWorkspace.shared.open(link) } }
        .animation(Theme.Motion.fast, value: hovering)
        .help(item.summary ?? "")
    }

    private var link: URL? {
        item.link.flatMap(URL.init(string:)).flatMap { ["https", "http"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
    }

    /// As the inbox writes dates (the clock today), with the time for a timed item on another day.
    /// An all-day item today has none.
    private var when: String {
        guard let date = item.when else { return "" }
        let day = BriefingFormat.short(date, now: now)
        if Calendar.current.isDate(date, inSameDayAs: now) { return item.allDay ? "" : day }
        return item.allDay ? day : day + " " + date.formatted(date: .omitted, time: .shortened)
    }
}
