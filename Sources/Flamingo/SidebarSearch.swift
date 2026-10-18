import SwiftUI
import AppKit
import FlamingoCore
import FlamingoDesign
import FlamingoIndex

/// The search tab's state: the query, its results grouped by file, and how they show.
/// Lives on `AppState` so a search survives switching tabs. Plan 01 owns.
@MainActor
final class SidebarSearchModel: ObservableObject {
    /// `path:Documents/work/ clamp` searches for "clamp" in that folder only.
    static let folderPrefix = "path:"

    enum Sort: String, CaseIterable {
        case relevance, nameAscending, nameDescending
        var title: String {
            switch self {
            case .relevance: "Relevance"
            case .nameAscending: "File name (A to Z)"
            case .nameDescending: "File name (Z to A)"
            }
        }
    }

    struct Group: Identifiable {
        let file: FileRef
        let hits: [SearchHit]
        var isDirectory = false
        var coverage: String? = nil
        var result: UnifiedSearchResult { .init(file: file, isDirectory: isDirectory, hits: hits, score: 0, modified: nil, coverage: coverage) }
        var id: String { file.relativePath }
        /// Ids unique across files: one lazy stack holds every group's rows.
        var rows: [(id: String, hit: SearchHit)] { hits.enumerated().map { (id + "#" + String($0.offset), $0.element) } }
    }

    @Published var query = "" { didSet { if query != oldValue { schedule() } } }
    @Published private(set) var groups: [Group] = []
    @Published private(set) var total = 0
    @Published private(set) var searching = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var filters: [String] = []
    /// Files whose matches are folded away; with `collapseResults`, files that are open.
    @Published var toggled: Set<FileRef> = []
    @Published var collapseResults = false { didSet { toggled = [] } }
    @Published var sort = Sort.relevance { didSet { regroup() } }
    /// Bumped to put the cursor in the field.
    @Published private(set) var focusToken = 0

    /// Runs a search; set by `AppState`.
    var run: ((String, String?) async throws -> [SearchHit])?
    var runUnified: ((String) async throws -> UnifiedSearchResponse)?
    /// What the last search found, best first; ↩ hands them to the results list.
    private(set) var unifiedResults: [UnifiedSearchResult]?
    private var hits: [SearchHit] = []
    private var task: Task<Void, Never>?

    func focus() { focusToken &+= 1 }

    func reset() {
        task?.cancel()
        query = ""
        hits = []
        unifiedResults = nil
        notice = nil; filters = []
        toggled = []
        regroup()
    }

    func isOpen(_ file: FileRef) -> Bool { collapseResults == toggled.contains(file) }

    func toggle(_ file: FileRef) {
        if toggled.contains(file) { toggled.remove(file) } else { toggled.insert(file) }
    }

    /// The query without its `path:` term, and that folder.
    static func split(_ query: String) -> (text: String, folder: String?) {
        let pattern = #"(?:^|\s)path:(?:"((?:\\.|[^"])*)"|'([^']*)'|(\S+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)) else {
            return (query.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        let ns = query as NSString
        let index = (1...3).first { match.range(at: $0).location != NSNotFound }!
        let folder = ns.substring(with: match.range(at: index)).replacingOccurrences(of: #"\""#, with: "\"")
            .replacingOccurrences(of: #"\\"#, with: "\\").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (ns.replacingCharacters(in: match.range, with: "").trimmingCharacters(in: .whitespacesAndNewlines), folder)
    }

    static func scopedQuery(folder: String, text: String = "") -> String {
        let escaped = folder.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "path:\"\(escaped)\" \(text)"
    }

    /// Re-run after files change. A hidden pane, or an empty query, waits: the watcher
    /// fires every few seconds on a whole disk, and each run is a full search.
    func refresh() {
        guard isShown, !query.trimmingCharacters(in: .whitespaces).isEmpty else { stale = true; return }
        schedule()
    }

    /// Set by the pane as it comes and goes.
    var isShown = false { didSet { if isShown, stale { stale = false; schedule() } } }
    private var stale = false

    private func schedule() {
        task?.cancel()
        let raw = query
        let parsed = UnifiedSearchQuery(raw: raw)
        filters = parsed.summary
        searching = true; error = nil; notice = nil
        task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                guard let self else { return }
                if let runUnified = self.runUnified {
                    let response = try await runUnified(raw)
                    guard !Task.isCancelled else { return }
                    self.unifiedResults = response.results
                    self.notice = response.notice
                    self.hits = response.results.flatMap(\.hits)
                } else if let run = self.run {
                    let found = try await run(parsed.text, parsed.folder)
                    guard !Task.isCancelled else { return }
                    self.unifiedResults = nil; self.hits = found
                }
                self.searching = false; self.toggled = []; self.regroup()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.error = "Search unavailable: " + error.localizedDescription
                self.searching = false; self.unifiedResults = nil; self.hits = []; self.regroup()
            }
        }
    }

    private func regroup() {
        if var results = unifiedResults {
            switch sort {
            case .relevance: break
            case .nameAscending: results.sort { $0.file.name.localizedStandardCompare($1.file.name) == .orderedAscending }
            case .nameDescending: results.sort { $0.file.name.localizedStandardCompare($1.file.name) == .orderedDescending }
            }
            groups = results.map { Group(file: $0.file, hits: $0.hits, isDirectory: $0.isDirectory, coverage: $0.coverage) }
            total = results.count
            return
        }
        var order: [FileRef] = []
        var byFile: [FileRef: [SearchHit]] = [:]
        for h in hits {
            if byFile[h.file] == nil { order.append(h.file) }
            byFile[h.file, default: []].append(h)
        }
        switch sort {
        case .relevance: break
        case .nameAscending: order.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDescending: order.sort { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        }
        groups = order.map { Group(file: $0, hits: byFile[$0]!) }
        total = hits.count
    }
}

/// Obsidian's search pane: a field, the result count, and every match under its file.
/// Click a file to open it, a match to open the file at that slide, page or moment.
struct SidebarSearchPane: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var model: SidebarSearchModel
    @FocusState private var focused: Bool
    /// The result whose name is being edited (right-click ▸ Rename…).
    @State private var renaming: FileRef?

    var body: some View {
        VStack(spacing: 0) {
            PaneActions {
                IconButton("arrow.up.left.and.arrow.down.right", help: "Open in Search") {
                    PaletteController.shared.showQuery(model.query, state: state)
                }
                IconButton("rectangle.compress.vertical", help: model.collapseResults ? "Expand results" : "Collapse results",
                           isOn: model.collapseResults) { model.collapseResults.toggle() }
                IconMenu(systemName: "arrow.up.arrow.down", help: "Change sort order") {
                    ForEach(SidebarSearchModel.Sort.allCases, id: \.self) { sort in
                        Toggle(sort.title, isOn: Binding(get: { model.sort == sort }, set: { if $0 { model.sort = sort } }))
                    }
                }
                IconButton("bookmark", help: "Bookmark this search") { state.bookmarkSearch(model.query) }
                    .disabled(model.query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            SidebarSearchInput(text: $model.query, focused: $focused, focusToken: model.focusToken,
                        onSubmit: { state.submitSidebarSearch() },
                        onExit: { focused = false; state.focusSidebar?() })
                .padding(.horizontal, Theme.Space.s)
                .padding(.bottom, Theme.Space.s)
            if let folder = SidebarSearchModel.split(model.query).folder {
                Label(folder.isEmpty ? "Workspace" : folder, systemImage: "folder")
                    .font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary).lineLimit(2).padding(.horizontal, 12).padding(.bottom, 8)
            }
            if let error = model.error {
                Text(error).font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary).padding(12)
                Button("Retry") { model.refresh() }
            }
            if model.error == nil {
                HStack {
                    Text(model.searching && model.total == 0 ? "Searching…" : model.total == 1 ? "1 result" : "\(model.total) results")
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.Color.textTertiary)
                    Spacer()
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.bottom, Theme.Space.xs)
                if model.total >= 300 {
                    Text("Top 300").font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary).padding(.horizontal, 12)
                } else if !model.searching, model.total == 0, model.error == nil {
                    Text("No matches").font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary).padding(12)
                }
            }
            if let notice = model.notice {
                Text(notice).font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary).padding(Theme.Space.s)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.groups) { group in
                        ResultFile(group: group, open: model.isOpen(group.file),
                                   toggle: { withAnimation(Theme.Motion.fast) { model.toggle(group.file) } },
                                   select: { state.openSearchResult(group.result, query: model.query) },
                                   renaming: renaming == group.file, endRename: { if renaming == group.file { renaming = nil } })
                            .onDrag {
                                guard let vault = state.vault else { return NSItemProvider() }
                                return FileHandoff.itemProvider(url: vault.url(for: group.file), relativePath: group.file.relativePath)
                            }
                            .contextMenu {
                                Button("Preview") { PaletteController.shared.showResult(group.result, query: model.query, state: state) }
                                Button("Open in Default App") { state.openSearchResult(group.result, externally: true) }
                                Divider()
                                Button("Rename…") { renaming = group.file }
                                Button("Copy File") { _ = state.copyFiles([group.file]) }
                            }
                        if model.isOpen(group.file) {
                            ForEach(group.rows, id: \.id) { _, hit in
                                ResultMatch(hit: hit, selected: hit.file == state.selected && hit.anchor != nil && hit.anchor == state.anchor) {
                                    pick(hit.file, anchor: hit.anchor, commentID: hit.commentID)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.xs)
                .padding(.bottom, Theme.Space.s)
            }
        }
        .onAppear { model.isShown = true }
        .onDisappear { model.isShown = false }
    }

    private func pick(_ file: FileRef, anchor: FileAnchor?, commentID: UUID? = nil) {
        state.recordSearch(model.query)
        state.jump(to: file, anchor: anchor)
        state.sourceHighlight = UnifiedSearchQuery(raw: model.query).text
        state.selectedCommentID = commentID
        if commentID != nil { state.railVisible = true }
    }
}

/// Takes focus as soon as AppKit attaches the field, before the next keyboard event.
/// A timer or delayed FocusState reset can drop the first letters after the shortcut.
/// The search tab's field, and the results list's (SearchResultsView.swift), which waits for
/// `focusToken` (`focusOnAppear: false`) and hands ↑ ↓ to the list through `onMove`.
struct SidebarSearchInput: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var focusToken: Int
    var focusOnAppear = true
    var onSubmit: () -> Void
    var onExit: () -> Void
    /// ↑ (-1) or ↓ (1); true when it was used.
    var onMove: ((Int) -> Bool)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12))
                .foregroundStyle(Theme.Color.textTertiary).accessibilityHidden(true)
            NativeSidebarSearchInput(text: $text, focusToken: focusToken, focusOnAppear: focusOnAppear,
                                     onFocus: { focused.wrappedValue = $0 }, onSubmit: onSubmit, onExit: onExit, onMove: onMove)
                .frame(maxWidth: .infinity)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.Color.textTertiary)
                }.buttonStyle(.press(shade: nil)).accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, Theme.Space.s).frame(height: Theme.Size.row)
        .background(Squircle(radius: Theme.Radius.m - 2).fill(Theme.Color.fill))
        .focusRing(focused.wrappedValue, radius: Theme.Radius.m - 2)
    }
}

struct NativeSidebarSearchInput: NSViewRepresentable {
    @Binding var text: String
    var focusToken: Int
    var focusOnAppear = true
    var onFocus: (Bool) -> Void
    var onSubmit: () -> Void
    var onExit: () -> Void
    var onMove: ((Int) -> Bool)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> ImmediateSearchTextField {
        let field = ImmediateSearchTextField()
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = Theme.NS.body; field.textColor = Theme.NS.text
        field.isEditable = true; field.isSelectable = true
        field.maximumNumberOfLines = 1; field.cell?.isScrollable = true
        field.setAccessibilityLabel("Search")
        field.delegate = context.coordinator
        field.stringValue = text
        context.coordinator.token = focusToken
        if focusOnAppear { field.requestFocus() }
        return field
    }
    func updateNSView(_ field: ImmediateSearchTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { field.stringValue = text }
        if coordinator.token != focusToken {
            coordinator.token = focusToken
            field.requestFocus()
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeSidebarSearchInput
        var token = 0
        init(_ parent: NativeSidebarSearchInput) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func controlTextDidBeginEditing(_ notification: Notification) {
            DispatchQueue.main.async { self.parent.onFocus(true) }
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            DispatchQueue.main.async { self.parent.onFocus(false) }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) { parent.onSubmit(); return true }
            if selector == #selector(NSResponder.cancelOperation(_:)) { parent.onExit(); return true }
            if selector == #selector(NSResponder.moveDown(_:)), let onMove = parent.onMove { return onMove(1) }
            if selector == #selector(NSResponder.moveUp(_:)), let onMove = parent.onMove { return onMove(-1) }
            return false
        }
    }
}

final class ImmediateSearchTextField: NSTextField {
    private var needsFocus = false
    func requestFocus() { needsFocus = true; focusIfAttached() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); focusIfAttached() }
    private func focusIfAttached() {
        guard needsFocus, let window, window.attachedSheet == nil else { return }
        if window.makeFirstResponder(self) { needsFocus = false }
    }
}

/// A file with matches: chevron, glyph, name, count.
private struct ResultFile: View {
    @EnvironmentObject var state: AppState
    let group: SidebarSearchModel.Group
    let open: Bool
    let toggle: () -> Void
    let select: () -> Void
    var renaming = false
    var endRename: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        let selected = state.selected == group.file
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.Color.textTertiary)
                .rotationEffect(.degrees(open ? 90 : 0))
                .frame(width: 14, height: Theme.Size.row)
                .contentShape(Rectangle())
                .onTapGesture(perform: toggle)
            if group.isDirectory { FolderGlyph() } else { FileGlyph(ext: group.file.ext, selected: selected) }
            if group.hits.contains(where: { $0.commentID != nil }) {
                Image(systemName: "text.bubble.fill").font(.system(size: 9)).foregroundStyle(Theme.Color.textTertiary)
                    .help("Matching thoughts attached")
            }
            if renaming {
                RenameField(name: group.file.name, isFolder: group.isDirectory, font: Theme.NS.bodyMedium,
                            commit: { state.rename(group.file.relativePath, to: $0) }, end: endRename)
            } else {
                Text(group.file.name)
                    .font(Theme.Font.bodyMedium)
                    .foregroundStyle(Theme.Color.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Theme.Space.xs)
            Text(group.isDirectory || group.hits.isEmpty ? "" : String(group.hits.count))
                .font(Theme.Font.small)
                .monospacedDigit()
                .foregroundStyle(Theme.Color.textTertiary)
        }
        .padding(.horizontal, Theme.Space.xs)
        .frame(height: Theme.Size.row)
        .background(Squircle(radius: Theme.Radius.s)
            .fill(selected ? Theme.Color.selection : Theme.Color.hover)
            .opacity(selected || hovering ? 1 : 0))
        .contentShape(Rectangle())
        .onTapGesture { if !renaming { select() } }
        .onHover { hovering = $0 }
        .help(group.file.relativePath)
    }
}

/// One match: the snippet with the matched words in full colour; a thought gets a bubble.
private struct ResultMatch: View {
    let hit: SearchHit
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
      Button(action: action) {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            if hit.commentID != nil {
                Image(systemName: "text.bubble")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.accent)
            }
            Text(SnippetText.attributed(hit.snippet.isEmpty ? hit.file.relativePath : hit.snippet))
                .font(Theme.Font.small)
                .foregroundStyle(Theme.Color.textSecondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let a = hit.anchor {
                Text(a.displayLabel)
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 5)
        .padding(.leading, 24)
        .padding(.trailing, Theme.Space.xs)
        .background(Squircle(radius: Theme.Radius.s)
            .fill(selected ? Theme.Color.selection : Theme.Color.hover)
            .opacity(selected || hovering ? 1 : 0))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
      }
      .buttonStyle(.press)
      .help((hit.commentID == nil ? "Open source: " : "Open thought: ") + hit.file.relativePath + (hit.anchor.map { " · " + $0.label } ?? ""))
    }
}

/// The index's `«…»` match marks, drawn as semibold full-colour runs.
private enum SnippetText {
    static func attributed(_ raw: String) -> AttributedString {
        var out = Snippet.attributed(raw)
        for run in out.runs where run.foregroundColor != nil {
            out[run.range].font = Theme.Font.small.weight(.semibold)
        }
        return out
    }
}
