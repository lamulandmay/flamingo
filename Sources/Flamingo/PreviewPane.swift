import SwiftUI
import FlamingoCore
import FlamingoDesign

/// Keep the primary document mounted when a second pane opens or closes. Each pane
/// owns its location; only the active one drives the shell and the context rail.
struct PreviewPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        GeometryReader { geometry in
        HSplitView {
            DocumentPaneColumn(pane: state.primaryPane)
                .frame(minWidth: 220, idealWidth: state.splitVisible ? (geometry.size.width - 1) / 2 : geometry.size.width,
                       maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .trailing) {
                    if state.splitVisible {
                        DocumentDividerGrip().frame(width: 8)
                    }
                }
            if state.splitVisible {
                DocumentPaneColumn(pane: state.secondaryPane)
                    .frame(minWidth: 220, idealWidth: (geometry.size.width - 1) / 2,
                           maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        }
        .background(Theme.Color.bg)
    }
}

/// A generous native hit target for the otherwise one-point SwiftUI split divider.
/// Resizing still goes through NSSplitView so both hosted documents keep their identity.
private struct DocumentDividerGrip: NSViewRepresentable {
    func makeNSView(context: Context) -> DocumentDividerGripView { DocumentDividerGripView() }
    func updateNSView(_ view: DocumentDividerGripView, context: Context) {}
}

private final class DocumentDividerGripView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        var ancestor = superview
        while let view = ancestor {
            if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count == 2 {
                let x = split.convert(event.locationInWindow, from: nil).x
                split.setPosition(min(max(220, x), split.bounds.width - 221), ofDividerAt: 0)
                return
            }
            ancestor = view.superview
        }
    }
}

private struct DocumentPaneColumn: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var pane: DocumentPane

    private var active: Bool { state.activePaneID == pane.id }

    var body: some View {
        VStack(spacing: 0) {
            if state.splitVisible {
                HStack(spacing: Theme.Space.s) {
                    Button { state.activatePane(pane.id); pane.focusWhenReady() } label: {
                        HStack(spacing: Theme.Space.s) {
                            if let file = pane.file { FileGlyph(ext: file.ext, selected: active) }
                            Text(pane.file?.name ?? "Files")
                                .font(Theme.Font.bodyMedium)
                                .foregroundStyle(active ? Theme.Color.text : Theme.Color.textSecondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            if let anchor = pane.anchor {
                                Text(anchor.label).font(Theme.Font.monoSmall)
                                    .foregroundStyle(Theme.Color.textTertiary).lineLimit(1)
                            }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .help(pane.file?.relativePath ?? "Activate pane")
                        .accessibilityLabel((pane.id == .primary ? "Left pane" : "Right pane") + (active ? ", active" : "") + ": " + (pane.file?.name ?? "Files"))
                    if pane.id == .secondary {
                        IconButton("xmark", help: "Close right pane") {
                            state.activatePane(.primary)
                            state.closeSplit()
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.m)
                .frame(height: 36)
                .background(active ? Theme.Color.bgRaised : Theme.Color.bg)
                Rectangle().fill(active ? Theme.Color.accent : Theme.Color.hairline).frame(height: 1)
            }
            if let file = pane.file, let url = state.url(for: file) {
                DocumentSurface(file: file, url: url, pane: pane)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if pane.id == .primary {
                FolderSurface()
            } else {
                VStack(spacing: Theme.Space.m) {
                    Text("No file open").font(Theme.Font.body).foregroundStyle(Theme.Color.textTertiary)
                    Button("Open a file…") {
                        state.activatePane(pane.id)
                        state.showPalette(.commands)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.Color.bg)
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
