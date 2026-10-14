import SwiftUI
import FlamingoCore
import FlamingoDesign

enum TrailMetrics {
    static let header: CGFloat = 26
    static let gutter: CGFloat = 156
    static let rail: CGFloat = 20
    static let dot: CGFloat = 5
    static let thumb: CGFloat = 32
    static let thumbMaxWidth: CGFloat = 48
    static let fileColumn: CGFloat = 112
    static let notedColumn: CGFloat = 212
    static let searchMax: CGFloat = 168
    static let searchLink: CGFloat = 16
    static let gap: CGFloat = 6
}

/// The list: newest session on top, one row each, a hairline rail on the left joining them.
struct TrailTimeline: View {
    var sessions: [TrailSession]
    var vaultRoot: URL?
    var showsPaused: Bool
    var onOpen: (FileRef, FileAnchor?) -> Void
    var onResume: ((TrailSession) -> Void)?
    var onRename: (TrailSession, String?) -> Void

    enum Focus: Hashable { case list, title }

    @State private var selection: UUID?
    @State private var expanded: [UUID: Bool] = [:]
    @State private var titles: [UUID: String] = [:]   // set by rename before the store reloads; "" clears
    @State private var editing: UUID?
    @State private var draft = ""
    @State private var hovered: UUID?
    @FocusState private var focus: Focus?

    private var ordered: [TrailSession] {
        sessions.sorted { $0.start != $1.start ? $0.start > $1.start : $0.id.uuidString < $1.id.uuidString }
    }

    var body: some View {
        let rows = ordered
        Group {
            if rows.isEmpty {
                if showsPaused {
                    Text("Trail paused")
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.Color.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color.clear
                }
            } else {
                list(rows)
            }
        }
        .background(Theme.Color.bg)
    }

    private func list(_ rows: [TrailSession]) -> some View {
        let calendar = Calendar.current
        let now = Date()
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, s in
                        SessionRow(
                            session: s,
                            title: title(of: s),
                            range: TrailPresentation.timeRange(start: s.start, end: s.end, now: now, calendar: calendar),
                            expanded: isExpanded(s, calendar: calendar),
                            selected: selection == s.id,
                            hovered: hovered == s.id,
                            editing: editing == s.id,
                            topGap: i > 0 && !calendar.isDate(rows[i - 1].start, inSameDayAs: s.start) ? Theme.Space.l : 0,
                            isFirst: i == 0,
                            isLast: i == rows.count - 1,
                            vaultRoot: vaultRoot,
                            draft: $draft,
                            focus: $focus,
                            canResume: onResume != nil,
                            onSelect: { select(s.id) },
                            onToggle: { toggle(s, calendar: calendar) },
                            onBeginRename: { beginRename(s) },
                            onCommitRename: commitRename,
                            onCancelRename: cancelRename,
                            onResume: { resume(s) },
                            onOpen: { file, anchor in select(s.id); onOpen(file, anchor) },
                            onHover: { inside in
                                if inside { hovered = s.id } else if hovered == s.id { hovered = nil }
                            }
                        )
                        .id(s.id)
                    }
                }
                .padding(.vertical, Theme.Space.l)
                .padding(.horizontal, Theme.Space.m)
            }
            .onChange(of: selection) { _, id in
                guard let id else { return }
                withAnimation(Theme.Motion.fast) { proxy.scrollTo(id) }
            }
        }
        .focusable()
        .focused($focus, equals: .list)
        .focusEffectDisabled()
        .onAppear { if focus == nil { focus = .list } }
        .onChange(of: focus) { old, new in
            if old == .title, new != .title, editing != nil { commitRename() }
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .space, .return, .escape]) { press in
            handle(press.key, rows: rows, calendar: calendar)
        }
        .background {
            Button("", action: resumeSelected)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(selection == nil || onResume == nil)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    // MARK: State

    private func title(of s: TrailSession) -> String? {
        if let t = titles[s.id] { return t.isEmpty ? nil : t }
        return s.title
    }

    /// Today's sessions start open, older ones closed, until the user says otherwise.
    private func isExpanded(_ s: TrailSession, calendar: Calendar) -> Bool {
        expanded[s.id] ?? calendar.isDateInToday(s.end)
    }

    private func select(_ id: UUID) {
        selection = id
        if editing == nil { focus = .list }
    }

    private func toggle(_ s: TrailSession, calendar: Calendar) {
        let open = !isExpanded(s, calendar: calendar)
        withAnimation(Theme.Motion.fast) { expanded[s.id] = open }
    }

    private func beginRename(_ s: TrailSession) {
        selection = s.id
        draft = title(of: s) ?? ""
        editing = s.id
        DispatchQueue.main.async { focus = .title }
    }

    private func commitRename() {
        guard let id = editing else { return }
        editing = nil
        focus = .list
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != (title(of: s) ?? "") else { return }
        titles[id] = t
        onRename(s, t.isEmpty ? nil : t)
    }

    private func cancelRename() {
        editing = nil
        focus = .list
    }

    private func resume(_ s: TrailSession) {
        selection = s.id
        onResume?(s)
    }

    private func resumeSelected() {
        guard let id = selection, let s = sessions.first(where: { $0.id == id }) else { return }
        resume(s)
    }

    private func handle(_ key: KeyEquivalent, rows: [TrailSession], calendar: Calendar) -> KeyPress.Result {
        guard editing == nil else { return .ignored }
        let ids = rows.map(\.id)
        let current = selection.flatMap { ids.firstIndex(of: $0) }
        let session = current.map { rows[$0] }
        switch key {
        case .downArrow, .upArrow:
            guard !ids.isEmpty else { return .ignored }
            let step = key == .downArrow ? 1 : -1
            let next = current.map { max(0, min(ids.count - 1, $0 + step)) } ?? 0
            selection = ids[next]
            return .handled
        case .rightArrow:
            guard let s = session, !isExpanded(s, calendar: calendar) else { return .ignored }
            toggle(s, calendar: calendar)
            return .handled
        case .leftArrow:
            guard let s = session, isExpanded(s, calendar: calendar) else { return .ignored }
            toggle(s, calendar: calendar)
            return .handled
        case .space:
            guard let s = session else { return .ignored }
            toggle(s, calendar: calendar)
            return .handled
        case .return:
            guard let s = session else { return .ignored }
            beginRename(s)
            return .handled
        case .escape:
            guard selection != nil else { return .ignored }
            selection = nil
            return .handled
        default:
            return .ignored
        }
    }
}

/// One session: time range, a dot on the rail, the title, and the chain.
struct SessionRow: View {
    let session: TrailSession
    let title: String?
    let range: String
    let expanded: Bool
    let selected: Bool
    let hovered: Bool
    let editing: Bool
    let topGap: CGFloat
    let isFirst: Bool
    let isLast: Bool
    let vaultRoot: URL?
    @Binding var draft: String
    var focus: FocusState<TrailTimeline.Focus?>.Binding
    let canResume: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onResume: () -> Void
    let onOpen: (FileRef, FileAnchor?) -> Void
    let onHover: (Bool) -> Void

    private typealias M = TrailMetrics

    var body: some View {
        let stops = TrailPresentation.stops(for: session)
        HStack(alignment: .top, spacing: 0) {
            gutter
            Color.clear.frame(width: M.rail, height: M.header)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                header(stops)
                    .frame(height: M.header)
                if expanded {
                    TrailChain(stops: stops, vaultRoot: vaultRoot, onOpen: onOpen)
                        .transition(.opacity)
                }
            }
        }
        .padding(.top, topGap)
        .padding(.bottom, expanded ? Theme.Space.l : 0)
        .background(alignment: .topLeading) { rail }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover(perform: onHover)
        .contextMenu {
            if canResume {
                Button("Resume", action: onResume).keyboardShortcut("r", modifiers: .command)
            }
            Button("Rename", action: onBeginRename)
            Button(expanded ? "Collapse" : "Expand", action: onToggle)
        }
    }

    private var gutter: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "chevron.right")
                .font(Theme.Font.small)
                .imageScale(.small)
                .foregroundStyle(Theme.Color.textTertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 12, height: M.header)
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggle)
            Text(range)
                .font(Theme.Font.monoSmall)
                .foregroundStyle(Theme.Color.textTertiary)
                .lineLimit(1)
                .gesture(TapGesture(count: 2).onEnded(onBeginRename))
                .simultaneousGesture(TapGesture().onEnded(onSelect))
        }
        .frame(width: M.gutter, height: M.header, alignment: .leading)
    }

    @ViewBuilder
    private func header(_ stops: [TrailStop]) -> some View {
        HStack(spacing: Theme.Space.s) {
            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.bodyMedium)
                    .focused(focus, equals: .title)
                    .onSubmit(onCommitRename)
                    .onExitCommand(perform: onCancelRename)
            } else {
                if let title {
                    Text(title)
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(Theme.Color.text)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .gesture(TapGesture(count: 2).onEnded(onBeginRename))
                        .simultaneousGesture(TapGesture().onEnded(onSelect))
                }
                if !expanded {
                    TrailCompactChain(stops: stops, onOpen: onOpen)
                } else {
                    Spacer(minLength: 0)
                }
            }
            if canResume, !editing {
                Button(action: onResume) {
                    Image(systemName: "arrow.clockwise")
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .frame(width: 20, height: M.header)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Resume")
                .opacity(hovered || selected ? 1 : 0)
                .animation(Theme.Motion.fast, value: hovered || selected)
            }
        }
    }

    /// Selection band behind the header line, then the rail: a hairline through every row
    /// that starts at the newest dot and ends at the oldest.
    private var rail: some View {
        let dotY = topGap + M.header / 2
        let x = M.gutter + M.rail / 2
        return ZStack(alignment: .topLeading) {
            if selected {
                RoundedRectangle(cornerRadius: Theme.Radius.s)
                    .fill(Theme.Color.selection)
                    .frame(height: M.header)
                    .padding(.top, topGap)
                    .padding(.horizontal, -Theme.Space.xs)
            }
            VStack(spacing: 0) {
                Rectangle().fill(isFirst ? Color.clear : Theme.Color.hairline).frame(width: 1, height: dotY)
                Rectangle().fill(isLast ? Color.clear : Theme.Color.hairline).frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
            .padding(.leading, x - 0.5)
            Circle()
                .fill(selected ? Theme.Color.accent : Theme.Color.textTertiary)
                .frame(width: M.dot, height: M.dot)
                .padding(.leading, x - M.dot / 2)
                .padding(.top, dotY - M.dot / 2)
        }
    }
}

/// The expanded chain: thumbnails joined by hairlines, wrapping like text when the window
/// is narrow. Comments sit under their file; searches sit between files.
struct TrailChain: View {
    let stops: [TrailStop]
    let vaultRoot: URL?
    let onOpen: (FileRef, FileAnchor?) -> Void

    var body: some View {
        TrailFlowLayout(spacing: TrailMetrics.gap, lineSpacing: Theme.Space.m) {
            ForEach(Array(stops.enumerated()), id: \.element.id) { i, stop in
                let links = i < stops.count - 1
                switch stop.kind {
                case let .file(file, anchor, notes):
                    TrailFileStop(file: file, anchor: anchor, notes: notes, links: links,
                                  vaultRoot: vaultRoot, onOpen: onOpen)
                case let .search(query):
                    TrailSearchStop(query: query, links: links)
                }
            }
        }
        .padding(.trailing, Theme.Space.m)
    }
}

struct TrailFileStop: View {
    let file: FileRef
    let anchor: FileAnchor?
    let notes: [TrailNote]
    let links: Bool
    let vaultRoot: URL?
    let onOpen: (FileRef, FileAnchor?) -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: TrailMetrics.gap) {
                TrailThumb(file: file, vaultRoot: vaultRoot)
                    .opacity(hover ? 1 : 0.92)
                    .onTapGesture { onOpen(file, anchor) }
                if links { Hairline() } else { Spacer(minLength: 0) }
            }
            .frame(height: TrailMetrics.thumb)
            Text(file.name)
                .font(Theme.Font.small)
                .foregroundStyle(hover ? Theme.Color.text : Theme.Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(file.relativePath)
                .onTapGesture { onOpen(file, anchor) }
            ForEach(notes) { note in
                TrailNoteText(note: note)
                    .padding(.leading, Theme.Space.s)
                    .padding(.top, Theme.Space.xs)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(file, note.anchor ?? anchor) }
            }
        }
        .frame(width: notes.isEmpty ? TrailMetrics.fileColumn : TrailMetrics.notedColumn, alignment: .leading)
        .onHover { hover = $0 }
        .animation(Theme.Motion.fast, value: hover)
    }
}

struct TrailSearchStop: View {
    let query: String
    let links: Bool

    var body: some View {
        HStack(spacing: TrailMetrics.gap) {
            Text("⌕ \(query)")
                .font(Theme.Font.monoSmall)
                .foregroundStyle(Theme.Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: TrailMetrics.searchMax, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            if links { Hairline().frame(width: TrailMetrics.searchLink) }
        }
        .frame(height: TrailMetrics.thumb)
    }
}

/// A comment as the user wrote it: anchor in mono, wikilinks in the accent.
struct TrailNoteText: View {
    let note: TrailNote

    var body: some View {
        Text(attributed)
            .lineLimit(6)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        var text = AttributedString()
        if let a = note.anchor {
            var chip = AttributedString("\(a.kind.rawValue) \(a.value)  ")
            chip.font = Theme.Font.monoSmall
            chip.foregroundColor = Theme.Color.textTertiary
            text += chip
        }
        for seg in TrailPresentation.segments(note.text) {
            var run = AttributedString(seg.text)
            run.font = Theme.Font.body
            run.foregroundColor = seg.isLink ? Theme.Color.accent : Theme.Color.text
            text += run
        }
        return text
    }
}

/// The collapsed line: glyphs and names, joined by short hairlines, fading out at the edge.
struct TrailCompactChain: View {
    let stops: [TrailStop]
    let onOpen: (FileRef, FileAnchor?) -> Void

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(Array(stops.prefix(24).enumerated()), id: \.element.id) { i, stop in
                if i > 0 { Hairline().frame(width: Theme.Space.s) }
                switch stop.kind {
                case let .file(file, anchor, _):
                    HStack(spacing: Theme.Space.xs) {
                        FileGlyph(ext: file.ext, size: 11)
                        Text(file.name)
                            .font(Theme.Font.small)
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(file, anchor) }
                case let .search(query):
                    Text("⌕ \(query)")
                        .font(Theme.Font.monoSmall)
                        .foregroundStyle(Theme.Color.textTertiary)
                        .fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .mask {
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Theme.Space.xl)
            }
        }
    }
}

/// A Quick Look thumbnail, or the file's glyph when there isn't one.
struct TrailThumb: View {
    let file: FileRef
    let vaultRoot: URL?
    @Environment(\.displayScale) private var scale
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image, image.size.width > 0, image.size.height > 0 {
                let aspect = image.size.width / image.size.height
                let w = min(TrailMetrics.thumbMaxWidth, TrailMetrics.thumb * aspect)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: w, height: w / aspect)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.Color.hairline, lineWidth: 1))
                    .frame(height: TrailMetrics.thumb)
            } else {
                FileGlyph(ext: file.ext, size: 18)
                    .frame(width: TrailMetrics.thumb, height: TrailMetrics.thumb)
            }
        }
        .task(id: file.relativePath) {
            guard let root = vaultRoot else { return }
            let url = root.appendingPathComponent(file.relativePath)
            let side = TrailMetrics.thumbMaxWidth
            if let hit = TrailThumbnails.shared.cached(url, side: side) { image = hit; return }
            image = await TrailThumbnails.shared.image(for: url, side: side, scale: scale)
        }
    }
}

/// Left-to-right, wrapping to a new line when the next item doesn't fit.
struct TrailFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = arrange(subviews, width: width)
        let h = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1))
        let w = lines.map(\.width).max() ?? 0
        return CGSize(width: proposal.width.map { min($0, w) } ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for (i, size) in zip(line.items, line.sizes) {
                subviews[i].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line { var items: [Int] = []; var sizes: [CGSize] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let needed = line.items.isEmpty ? size.width : line.width + spacing + size.width
            if !line.items.isEmpty, needed > width {
                lines.append(line)
                line = Line()
            }
            line.width = line.items.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.items.append(i)
            line.sizes.append(size)
        }
        if !line.items.isEmpty { lines.append(line) }
        return lines
    }
}
