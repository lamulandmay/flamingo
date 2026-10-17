import AppKit
import SwiftUI
import QuickLookThumbnailing
import FlamingoCore
import FlamingoDesign

/// Connect mode (⌘J, or the grid button top right): the files you're working with as tiles
/// that quiver, waiting to be joined. Click a file, then another, and they're connected; keep
/// clicking and each file joins the same connection, every pair linked. Click a picked file
/// to take it back out. Click empty space or press Return to start the next connection, and
/// Esc to leave. Typing finds any file in the vault, and Return picks the top match.
struct ConnectGrid: View {
    @EnvironmentObject var state: AppState
    @State private var query = ""
    /// What shows before you type: the open file, tabs, where you've been, this folder.
    @State private var working: [FileRef] = []
    @State private var found: [FileRef] = []
    @State private var searchTask: Task<Void, Never>?
    /// The connection being made, in the order its files were picked.
    @State private var group: [FileRef] = []
    /// Pairs this connection created, so taking a file out removes only those.
    @State private var made: [ManualConnection] = []
    /// How far each picked file's line has drawn, 0 to 1.
    @State private var drawn: [FileRef: CGFloat] = [:]
    /// The last connection made, named in the footer until the next pick.
    @State private var finished: [FileRef] = []

    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private var tiles: [FileRef] {
        let base = query.isEmpty ? working : found
        return group.filter { !base.contains($0) } + base
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: Theme.Size.icon))
                    .foregroundStyle(Theme.Color.textTertiary)
                CommandField(text: $query, label: "Find a file", fontSize: 15) { command($0) }
                IconButton("xmark", help: "Done") { close() }
            }
            .padding(.horizontal, Theme.Space.l)
            .frame(height: 44)
            Hairline()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 156), spacing: Theme.Space.m)],
                          spacing: Theme.Space.l) {
                    ForEach(tiles, id: \.self) { file in
                        ConnectTile(file: file, url: state.vault?.url(for: file), picked: group.contains(file), moving: !reduceMotion)
                            .anchorPreference(key: TileBounds.self, value: .bounds) { [file: $0] }
                            .onTapGesture { toggle(file) }
                    }
                }
                .padding(Theme.Space.xl)
                // Behind the tiles, so a line runs between them like a thread under cards.
                .backgroundPreferenceValue(TileBounds.self) { bounds in
                    GeometryReader { proxy in lines(bounds, in: proxy) }
                        .allowsHitTesting(false)
                }
            }
            .background(Color.clear.contentShape(Rectangle()).onTapGesture(perform: finish))
            if !group.isEmpty || !finished.isEmpty {
                Hairline()
                footer.frame(height: 36).padding(.horizontal, Theme.Space.l)
            }
        }
        .background(Theme.Color.bg)
        .onExitCommand(perform: close)
        .onAppear { working = Self.workingSet(state) }
        .onChange(of: query) { search() }
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: Lines

    /// Two files: one line between them. More: a line from each to a hub at their middle.
    @ViewBuilder private func lines(_ bounds: [FileRef: Anchor<CGRect>], in proxy: GeometryProxy) -> some View {
        let points = group.compactMap { f in bounds[f].map { (file: f, at: CGPoint(x: proxy[$0].midX, y: proxy[$0].midY)) } }
        if points.count >= 2 {
            let hub: CGPoint? = points.count == 2 ? nil : CGPoint(
                x: points.map(\.at.x).reduce(0, +) / CGFloat(points.count),
                y: points.map(\.at.y).reduce(0, +) / CGFloat(points.count))
            ZStack {
                ForEach(Array(points.enumerated()), id: \.element.file) { i, p in
                    if let to = hub ?? (i == 1 ? points[0].at : nil) {
                        Thread(from: p.at, to: to)
                            .trim(from: 0, to: drawn[p.file] ?? 1)
                            .stroke(Theme.Color.thought(1), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                }
                if let hub {
                    Circle().fill(Theme.Color.thought(1)).frame(width: 9, height: 9).position(hub)
                }
            }
        }
    }

    private var footer: some View {
        let files = group.isEmpty ? finished : group
        return HStack(spacing: Theme.Space.s) {
            ForEach(Array(files.enumerated()), id: \.element) { i, f in
                if i > 0 {
                    Rectangle().fill(Theme.Color.thought(1)).frame(width: 14, height: 1.5)
                }
                HStack(spacing: Theme.Space.xs) {
                    FileGlyph(ext: f.ext, size: Theme.Size.iconSmall)
                    Text(f.name).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .font(Theme.Font.small)
        .foregroundStyle(group.isEmpty ? Theme.Color.textTertiary : Theme.Color.textSecondary)
    }

    // MARK: Picking

    private func toggle(_ file: FileRef) {
        if group.contains(file) { return remove(file) }
        finished = []
        group.append(file)
        guard group.count > 1 else { Chime.depart(); return }
        // Inserted at nothing drawn, then drawn on the next pass, so the line visibly travels.
        drawn[file] = 0
        DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.32)) { drawn[file] = 1 } }
        made += state.connect(group)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Chime.arrive(level: 1) }
    }

    private func remove(_ file: FileRef) {
        withAnimation(Theme.Motion.fast) { group.removeAll { $0 == file } }
        drawn[file] = nil
        let mine = made.filter { $0.source == file.relativePath || $0.target == file.relativePath }
        for c in mine { state.disconnect(FileRef(relativePath: c.source), FileRef(relativePath: c.target)) }
        made.removeAll { mine.contains($0) }
    }

    /// Ends this connection; the next pick starts another.
    private func finish() {
        guard !group.isEmpty else { return }
        finished = group.count > 1 ? group : []
        withAnimation(Theme.Motion.normal) { group = []; drawn = [:] }
        made = []
    }

    private func close() {
        finish()
        state.connectGridShown = false
    }

    private func command(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if query.isEmpty { finish() }
            else if let top = found.first(where: { !group.contains($0) }) { toggle(top); query = "" }
            else { NSSound.beep() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if query.isEmpty { close() } else { query = "" }
            return true
        default:
            return false
        }
    }

    // MARK: Files

    static func workingSet(_ state: AppState) -> [FileRef] {
        let limit = 48
        var seen = Set<FileRef>(), out: [FileRef] = []
        func add(_ f: FileRef?) {
            if let f, out.count < limit, state.fileSet.contains(f), seen.insert(f).inserted { out.append(f) }
        }
        add(state.selected)
        state.openFiles.reversed().forEach(add)
        state.history.entries.reversed().forEach { add($0.file) }
        // The folder on screen: the deepest column when no file is open, else the sidebar's.
        var folder = state.selectedFolder ?? state.selected?.directory ?? ""
        if state.mode == .files, state.selected == nil, let shown = state.browser.folder, let v = state.vault {
            folder = v.relativePath(of: shown) ?? ""
        }
        for f in state.files where f.directory == folder {
            add(f)
            if out.count >= limit { break }
        }
        return out
    }

    private func search() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { found = []; return }
        let files = state.files
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { Self.match(q, in: files) }.value
            if !Task.isCancelled { found = result }
        }
    }

    /// Names that start with the query, then contain it, then contain every word of it,
    /// then paths that do; shorter paths first within each.
    nonisolated static func match(_ query: String, in files: [FileRef], limit: Int = 48) -> [FileRef] {
        let words = query.split(separator: " ").map(String.init)
        var hits: [(rank: Int, length: Int, file: FileRef)] = []
        for (i, f) in files.enumerated() {
            if i % 8192 == 0, Task.isCancelled { return [] }
            let name = f.name
            let rank: Int
            if name.range(of: query, options: [.caseInsensitive, .anchored]) != nil { rank = 0 }
            else if name.range(of: query, options: .caseInsensitive) != nil { rank = 1 }
            else if words.count > 1, words.allSatisfy({ name.range(of: $0, options: .caseInsensitive) != nil }) { rank = 2 }
            else if words.allSatisfy({ f.relativePath.range(of: $0, options: .caseInsensitive) != nil }) { rank = 3 }
            else { continue }
            hits.append((rank, f.relativePath.utf8.count, f))
        }
        return hits.sorted { ($0.rank, $0.length) < ($1.rank, $1.length) }.prefix(limit).map(\.file)
    }
}

private struct TileBounds: PreferenceKey {
    static let defaultValue: [FileRef: Anchor<CGRect>] = [:]
    static func reduce(value: inout [FileRef: Anchor<CGRect>], nextValue: () -> [FileRef: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// A line with a slight sag, like a thread drawn between two pins.
private struct Thread: Shape {
    var from: CGPoint
    var to: CGPoint

    func path(in rect: CGRect) -> Path {
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let length = hypot(to.x - from.x, to.y - from.y)
        var p = Path()
        p.move(to: from)
        p.addQuadCurve(to: to, control: CGPoint(x: mid.x, y: mid.y + length * 0.12))
        return p
    }
}

/// One file in the grid. Waiting tiles quiver, each out of step with the next; a picked one
/// holds still and breathes in the accent.
private struct ConnectTile: View {
    let file: FileRef
    let url: URL?
    let picked: Bool
    let moving: Bool
    @State private var phase = Double.random(in: 0..<(2 * .pi))
    @State private var thumbnail: NSImage?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let quiver = moving && !picked
            TileFace(file: file, thumbnail: thumbnail, picked: picked)
                .rotationEffect(.degrees(quiver ? 1.4 * sin(t * 2 * .pi / 0.28 + phase) : 0))
                .offset(y: quiver ? 0.6 * cos(t * 2 * .pi / 0.34 + phase) : 0)
                .scaleEffect(picked ? 1.04 + (moving ? 0.025 * sin(t * 2 * .pi / 1.1) : 0) : 1)
                .shadow(color: picked ? Theme.Color.thought(1).opacity(0.45) : .clear, radius: picked ? 10 : 0)
        }
        .contentShape(Rectangle())
        .help(file.relativePath)
        .task(id: file) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        guard let url else { return }
        if let cached = ThumbnailCache.shared.object(forKey: url.path as NSString) { thumbnail = cached; return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 76), scale: scale,
                                                   representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
              !Task.isCancelled else { return }
        ThumbnailCache.shared.setObject(rep.nsImage, forKey: url.path as NSString)
        thumbnail = rep.nsImage
    }
}

/// The still part of a tile, kept apart so the quiver redraws only a transform.
private struct TileFace: View {
    let file: FileRef
    let thumbnail: NSImage?
    let picked: Bool

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            ZStack {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(Squircle(radius: 3))
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                } else {
                    FileGlyph(ext: file.ext, size: 34)
                }
            }
            .frame(width: 96, height: 76)
            Text(file.name)
                .font(Theme.Font.small)
                .foregroundStyle(Theme.Color.text)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(Theme.Space.s)
        .frame(width: 128)
        // Opaque, so the lines behind run between tiles, not across them.
        .background(ZStack {
            Squircle(radius: Theme.Radius.m).fill(Theme.Color.bg)
            Squircle(radius: Theme.Radius.m).fill(picked ? Theme.Color.selection : .clear)
        })
        .overlay(Squircle(radius: Theme.Radius.m).strokeBorder(Theme.Color.thought(1), lineWidth: picked ? 1.5 : 0))
    }
}
