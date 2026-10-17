import AppKit
import SwiftUI
import FlamingoDesign

/// Geometry that changes every frame while someone drags a divider, resizes the window or
/// swipes. Kept out of `AppState` so those frames redraw the layout, not every view that
/// reads the shell's state. Widths persist when a drag ends.
@MainActor
final class PanelLayout: ObservableObject {
    @Published var leftWidth = Defaults.sidebarWidth
    @Published var rightWidth = Defaults.inspectorWidth
    @Published var windowWidth: CGFloat = 1200
    @Published var swipeAmount: CGFloat = 0

    static let left: ClosedRange<CGFloat> = 180...480
    static let right: ClosedRange<CGFloat> = 260...720

    func persist() {
        Defaults.sidebarWidth = leftWidth
        Defaults.inspectorWidth = rightWidth
    }
}

/// The hairline between two columns, with a wider invisible grip that resizes the column
/// on its `edge` side. Double-click puts the column back to its default width.
struct ResizeHandle: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    /// Which side of the handle the resized column is on.
    let edge: HorizontalEdge
    let defaultWidth: CGFloat
    var onEnd: () -> Void = {}
    @State private var start: CGFloat?
    @State private var hovering = false

    var body: some View {
        VHairline()
            .overlay {
                Rectangle()
                    .fill(Theme.Color.accent)
                    .frame(width: 2)
                    .opacity(start != nil ? 0.6 : 0)
                    .animation(Theme.Motion.fast, value: start != nil)
            }
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        if inside { NSCursor.resizeLeftRight.set() } else if start == nil { NSCursor.arrow.set() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { v in
                                if start == nil { start = width }
                                let delta = edge == .leading ? v.translation.width : -v.translation.width
                                width = min(max(((start ?? defaultWidth) + delta).rounded(), range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in start = nil; onEnd() }
                    )
                    .onTapGesture(count: 2) { width = defaultWidth; onEnd() }
            }
            .zIndex(1)
    }
}

/// A horizontal hairline that resizes the view above it by dragging. Double-click resets.
struct HeightHandle: View {
    @Binding var height: Double
    let range: ClosedRange<Double>
    let defaultHeight: Double
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 9)
            .overlay {
                Squircle(radius: 1.5).fill(Theme.Color.textTertiary)
                    .frame(width: 28, height: 3)
                    .opacity(start != nil ? 0.9 : 0.35)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.set() } else if start == nil { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        if start == nil { start = height }
                        height = min(max(((start ?? defaultHeight) + v.translation.height).rounded(), range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in start = nil }
            )
            .onTapGesture(count: 2) { height = defaultHeight }
            .help("Drag to resize")
    }
}
