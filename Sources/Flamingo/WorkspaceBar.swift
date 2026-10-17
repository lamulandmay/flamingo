import SwiftUI
import FlamingoCore
import FlamingoDesign
import FlamingoIndex

/// Open files as quiet tabs: the current one in full text with an accent underline, the
/// rest secondary. One open file needs no tab bar; the title bar already names it.
struct WorkingFilesBar: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        if state.openFiles.count > 1 {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(state.openFiles, id: \.relativePath) { file in
                            WorkingFileTab(file: file, selected: state.selected == file).id(file.relativePath)
                        }
                    }
                    .padding(.horizontal, Theme.Space.xs)
                }
                .onChange(of: state.selected) { _, file in
                    if let file { withAnimation(Theme.Motion.fast) { proxy.scrollTo(file.relativePath) } }
                }
            }
            .frame(height: 30)
            .background(Theme.Color.bg)
            Hairline()
        }
    }
}

private struct WorkingFileTab: View {
    @EnvironmentObject var state: AppState
    let file: FileRef
    let selected: Bool
    @State private var hovering = false
    /// Showing in a pane that isn't the active one.
    private var elsewhere: Bool {
        !selected && state.visiblePanes.contains { $0.id != state.activePaneID && $0.file == file }
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            FileGlyph(ext: file.ext, size: 12, selected: selected)
            Text(file.name)
                .font(Theme.Font.small)
                .foregroundStyle(selected ? Theme.Color.text : Theme.Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .leading)
            Button { state.closeTab(file) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.Color.textTertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Close Tab")
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 30)
        .background(Theme.Color.hover.opacity(hovering && !selected ? 1 : 0))
        .overlay(alignment: .bottom) {
            Rectangle().fill(selected ? Theme.Color.accent : Theme.Color.textTertiary).frame(height: 1.5)
                .opacity(selected || elsewhere ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { state.reveal(file) }
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fast, value: hovering)
        .help(file.relativePath)
        .onDrag {
            guard let url = state.url(for: file) else { return NSItemProvider() }
            return FileHandoff.itemProvider(url: url, relativePath: file.relativePath)
        }
        .contextMenu {
            Button("Open Beside") { state.openBeside(file) }
            if let empty = state.visiblePanes.first(where: { $0.file == nil }) {
                Button("Open in Empty Pane") { state.open(file, inPane: empty.id) }
            }
            Button("Copy File") { state.copyFiles([file]) }
            Button("Copy Path") { state.copyPath(file) }
            Button("Reveal in Finder") { state.revealInFinder(file) }
            Divider()
            Button("Close Tab") { state.closeTab(file) }
            Button("Close Other Tabs") { for other in state.openFiles where other != file { state.closeTab(other) } }
        }
    }
}

struct IndexHealthSheet: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var indexing: IndexingModel
    @State private var health: IndexHealth?
    @State private var incomplete: [IndexedFileCoverage] = []
    @State private var size: Int64 = 0
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.vault?.name ?? "").font(Theme.Font.title).foregroundStyle(Theme.Color.text)
                    Text(state.vault?.root.path ?? "").font(Theme.Font.monoSmall).foregroundStyle(Theme.Color.textTertiary)
                        .lineLimit(1).truncationMode(.head).textSelection(.enabled)
                }
                Spacer()
                IconButton("xmark", help: "Close") { state.isHealthPresented = false }.keyboardShortcut(.cancelAction)
            }
            if let health {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xl) {
                    metric("searchable", health.complete)
                    metric("partial", health.partial)
                    metric("failed", health.failed)
                    metric("name only", health.metadataOnly + health.unsupported)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary).help("Index size on disk")
                }
            }
            if let status = indexing.status {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ProgressHairline(value: status.fraction)
                    Text(status.headline).font(Theme.Font.small).monospacedDigit().foregroundStyle(Theme.Color.textSecondary)
                    if let detail = status.detail {
                        Text(detail).font(Theme.Font.small).monospacedDigit().foregroundStyle(Theme.Color.textTertiary)
                    }
                    if let current = status.current {
                        Text(current.relativePath).font(Theme.Font.monoSmall).foregroundStyle(Theme.Color.textTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            ForEach([error, indexing.error, state.continuityError].compactMap { $0 }, id: \.self) { line in
                Text(line).font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary).textSelection(.enabled)
            }
            HStack(spacing: Theme.Space.s) {
                Toggle("Analyze files saved from Flamingo", isOn: $state.automaticAnalysis)
                    .toggleStyle(.switch).controlSize(.small).font(Theme.Font.small)
                    .help("Runs locally and leaves a labelled AI thought with suggested connections")
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Retry Failed") { Task { await retry() } }.disabled(busy || (health?.failed ?? 0) == 0)
                if indexing.status != nil {
                    Button("Pause") { state.session?.cancelIndexing() }
                } else {
                    Button("Rescan") { state.reindex() }
                }
                if state.continuityError != nil {
                    Button("Retry Moves") { if let s = state.session { Task { await state.applyIndexedRenames(in: s) } } }
                }
            }
            .controlSize(.small)
            if !incomplete.isEmpty {
                Hairline()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(incomplete, id: \.file.relativePath) { item in
                            Button {
                                state.isHealthPresented = false; state.jump(to: item.file, anchor: nil)
                            } label: {
                                HStack(spacing: Theme.Space.s) {
                                    FileGlyph(ext: item.file.ext)
                                    Text(item.file.relativePath).font(Theme.Font.body).foregroundStyle(Theme.Color.text)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: Theme.Space.s)
                                    Text(item.coverage.reason ?? item.coverage.state.rawValue)
                                        .font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary).lineLimit(1)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .flamingoRow(selected: false)
                        }
                    }
                }.frame(maxHeight: 240)
            }
        }.padding(Theme.Space.xl).frame(width: 600).background(Theme.Color.bg).task { await refresh() }
    }
    private func metric(_ name: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(count.formatted()).font(.system(size: 20, weight: .medium)).monospacedDigit()
                .foregroundStyle(count > 0 || name == "searchable" ? Theme.Color.text : Theme.Color.textTertiary)
            Text(name).font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary)
        }
    }
    private func refresh() async {
        guard let session = state.session else { return }
        do { (health, incomplete, size) = try await session.health(); error = nil; indexing.error = session.indexingError }
        catch { self.error = session.startupError ?? error.localizedDescription }
    }
    private func retry() async {
        guard let session = state.session else { return }
        busy = true
        var failure: String?
        do { try await session.retryIncomplete() } catch { failure = error.localizedDescription }
        busy = false; await refresh(); if let failure { error = failure }; state.sidebarSearch.refresh()
    }
}
