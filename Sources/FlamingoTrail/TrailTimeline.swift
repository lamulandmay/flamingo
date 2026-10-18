import SwiftUI
import FlamingoCore
import FlamingoDesign

enum TrailMetrics {
    static let header: CGFloat = Theme.Size.row
    static let chevron: CGFloat = 12
    static let rail: CGFloat = 20
    static let dot: CGFloat = 5
    static let thumb: CGFloat = 32
    static let thumbMaxWidth: CGFloat = 48
    static let fileColumn: CGFloat = 112
    static let notedColumn: CGFloat = 212
    static let searchMax: CGFloat = 168
    static let searchLink: CGFloat = 16
    static let gap: CGFloat = Theme.Space.s
    /// A glyph standing in for a thumbnail sits a notch above row icons.
    static let thumbGlyph: CGFloat = Theme.Size.icon + Theme.Space.xs

    /// Wide enough for the longest time range on screen, so the rail is one straight line.
    static func gutter(for ranges: [String]) -> CGFloat {
        let widest = ranges.reduce(0) { w, r in
            max(w, (r as NSString).size(withAttributes: [.font: Theme.NS.monoSmall]).width)
        }
        return (chevron + Theme.Space.xs + widest + Theme.Space.m).rounded(.up)
    }
}

/// The list: newest session on top, one row each, a hairline rail on the left joining them.
struct TrailTimeline: View {
    var sessions: [TrailSession]
    var vaultRoot: URL?
    var showsPaused: Bool
    var onOpen: (FileRef, FileAnchor?) -> Void
    var onResume: ((TrailSession) -> Void)?
    /// Nil when there is nowhere to save a name; renaming is then off.
    var onRename: ((TrailSession, String?) -> Void)?
    var renameRevision: Int = 0
    var isFiltered = false
    var previousSessionNames: [UUID: String] = [:]
    var correctionBusy = false
    var onCorrection: ((TrailSession, TrailCorrectionAction) -> Void)?

    enum Focus: Hashable { case list, title }

    @State private var selection: UUID?
    @State private var expanded: [UUID: Bool] = [:]
    @State private var titles: [UUID: String] = [:]   // set by rename before the store reloads; "" clears
    @State private var editing: UUID?
    @State private var draft = ""
    @FocusState private var focus: Focus?

    private struct Row: Identifiable {
        var session: TrailSession
        var range: String
        var topGap: CGFloat
        var isFirst: Bool
        var isLast: Bool
        var id: UUID { session.id }
    }

    private func rows(now: Date, calendar: Calendar) -> [Row] {
        let ordered = sessions.sorted {
            $0.start != $1.start ? $0.start > $1.start : $0.id.uuidString < $1.id.uuidString
        }
        return ordered.enumerated().map { i, s in
            Row(session: s,
                range: TrailPresentation.timeRange(start: s.start, end: s.end, now: now, calendar: calendar),
                topGap: i > 0 && !calendar.isDate(ordered[i - 1].start, inSameDayAs: s.start) ? Theme.Space.l : 0,
                isFirst: i == 0,
                isLast: i == ordered.count - 1)
        }
    }

    var body: some View {
        let calendar = Calendar.current
        let rows = rows(now: Date(), calendar: calendar)
        Group {
            if rows.isEmpty {
                if showsPaused { EmptyState("Trail paused — enable recording in Settings") }
                else if isFiltered { EmptyState("No sessions match this search") }
                else { EmptyState("Your work will appear here as you open, edit, search and comment on files") }
            } else {
                list(rows, calendar: calendar)
            }
        }
        .background(Theme.Color.bg)
        .onChange(of: renameRevision) { _, _ in titles = [:] }
        .onChange(of: sessions) { _, updated in
            for session in updated where titles[session.id] == (session.title ?? "") { titles[session.id] = nil }
        }
    }

    private func list(_ rows: [Row], calendar: Calendar) -> some View {
        let gutter = TrailMetrics.gutter(for: rows.map(\.range))
        let ordered = rows.map(\.session)
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        let s = row.session
                        SessionRow(
                            session: s,
                            title: title(of: s),
                            range: row.range,
                            gutter: gutter,
                            expanded: isExpanded(s, calendar: calendar),
                            selected: selection == s.id,
                            active: focus != nil,
                            editing: editing == s.id,
                            topGap: row.topGap,
                            isFirst: row.isFirst,
                            isLast: row.isLast,
                            vaultRoot: vaultRoot,
                            draft: $draft,
                            focus: $focus,
                            canResume: onResume != nil,
                            canRename: onRename != nil,
                            onSelect: { select(s.id) },
                            onToggle: { toggle(s, calendar: calendar) },
                            onBeginRename: { beginRename(s) },
                            onCommitRename: { commitRename(restoreFocus: true) },
                            onCancelRename: cancelRename,
                            onResume: { resume(s) },
                            onOpen: { file, anchor in select(s.id); onOpen(file, anchor) },
                            previousSessionName: previousSessionNames[s.id],
                            correctionBusy: correctionBusy,
                            onCorrection: onCorrection.map { action in { action(s, $0) } }
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
        .onDisappear { if editing != nil { commitRename(restoreFocus: false) } }
        .onChange(of: focus) { old, new in
            // Focus went somewhere else: keep the name, and leave focus where the user put it.
            if old == .title, new != .title, editing != nil { commitRename(restoreFocus: false) }
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .space, .return, .escape]) { press in
            handle(press.key, ordered: ordered, calendar: calendar)
        }
        .background {
            Button("", action: resumeSelected)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(selection == nil || onResume == nil || editing != nil)
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
        guard onRename != nil else { return }
        if editing != nil, editing != s.id { commitRename(restoreFocus: false) }
        selection = s.id
        draft = title(of: s) ?? ""
        editing = s.id
        DispatchQueue.main.async { focus = .title }
    }

    private func commitRename(restoreFocus: Bool) {
        guard let id = editing else { return }
        editing = nil
        if restoreFocus { focus = .list }
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != (title(of: s) ?? "") else { return }
        titles[id] = t
        onRename?(s, t.isEmpty ? nil : t)
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

    private func handle(_ key: KeyEquivalent, ordered: [TrailSession], calendar: Calendar) -> KeyPress.Result {
        guard editing == nil else { return .ignored }
        let current = selection.flatMap { id in ordered.firstIndex { $0.id == id } }
        let session = current.map { ordered[$0] }
        switch key {
        case .downArrow, .upArrow:
            guard !ordered.isEmpty else { return .ignored }
            let step = key == .downArrow ? 1 : -1
            let next = current.map { max(0, min(ordered.count - 1, $0 + step)) } ?? 0
            selection = ordered[next].id
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
    let gutter: CGFloat
    let expanded: Bool
    let selected: Bool
    /// The list (or the title field) has keyboard focus. Selection is coral only then.
    let active: Bool
    let editing: Bool
    let topGap: CGFloat
    let isFirst: Bool
    let isLast: Bool
    let vaultRoot: URL?
    @Binding var draft: String
    var focus: FocusState<TrailTimeline.Focus?>.Binding
    let canResume: Bool
    let canRename: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void
    let onResume: () -> Void
    let onOpen: (FileRef, FileAnchor?) -> Void
    var previousSessionName: String? = nil
    var correctionBusy = false
    var onCorrection: ((TrailCorrectionAction) -> Void)? = nil
    @State private var hovered = false

    private typealias M = TrailMetrics

    var body: some View {
        let stops = TrailPresentation.stops(for: session)
        HStack(alignment: .top, spacing: 0) {
            gutterView
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
        .onHover { hovered = $0 }
        .contextMenu {
            if canResume {
                Button("Resume", action: onResume).keyboardShortcut("r", modifiers: .command)
            }
            if canRename { Button("Rename", action: onBeginRename) }
            Button(expanded ? "Collapse" : "Expand", action: onToggle)
            if onCorrection != nil { Divider(); correctionItems }
        }
    }

    private var gutterView: some View {
        HStack(spacing: Theme.Space.xs) {
            Button(action: onToggle) { Image(systemName: "chevron.right")
                .font(Theme.Font.small)
                .imageScale(.small)
                .foregroundStyle(Theme.Color.textTertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: M.chevron, height: M.header)
                .contentShape(Rectangle())
            }.buttonStyle(.press).accessibilityLabel(expanded ? "Collapse session" : "Expand session")
            Text(range)
                .font(Theme.Font.monoSmall)
                .foregroundStyle(Theme.Color.textTertiary)
                .lineLimit(1)
                .fixedSize()
                .gesture(TapGesture(count: 2).onEnded(onBeginRename))
                .simultaneousGesture(TapGesture().onEnded(onSelect))
        }
        .frame(width: gutter, height: M.header, alignment: .leading)
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
            // Actions appear on hover or selection; at rest the row is just the session.
            HStack(spacing: 0) {
                if canResume, !editing {
                    if canRename { IconButton("pencil", help: "Name Session", action: onBeginRename) }
                    IconButton("arrow.uturn.backward", help: "Resume", action: onResume)
                }
                if onCorrection != nil, !editing {
                    Menu { correctionItems } label: {
                        Image(systemName: "ellipsis").font(.system(size: Theme.Size.iconSmall))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .tint(Theme.Color.textSecondary)
                    .fixedSize()
                    .frame(width: 24, height: 24)
                    .help("Session")
                    .accessibilityLabel("Session corrections")
                    .disabled(correctionBusy)
                }
            }
            .opacity(hovered || selected ? 1 : 0)
            .animation(Theme.Motion.fast, value: hovered || selected)
            if session.excludesInferredConnections {
                Image(systemName: "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textTertiary)
                    .help("Not used for suggested connections")
                    .accessibilityLabel("Not used for suggested connections")
            }
        }
    }

    @ViewBuilder private var correctionItems: some View {
        Button(session.excludesInferredConnections ? "Use for Suggested Connections" : "Don't Use for Suggested Connections") {
            onCorrection?(.excluded(!session.excludesInferredConnections))
        }
        .disabled(correctionBusy)
        if !session.correctionStops.isEmpty {
            Menu("Split before stop") {
                ForEach(session.correctionStops) { stop in
                    Button(stop.label) { onCorrection?(.splitBefore(stop.id)) }
                }
            }.disabled(correctionBusy)
        }
        if let previousSessionName {
            Button("Merge with previous: " + previousSessionName) { onCorrection?(.mergePrevious) }
                .disabled(correctionBusy)
        }
        if session.hasGroupingCorrection {
            Button("Use automatic grouping") { onCorrection?(.automaticGrouping) }.disabled(correctionBusy)
        }
    }

    /// Selection band behind the header line, then the rail: a hairline through every row
    /// that starts at the newest dot and ends at the oldest.
    private var rail: some View {
        let dotY = topGap + M.header / 2
        let x = gutter + M.rail / 2
        return ZStack(alignment: .topLeading) {
            if selected {
                Squircle(radius: Theme.Radius.s)
                    .fill(active ? Theme.Color.selection : Theme.Color.hover)
                    .frame(height: M.header)
                    .padding(.top, topGap)
                    .padding(.horizontal, -Theme.Space.xs)
            }
            VStack(spacing: 0) {
                VHairline().frame(height: dotY).opacity(isFirst ? 0 : 1)
                VHairline().frame(maxHeight: .infinity).opacity(isLast ? 0 : 1)
            }
            .padding(.leading, x - Theme.Size.hairline / 2)
            Circle()
                .fill(selected && active ? Theme.Color.accent : Theme.Color.textTertiary)
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
                    .pressFeedback(shade: nil)
                    .onTapGesture { onOpen(file, anchor) }
                if links { Hairline() } else { Spacer(minLength: 0) }
            }
            .frame(height: TrailMetrics.thumb)
            Button { onOpen(file, anchor) } label: { Text(file.name)
                .font(Theme.Font.small)
                .foregroundStyle(hover ? Theme.Color.text : Theme.Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(file.relativePath)
            }.buttonStyle(.press(shade: nil)).accessibilityLabel("Open " + file.relativePath)
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 3) {
                    Button(note.anchor?.label ?? "Open note location") { onOpen(file, note.anchor ?? anchor) }
                        .font(.caption).buttonStyle(.press(shade: nil)).foregroundStyle(Theme.Color.textSecondary)
                    TrailNoteText(note: note, source: file)
                }
                .padding(.leading, Theme.Space.s)
                .padding(.top, Theme.Space.xs)
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
    var source: FileRef? = nil
    @Environment(\.trailOpenLink) private var openLink

    var body: some View {
        TrailRichText(note: note, source: source, onOpenLink: openLink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                        FileGlyph(ext: file.ext, size: Theme.Size.iconSmall)
                        Text(file.name)
                            .font(Theme.Font.small)
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                    .pressFeedback(shade: Theme.Radius.s)
                    .onTapGesture { onOpen(file, anchor) }
                case let .search(query):
                    Text("⌕ \(query)")
                        .font(Theme.Font.monoSmall)
                        .foregroundStyle(Theme.Color.textTertiary)
                        .fixedSize()
                }
            }
        }
        // minWidth 0 lets the title beside it win; the chain clips instead.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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

    init(file: FileRef, vaultRoot: URL?) {
        self.file = file
        self.vaultRoot = vaultRoot
        // Rows are recreated as the list scrolls; start from the cache so they don't flash.
        if let root = vaultRoot {
            _image = State(initialValue: TrailThumbnails.shared.cached(root.appendingPathComponent(file.relativePath),
                                                                      side: TrailMetrics.thumbMaxWidth))
        }
    }

    var body: some View {
        Group {
            if let image, image.size.width > 0, image.size.height > 0 {
                let aspect = image.size.width / image.size.height
                let w = min(TrailMetrics.thumbMaxWidth, TrailMetrics.thumb * aspect)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: w, height: w / aspect)
                    .clipShape(Squircle(radius: Theme.Radius.s - 2))
                    .overlay(Squircle(radius: Theme.Radius.s - 2)
                        .stroke(Theme.Color.hairline, lineWidth: Theme.Size.hairline))
                    .frame(height: TrailMetrics.thumb)
            } else {
                FileGlyph(ext: file.ext, size: TrailMetrics.thumbGlyph)
                    .frame(width: TrailMetrics.thumb, height: TrailMetrics.thumb)
            }
        }
        .task(id: thumbnailVersion) {
            // Quick Look's audio "thumbnail" is a generic note; the family glyph says more.
            guard let root = vaultRoot, !FileFamily.audio.contains(file.ext) else { return }
            let url = root.appendingPathComponent(file.relativePath)
            image = await TrailThumbnails.shared.image(for: url, side: TrailMetrics.thumbMaxWidth, scale: scale)
        }
    }

    private var thumbnailVersion: String {
        guard let vaultRoot else { return file.relativePath }
        let url = vaultRoot.appendingPathComponent(file.relativePath)
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return url.path + "|" + String(date?.timeIntervalSinceReferenceDate ?? 0)
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
            if !line.items.isEmpty, line.width + spacing + size.width > width {
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
