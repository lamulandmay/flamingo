import SwiftUI
import UniformTypeIdentifiers
import FlamingoCore
import FlamingoDesign
import FlamingoCapture
import FlamingoGraph
import FlamingoTrail
import FlamingoAsk

/// Sidebar | content | comments rail, under a transparent title bar. Plan 01 owns.
struct RootView: View {
    @EnvironmentObject var state: AppState
    @State private var dropTargeted = false

    var body: some View {
        GeometryReader { geo in
            let titlebar = geo.safeAreaInsets.top > 0 ? geo.safeAreaInsets.top : 38
            HStack(spacing: 0) {
                Sidebar(topInset: titlebar)
                    .frame(width: state.sidebarWidth)
                SidebarDivider()
                VStack(spacing: 0) {
                    TopBar(height: titlebar)
                    Hairline()
                    HStack(spacing: 0) {
                        content
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(alignment: .bottom) {
                                if let toast = state.toast {
                                    Toast(toast.text, action: toast.action, perform: toast.perform)
                                        .frame(maxWidth: 360)
                                        .padding(Theme.Space.l)
                                        .id(toast.id)
                                }
                            }
                        if state.railShown {
                            VHairline()
                            Rail(file: state.selected)
                                .frame(width: Theme.Size.rail)
                                .transition(.move(edge: .trailing))
                        }
                    }
                    .clipped()
                }
                .background(Theme.Color.bg)
            }
            .ignoresSafeArea()
        }
        .tint(Theme.Color.accent)
        .overlay {
            Rectangle()
                .strokeBorder(Theme.Color.accent, lineWidth: 1)
                .opacity(dropTargeted ? 1 : 0)
                .animation(Theme.Motion.fast, value: dropTargeted)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        }
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
            case .files:
                PreviewPane()
            case .graph:
                GraphView(graph: state.graph, selected: state.selected, vault: state.vault) {
                    state.jump(to: $0, anchor: nil)
                }
            case .trail:
                if let store = state.trailStore {
                    TrailView(store: store, onSelect: { state.jump(to: $0, anchor: $1) })
                        .onResume { state.resume($0.filesToReopen) }
                } else {
                    Color.clear
                }
            case .ask:
                if let engine = state.askEngine {
                    AskView(engine: engine) { state.jump(to: $0, anchor: $1) }
                } else {
                    Color.clear
                }
            }
        }
    }
}

/// The strip under the transparent title bar: mode switcher, current file, rail toggle.
struct TopBar: View {
    @EnvironmentObject var state: AppState
    let height: CGFloat

    var body: some View {
        ZStack {
            HStack(spacing: Theme.Space.m) {
                SegmentedModes(selection: $state.mode)
                    .disabled(state.vault == nil)
                    .opacity(state.vault == nil ? Theme.Opacity.disabled : 1)
                Spacer()
                IconButton("sidebar.right", help: state.railShown ? "Hide Comments" : "Show Comments") {
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
struct CurrentFileTitle: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if let f = state.selected {
            HStack(spacing: Theme.Space.s) {
                Text(f.name)
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let a = state.anchor {
                    Text(a.label)
                        .font(Theme.Font.mono)
                        .foregroundStyle(Theme.Color.textTertiary)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            .animation(Theme.Motion.fast, value: state.anchor)
        }
    }
}

/// Hairline between sidebar and content that can be dragged to resize the sidebar.
struct SidebarDivider: View {
    @EnvironmentObject var state: AppState
    @State private var startWidth: CGFloat?

    var body: some View {
        VHairline()
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { v in
                                if startWidth == nil { startWidth = state.sidebarWidth }
                                let w = (startWidth ?? Theme.Size.sidebar) + v.translation.width
                                state.sidebarWidth = min(max(w.rounded(), 180), 420)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
    }
}

/// The comments rail for one file, with the file's neighbourhood beneath it.
/// `file` is fixed when the view is built, so an edit that commits while the selection is
/// already moving still lands on the file it was made on.
struct Rail: View {
    @EnvironmentObject var state: AppState
    let file: FileRef?

    var body: some View {
        VStack(spacing: 0) {
            CommentsRail(
                comments: state.comments,
                onJump: { state.jumpToAnchor($0) },
                onEdit: { c in if let file { state.updateComment(c, in: file) } },
                onDelete: { c in if let file { state.deleteComment(c, from: file) } }
            )
            .onOpenLink { state.openLink($0) }
            .onRestore { c in state.restoreComment(c, to: file) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let file, state.graph.nodes.contains(where: { $0.id == file.relativePath }) {
                Hairline()
                LocalGraphView(graph: state.graph, center: file, depth: 1) { state.jump(to: $0, anchor: nil) }
                    .frame(height: 220)
                    .clipped()
            }
        }
        .id(file)
        .background(Theme.Color.bg)
    }
}

/// Empty state: one noun phrase, and it is the way in.
struct NoVault: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Button { state.openVaultDialog() } label: {
            EmptyState("No vault open")
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
