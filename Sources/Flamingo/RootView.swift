import SwiftUI
import UniformTypeIdentifiers
import FlamingoCore
import FlamingoDesign
import FlamingoCapture
import FlamingoGraph
import FlamingoTrail
import FlamingoAsk

/// Sidebar | content | inspector, under a transparent title bar. Both sidebars resize by
/// their dividers. Plan 01 owns.
struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View { RootLayout(layout: state.layout) }
}

/// Observes only the geometry, so a divider drag redraws the frame and the columns' sizes,
/// not every view that reads `AppState`. A swipe's frames redraw only `SwipeFollow`.
private struct RootLayout: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var layout: PanelLayout
    @State private var dropTargeted = false

    var body: some View {
        GeometryReader { geo in
            let titlebar = geo.safeAreaInsets.top > 0 ? geo.safeAreaInsets.top : 38
            HStack(spacing: 0) {
                Sidebar(topInset: titlebar)
                    .frame(width: Sidebar.width(state))
                if state.sidebarCollapsed {
                    VHairline()
                } else {
                    ResizeHandle(width: $layout.leftWidth, range: PanelLayout.left, edge: .leading,
                                 defaultWidth: Theme.Size.sidebar, onEnd: layout.persist)
                }
                VStack(spacing: 0) {
                    TopBar(height: titlebar)
                    Hairline()
                        .overlay(alignment: .top) { IndexingHairline(indexing: state.indexing) }
                    WorkingFilesBar()
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .modifier(SwipeFollow(motion: state.swipe))
                        .overlay(alignment: .bottom) {
                            ZStack {
                                if let toast = state.toast {
                                    Toast(toast.text, action: toast.action, perform: toast.perform)
                                        .frame(maxWidth: 360)
                                        .padding(Theme.Space.l)
                                        .id(toast.id)
                                }
                            }
                            .animation(Theme.Motion.arrive, value: state.toast?.id)
                        }
                        .overlay {
                            if let deck = state.wander { WanderPanel(deck: deck).transition(.opacity.combined(with: .scale(0.97))) }
                        }
                        .overlay {
                            if state.connectGridShown { ConnectGrid().transition(.opacity) }
                        }
                        .clipped()
                }
                .background(Theme.Color.bg)
                .frame(minWidth: 360)
                if state.railShown {
                    ResizeHandle(width: $layout.rightWidth, range: PanelLayout.right, edge: .trailing,
                                 defaultWidth: 320, onEnd: layout.persist)
                    Inspector(topInset: titlebar)
                        .frame(width: layout.rightWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .ignoresSafeArea()
            .overlay { BriefingOverlay(model: state.briefing, topInset: titlebar).ignoresSafeArea() }
        }
        .tint(Theme.Color.accent)
        .animation(Theme.Motion.normal, value: state.wander != nil)
        .animation(Theme.Motion.normal, value: state.connectGridShown)
        .sheet(isPresented: $state.isNewFilePresented) { NewFileSheet().environmentObject(state) }
        .sheet(isPresented: $state.isHealthPresented) { IndexHealthSheet(indexing: state.indexing).environmentObject(state) }
        .background(MakeProjectHost(model: state.agentProjects))
        .overlay {
            Rectangle()
                .strokeBorder(Theme.Color.accent, lineWidth: 1)
                .opacity(dropTargeted ? 1 : 0)
                .animation(Theme.Motion.fast, value: dropTargeted)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        }
        .overlay { RadialRecentsView(radial: state.radial, recents: state.recents) }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { @MainActor in
                let urls = await DroppedURLs.load(providers)
                state.handleDropped(urls)
            }
            return true
        }
    }

    @ViewBuilder private var content: some View {
        if state.vault == nil {
            NoVault()
        } else {
            switch state.mode {
            case .files, .ask:
                // The morning inbox covers the window; the panes stay mounted underneath.
                PreviewPane()
                    .opacity(state.briefing.isPresented ? 0 : 1)
                    .allowsHitTesting(!state.briefing.isPresented)
            case .graph:
                GraphView(graph: state.graph, selected: state.selected, vault: state.vault, scope: state.selectedFolder,
                          arrangement: state.graphArrangement,
                          onSelectionChange: { state.select($0, source: .graph) },
                          onScopeChange: { state.selectFromSidebar(folder: $0, file: nil) },
                          onConnectionsChanged: { state.connectionsTouched(identities: true) },
                          onArrangementChange: { state.graphArrangement = $0 }) {
                    state.jump(to: $0, anchor: nil)
                }
                .actionHistory(state.actionHistory)
                .graphRevision(state.graphRevision)
                .replay(firstSeen: { [weak state] in await state?.session?.firstSeen() ?? [:] }, request: state.graphReplayRequest)
                .celebrating(state.graphCelebration) { state.celebrationMissed($0) }
            case .trail:
                if let store = state.trailStore {
                    TrailView(store: store, onSelect: { state.jump(to: $0, anchor: $1) },
                              onOpenLink: { state.openLink($0, from: $1) })
                        .onResume { state.resumeLocations($0.locationsToReopen) }
                        .actionHistory(state.actionHistory)
                } else {
                    Color.clear
                }
            }
        }
    }
}

/// A 2pt accent line under the title bar while the vault is being indexed, as long as the
/// pass knows how far it has to go. Nothing else on screen says so; hovering it, the palette
/// and Workspace Health say what the pass is doing, how far it got, and how long is left.
private struct IndexingHairline: View {
    @ObservedObject var indexing: IndexingModel

    var body: some View {
        // Only in the tree while indexing: an indeterminate hairline's pulse repeats forever,
        // and at opacity 0 it still redrew the window at the display's rate, idle or not.
        ZStack {
            if indexing.status != nil { ProgressHairline(value: progress).transition(.opacity) }
        }
        .frame(maxWidth: .infinity, minHeight: 2, maxHeight: 2)
        .animation(Theme.Motion.normal, value: indexing.status == nil)
        // A band a few points tall, so the tooltip can be found; only while indexing.
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(indexing.status?.summary ?? "")
        .allowsHitTesting(indexing.status != nil)
        .padding(.vertical, -3)
    }

    private var progress: Double? { indexing.status?.fraction.map { min(1, max(0, $0)) } }
}

/// The strip under the transparent title bar: mode switcher, current file, rail toggle.
struct TopBar: View {
    @EnvironmentObject var state: AppState
    let height: CGFloat

    var body: some View {
        ZStack {
            HStack(spacing: Theme.Space.m) {
                if state.sidebarCollapsed {
                    // The traffic lights spill past the ribbon; the panel's toggle sits after them.
                    Color.clear.frame(width: Sidebar.trafficLights - Ribbon.width - Theme.Space.m - Theme.Space.xs)
                    SidebarToggle()
                }
                SegmentedModes(selection: $state.mode)
                    .disabled(state.vault == nil)
                    .opacity(state.vault == nil ? Theme.Opacity.disabled : 1)
                Spacer()
                if state.vault != nil, state.mode == .files, state.selected == nil, !state.splitVisible, state.shownResults == nil {
                    FolderStyleToggle(browser: state.browser)
                        .transition(.opacity)
                }
                AttentionButton(indexing: state.indexing)
                IconButton("square.grid.3x3", help: "Connect Files", isOn: state.connectGridShown) {
                    state.connectGridShown.toggle()
                }
                .disabled(state.vault == nil)
                IconButton("sidebar.right", help: state.railShown ? "Hide Inspector" : "Show Inspector", isOn: state.railShown) {
                    state.toggleRail()
                }
            }
            CurrentFileTitle()
                .padding(.horizontal, 160)
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: height)
        .background(Theme.Color.bg)
        .focusEffectDisabled()
    }
}

/// File name and anchor, centred, like a window title that only shows the user's own data.
/// ↩ (when nothing else takes it) or right-click ▸ Rename… edits the name here.
struct CurrentFileTitle: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if let f = state.selected {
            let renaming = state.renamingTitle == f
            HStack(spacing: Theme.Space.s) {
                if renaming {
                    RenameField(name: f.name, alignment: .center, maxWidth: 420) { new in
                        state.rename(f.relativePath, to: new)
                    } end: {
                        if state.renamingTitle == f { state.renamingTitle = nil }
                    }
                } else {
                    Text(f.name)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contextMenu {
                            Button("Rename…") { state.renameInTitle() }
                            Button("Reveal in Finder") { state.revealInFinder(f) }
                            Button("Copy Path") { state.copyPath(f) }
                        }
                }
                if let a = state.anchor, !renaming {
                    Text(a.displayLabel)
                        .font(Theme.Font.mono)
                        .foregroundStyle(Theme.Color.textTertiary)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            .animation(Theme.Motion.fast, value: state.anchor)
            // Another file came up some other way than a click (which would have kept the name).
            .onChange(of: f) { state.renamingTitle = nil }
        } else if state.vault != nil, state.mode == .files, state.shownResults == nil {
            BrowsedFolderTitle(browser: state.browser)
        }
    }
}

/// With no file open, the folder the columns show, as Finder titles its window.
private struct BrowsedFolderTitle: View {
    @ObservedObject var browser: ColumnBrowserModel

    var body: some View {
        if browser.style == .columns, let folder = browser.folder ?? browser.root {
            Text(FileManager.default.displayName(atPath: folder.path))
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(folder.path)
        }
    }
}

/// Icons or columns, as in Finder's toolbar.
private struct FolderStyleToggle: View {
    @ObservedObject var browser: ColumnBrowserModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(FolderStyle.allCases) { style in
                IconButton(style.symbol, help: "View " + style.title, isOn: browser.style == style) { browser.style = style }
                    .background(Squircle(radius: Theme.Radius.s)
                        .fill(Theme.Color.hover)
                        .opacity(browser.style == style ? 1 : 0))
            }
        }
        .animation(Theme.Motion.fast, value: browser.style)
    }
}

/// Appears only when something needs you: indexing failed, or rename tracking did.
/// Opens Workspace Health.
private struct AttentionButton: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var indexing: IndexingModel

    var body: some View {
        if indexing.error != nil || state.continuityError != nil {
            IconButton("exclamationmark.triangle", help: indexing.error ?? state.continuityError ?? "Workspace Health") {
                state.isHealthPresented = true
            }
            .transition(.opacity)
        }
    }
}

/// Empty state: the mark, and the one way in.
struct NoVault: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            FlamingoMark()
                .fill(Theme.Color.accent)
                .frame(width: 44, height: 68)
                .accessibilityHidden(true)
            Button("Open Folder…") { state.openVaultDialog() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: .command)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contextMenu {
            Button("Open Home Folder") { state.open(FileManager.default.homeDirectoryForCurrentUser) }
        }
    }
}

enum DroppedURLs {
    static func load(_ providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { cont in
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    if let data = item as? Data { cont.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                    else if let u = item as? URL { cont.resume(returning: u) }
                    else { cont.resume(returning: nil) }
                }
            }
            if let url { urls.append(url) }
        }
        return urls
    }
}
