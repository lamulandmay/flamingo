import SwiftUI
import FlamingoCore
import FlamingoDesign

/// Up to four document panes in one container. A single `ForEach` over the visible panes, keyed
/// by pane, places each in its frame, so changing the layout or closing a neighbour only moves
/// frames: no PDF, Quick Look or text view is remounted. Each pane owns its location; only the
/// active one drives the shell and the context rail.
struct PreviewPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TileContainer(tiling: state.tiling, geometry: state.tiling.geometry)
            .background(Theme.Color.bg)
    }
}

private struct TileContainer: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var tiling: PaneTiling
    @ObservedObject var geometry: TileGeometry

    var body: some View {
        GeometryReader { proxy in
            let arrangement = tiling.arrangement
            let layout = arrangement.kind, visible = arrangement.visible
            let fractions = geometry.fractions(for: layout).clamped(layout, size: proxy.size)
            let frames = layout.frames(in: proxy.size, fractions)
            ZStack(alignment: .topLeading) {
                ForEach(visible, id: \.self) { id in
                    let slot = visible.firstIndex(of: id) ?? 0
                    let frame = frames.indices.contains(slot) ? frames[slot] : .zero
                    DocumentPaneColumn(pane: state.pane(id), slot: slot, count: visible.count, width: frame.width)
                        .frame(width: frame.width, height: frame.height)
                        .clipped()
                        .position(x: frame.midX, y: frame.midY)
                        .transition(.opacity.animation(Theme.Motion.normal))
                }
                ForEach(layout.dividers(in: proxy.size, fractions)) { spec in
                    TileDividerHandle(spec: spec, layout: layout, size: proxy.size, geometry: geometry)
                        .position(x: spec.rect.midX, y: spec.rect.midY)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }
}

private struct DocumentPaneColumn: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var pane: DocumentPane
    let slot: Int
    let count: Int
    var width: CGFloat = 1000
    @State private var hovering = false

    private var active: Bool { state.activePaneID == pane.id }
    private var tiled: Bool { count > 1 }
    /// Too narrow for the name, ••• and the anchor side by side: ••• moves beside ✕, the anchor goes.
    private var narrow: Bool { width < 360 }

    var body: some View {
        VStack(spacing: 0) {
            if tiled {
                header
                Rectangle().fill(active ? Theme.Color.accent : Theme.Color.hairline).frame(height: 1)
            }
            if let file = pane.file, let url = state.url(for: file) {
                DocumentSurface(file: file, url: url, pane: pane, paneHovering: hovering)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tiled {
                PaneLauncher(pane: pane)
            } else {
                HStack {
                    TileHandle(paneID: pane.id, paneHovering: hovering)
                }
                .frame(maxWidth: .infinity).frame(height: 30)
                Hairline()
                FolderSurface()
            }
        }
        .background(Theme.Color.bg)
        .onHover { hovering = $0 }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            Button { state.activatePane(pane.id); pane.focusWhenReady() } label: {
                HStack(spacing: Theme.Space.s) {
                    if let file = pane.file { FileGlyph(ext: file.ext, selected: active) }
                    Text(pane.file?.name ?? "")
                        .font(Theme.Font.bodyMedium)
                        .foregroundStyle(active ? Theme.Color.text : Theme.Color.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if !narrow, let anchor = pane.anchor {
                        Text(anchor.label).font(Theme.Font.monoSmall)
                            .foregroundStyle(Theme.Color.textTertiary).lineLimit(1)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
                .help(pane.file?.relativePath ?? "")
            if narrow { TileHandle(paneID: pane.id, paneHovering: hovering) }
            IconButton("xmark", help: "Close Pane") { state.closePane(pane.id) }
        }
        .overlay(alignment: .center) { if !narrow { TileHandle(paneID: pane.id, paneHovering: hovering) } }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 36)
        .background(active ? Theme.Color.bgRaised : Theme.Color.bg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pane \(slot + 1) of \(count)" + (active ? ", active" : "") + (pane.file.map { ": " + $0.name } ?? ""))
    }
}

/// Which view renders a file, by extension.
enum PreviewKind {
    case pdf, media, quickLook

    init(ext: String) {
        if ext == "pdf" {
            self = .pdf
        } else if MediaKind.isMedia(ext) {
            self = .media
        } else {
            self = .quickLook
        }
    }

    /// Content modification date, nil when the file is gone. One stat per update of the
    /// pane; SwiftUI only re-runs `updateNSView` when an input changes, so this is how
    /// a file rewritten on disk gets re-rendered.
    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
