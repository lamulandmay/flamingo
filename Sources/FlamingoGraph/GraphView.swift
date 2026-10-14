import SwiftUI
import AppKit
import FlamingoCore
import FlamingoDesign

/// Force-directed graph of the vault. Plan 06 owns.
///
/// Drag to pan, scroll or pinch to zoom, double-click empty space to fit. Drag a node to pin
/// it; double-click it to let go. Hover shows a node's neighborhood, click opens the file.
/// Arrows walk the graph, Return opens. Typing filters: `ext:pptx`, `orphans`, or any part
/// of a path. Files that don't exist (unresolved wikilinks) draw as hollow rings when the
/// vault is passed.
public struct GraphView: View {
    public var graph: Graph
    public var selected: FileRef?
    public var onSelect: (FileRef) -> Void
    var vault: Vault?

    @StateObject private var model: GraphModel
    @State private var filter = ""
    @FocusState private var filterFocused: Bool

    public init(graph: Graph, selected: FileRef? = nil, onSelect: @escaping (FileRef) -> Void) {
        self.init(graph: graph, selected: selected, vault: nil, onSelect: onSelect)
    }

    /// Pass the vault so the layout persists in `<vault>/.flamingo/graph-layout.json`: reopening
    /// shows the graph exactly as it was left, pins included. Without it the layout lives only
    /// for the life of the process.
    public init(graph: Graph, selected: FileRef? = nil, vault: Vault?, onSelect: @escaping (FileRef) -> Void) {
        self.graph = graph; self.selected = selected; self.vault = vault; self.onSelect = onSelect
        _model = StateObject(wrappedValue: GraphModel(graph: graph, vault: vault))
    }

    public var body: some View {
        let _ = bindCallbacks()
        ZStack(alignment: .topLeading) {
            GraphCanvas(model: model, redraw: model.redraw)
                .overlay(GraphInputLayer(target: model))
            SearchField(text: $filter, focused: $filterFocused,
                        onSubmit: { model.openBestMatch() },
                        onExit: { filter = ""; model.focusCanvas() })
                // Up and down walk the matches without leaving the field.
                .onKeyPress(.upArrow) { model.moveSelection(.up); return .handled }
                .onKeyPress(.downArrow) { model.moveSelection(.down); return .handled }
                .frame(width: 200)
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { model.occludedRect = proxy.frame(in: .named(Self.space)) }
                        .onChange(of: proxy.frame(in: .named(Self.space))) { _, r in model.occludedRect = r }
                })
                .padding(Theme.Space.m)
        }
        .coordinateSpace(name: Self.space)
        .background(Theme.Color.bgSunken)
        .onAppear {
            model.select(selected)
            model.resume()
        }
        .onDisappear { model.suspend() }
        .onChange(of: graph) { _, new in model.update(graph: new) }
        .onChange(of: selected) { _, new in model.select(new) }
        .onChange(of: vault) { _, new in model.reset(graph: graph, vault: new) }
        .onChange(of: filter) { _, new in model.setFilter(new) }
    }

    private static let space = "graph"

    private func bindCallbacks() {
        model.onSelect = onSelect
        model.onType = { text in
            filter += text
            guard !filterFocused else { return }
            filterFocused = true
            Self.placeCaretAtEndSoon()
        }
        model.onEscape = { if !filter.isEmpty { filter = "" } }
    }
}

/// Redraws on every display frame while something moves, otherwise only when told.
struct GraphCanvas: View {
    let model: GraphModel
    @ObservedObject var redraw: GraphRedraw

    var body: some View {
        let revision = redraw.revision
        TimelineView(.animation(paused: !redraw.isAnimating)) { timeline in
            // The closure must capture something that changes. A closure over `model` alone
            // compares equal to the last one and SwiftUI skips the redraw.
            let stamp = GraphModel.DrawStamp(date: timeline.date, revision: revision)
            Canvas { context, size in model.draw(in: &context, size: size, stamp: stamp) }
        }
        .accessibilityElement()
        .accessibilityLabel("Graph")
    }
}

extension GraphView {
    /// Focusing a text field selects all of it, so the next keystroke would replace the
    /// character that started the filter. Collapse the selection once focus has landed.
    static func placeCaretAtEndSoon() {
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            }
        }
    }
}
