import AppKit
import SwiftUI
import FlamingoDesign

/// The ••• on a pane: dim until the pointer is in that pane, full on hover or while its popover
/// is open. Clicking offers the five layouts as small diagrams.
struct TileHandle: View {
    @EnvironmentObject var state: AppState
    let paneID: DocumentPaneID
    /// The pointer is somewhere in this pane.
    var paneHovering: Bool
    @State private var hovering = false
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: Theme.Size.iconSmall))
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 32, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(open || hovering ? 1 : paneHovering ? Theme.Opacity.rest : Theme.Opacity.dimmed)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fast, value: hovering)
        .animation(Theme.Motion.fast, value: paneHovering)
        .help("Arrange Panes")
        .accessibilityLabel("Arrange Panes")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            TileLayoutPicker(current: state.tiling.arrangement.kind) { layout in
                open = false
                state.activatePane(paneID)
                state.setLayout(layout, from: paneID)
            }
        }
    }
}

/// Five diagrams in a row, no words. ←/→ move, Return picks.
struct TileLayoutPicker: View {
    let current: TileLayout
    let pick: (TileLayout) -> Void
    @State private var highlighted: TileLayout
    @FocusState private var focused: Bool

    init(current: TileLayout, pick: @escaping (TileLayout) -> Void) {
        self.current = current; self.pick = pick
        _highlighted = State(initialValue: current)
    }

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(TileLayout.allCases) { layout in
                Button { pick(layout) } label: {
                    TileDiagram(layout: layout, current: layout == current)
                        .frame(width: 40, height: 30)
                        .background(Squircle(radius: Theme.Radius.s).fill(Theme.Color.hover).opacity(layout == highlighted ? 1 : 0))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { highlighted = layout } }
                .help(layout.title)
                .accessibilityLabel(layout.title)
                .accessibilityAddTraits(layout == current ? .isSelected : [])
            }
        }
        .padding(Theme.Space.s)
        .animation(Theme.Motion.fast, value: highlighted)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.return) { pick(highlighted); return .handled }
    }

    private func move(_ step: Int) {
        let all = TileLayout.allCases, i = all.firstIndex(of: highlighted) ?? 0
        highlighted = all[min(max(i + step, 0), all.count - 1)]
    }
}

/// A layout drawn small: an outline and its tiles. The current layout is the accent's.
struct TileDiagram: View {
    let layout: TileLayout
    var current = false

    private static let outline = CGSize(width: 28, height: 20), inset: CGFloat = 3

    var body: some View {
        let color = current ? Theme.Color.accent : Theme.Color.textTertiary
        let inner = CGSize(width: Self.outline.width - 2 * Self.inset, height: Self.outline.height - 2 * Self.inset)
        ZStack(alignment: .topLeading) {
            Squircle(radius: Theme.Radius.s).strokeBorder(color, lineWidth: 1)
            ForEach(Array(layout.frames(in: inner, .defaults(for: layout)).enumerated()), id: \.offset) { _, r in
                Squircle(radius: 2).fill(color.opacity(current ? 0.9 : 0.55))
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX + Self.inset, y: r.minY + Self.inset)
            }
        }
        .frame(width: Self.outline.width, height: Self.outline.height, alignment: .topLeading)
    }
}

/// The hairline between two tiles with a wider invisible grip. Dragging moves the line; double-click
/// puts the layout's lines back. Offered to VoiceOver as an adjustable control.
struct TileDividerHandle: View {
    let spec: TileDividerSpec
    let layout: TileLayout
    let size: CGSize
    @ObservedObject var geometry: TileGeometry
    @State private var start: Double?

    private var vertical: Bool { spec.axis == .column }

    var body: some View {
        Rectangle().fill(Theme.Color.hairline)
            .frame(width: spec.rect.width, height: spec.rect.height)
            .overlay {
                Rectangle().fill(Theme.Color.accent)
                    .frame(width: vertical ? 2 : nil, height: vertical ? nil : 2)
                    .opacity(start != nil ? 0.6 : 0)
                    .animation(Theme.Motion.fast, value: start != nil)
            }
            .overlay {
                Color.clear
                    .frame(width: vertical ? 9 : spec.rect.width, height: vertical ? spec.rect.height : 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set() }
                        else if start == nil { NSCursor.arrow.set() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { v in
                                if start == nil { start = current }
                                move(to: (start ?? current) + Double((vertical ? v.translation.width : v.translation.height) / spec.usable))
                            }
                            .onEnded { _ in start = nil; geometry.persist() }
                    )
                    .onTapGesture(count: 2) { geometry.reset(layout) }
            }
            .zIndex(1)
            .accessibilityElement()
            .accessibilityLabel("Pane divider")
            .accessibilityValue("\(Int((current * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: move(to: current + 0.02); geometry.persist()
                case .decrement: move(to: current - 0.02); geometry.persist()
                @unknown default: break
                }
            }
    }

    private var fractions: TileFractions { geometry.fractions(for: layout).clamped(layout, size: size) }
    private var current: Double { (vertical ? fractions.columns : fractions.rows)[spec.index] }

    private func move(to value: Double) {
        var f = fractions
        if vertical { f.columns[spec.index] = value } else { f.rows[spec.index] = value }
        geometry.fractions[layout] = f.clamped(layout, size: size)
    }
}
