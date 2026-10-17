import SwiftUI
import FlamingoCore

/// How the content area is divided between document panes. Everything here is pure except the
/// two small observable objects at the bottom, so frames, growing, shrinking and closing are
/// unit-tested without a window.
enum TileLayout: String, Codable, CaseIterable, Identifiable {
    case single, halves, thirds, mainPlusStack, grid

    var id: String { rawValue }

    var count: Int {
        switch self {
        case .single: 1
        case .halves: 2
        case .thirds, .mainPlusStack: 3
        case .grid: 4
        }
    }

    /// What closing a pane leaves: grid → one and two → halves → single.
    var collapsed: TileLayout {
        switch self {
        case .single, .halves: .single
        case .thirds, .mainPlusStack: .halves
        case .grid: .mainPlusStack
        }
    }

    /// Menus, the palette and `.help` only. Nothing on screen is labelled with these.
    var title: String {
        switch self {
        case .single: "Single"
        case .halves: "Two Side by Side"
        case .thirds: "Three Columns"
        case .mainPlusStack: "One and Two"
        case .grid: "Four"
        }
    }

    var symbol: String {
        switch self {
        case .single: "rectangle"
        case .halves: "rectangle.split.2x1"
        case .thirds: "rectangle.split.3x1"
        case .mainPlusStack: "rectangle.lefthalf.inset.filled"
        case .grid: "rectangle.split.2x2"
        }
    }

    /// ⌃⌥⌘ plus this digit.
    var key: String { String((Self.allCases.firstIndex(of: self) ?? 0) + 1) }

    var columnCount: Int {
        switch self {
        case .single: 1
        case .halves, .mainPlusStack, .grid: 2
        case .thirds: 3
        }
    }

    var rowCount: Int {
        switch self {
        case .single, .halves, .thirds: 1
        case .mainPlusStack, .grid: 2
        }
    }

    /// Width of the line between two tiles.
    static let gap: CGFloat = 1

    /// One rect per slot, tiles one point apart. Slots run left to right; in "one and two" slot
    /// 0 is the tall tile and 1, 2 stack on its right; in the grid they run row by row.
    func frames(in size: CGSize, _ f: TileFractions) -> [CGRect] {
        switch self {
        case .single:
            return [CGRect(origin: .zero, size: size)]
        case .halves, .thirds:
            return Self.spans(size.width, f.columns, count: columnCount).map {
                CGRect(x: $0.start, y: 0, width: $0.length, height: size.height)
            }
        case .mainPlusStack:
            let cols = Self.spans(size.width, f.columns, count: 2), rows = Self.spans(size.height, f.rows, count: 2)
            return [CGRect(x: cols[0].start, y: 0, width: cols[0].length, height: size.height),
                    CGRect(x: cols[1].start, y: rows[0].start, width: cols[1].length, height: rows[0].length),
                    CGRect(x: cols[1].start, y: rows[1].start, width: cols[1].length, height: rows[1].length)]
        case .grid:
            let cols = Self.spans(size.width, f.columns, count: 2), rows = Self.spans(size.height, f.rows, count: 2)
            return [CGRect(x: cols[0].start, y: rows[0].start, width: cols[0].length, height: rows[0].length),
                    CGRect(x: cols[1].start, y: rows[0].start, width: cols[1].length, height: rows[0].length),
                    CGRect(x: cols[0].start, y: rows[1].start, width: cols[0].length, height: rows[1].length),
                    CGRect(x: cols[1].start, y: rows[1].start, width: cols[1].length, height: rows[1].length)]
        }
    }

    /// The draggable lines, one point wide, where tiles meet.
    func dividers(in size: CGSize, _ f: TileFractions) -> [TileDividerSpec] {
        let gap = Self.gap
        switch self {
        case .single:
            return []
        case .halves, .thirds:
            let spans = Self.spans(size.width, f.columns, count: columnCount)
            return (0..<(columnCount - 1)).map { i in
                TileDividerSpec(axis: .column, index: i, usable: size.width - CGFloat(columnCount - 1) * gap,
                                rect: CGRect(x: spans[i].start + spans[i].length, y: 0, width: gap, height: size.height))
            }
        case .mainPlusStack:
            let cols = Self.spans(size.width, f.columns, count: 2), rows = Self.spans(size.height, f.rows, count: 2)
            return [TileDividerSpec(axis: .column, index: 0, usable: size.width - gap,
                                    rect: CGRect(x: cols[0].start + cols[0].length, y: 0, width: gap, height: size.height)),
                    TileDividerSpec(axis: .row, index: 0, usable: size.height - gap,
                                    rect: CGRect(x: cols[1].start, y: rows[0].start + rows[0].length, width: cols[1].length, height: gap))]
        case .grid:
            let cols = Self.spans(size.width, f.columns, count: 2), rows = Self.spans(size.height, f.rows, count: 2)
            return [TileDividerSpec(axis: .column, index: 0, usable: size.width - gap,
                                    rect: CGRect(x: cols[0].start + cols[0].length, y: 0, width: gap, height: size.height)),
                    TileDividerSpec(axis: .row, index: 0, usable: size.height - gap,
                                    rect: CGRect(x: 0, y: rows[0].start + rows[0].length, width: size.width, height: gap))]
        }
    }

    /// `count` consecutive segments of `total`, `count - 1` gaps apart. `boundaries` are the
    /// cumulative edges as fractions of what the gaps leave. Whole points, so lines stay crisp.
    static func spans(_ total: CGFloat, _ boundaries: [Double], count: Int) -> [(start: CGFloat, length: CGFloat)] {
        let usable = max(0, total - CGFloat(count - 1) * gap)
        var edges: [CGFloat] = [0]
        for k in 0..<(count - 1) {
            let f = k < boundaries.count ? boundaries[k] : Double(k + 1) / Double(count)
            edges.append(min(usable, max(edges[k], (CGFloat(f) * usable).rounded())))
        }
        edges.append(usable)
        return (0..<count).map { i in (start: edges[i] + CGFloat(i) * gap, length: edges[i + 1] - edges[i]) }
    }
}

/// A line between two tiles and what dragging it changes.
struct TileDividerSpec: Equatable, Identifiable {
    enum Axis { case column, row }
    var axis: Axis
    /// Which boundary in `TileFractions.columns` or `.rows`.
    var index: Int
    /// The length the fraction is measured against: the extent minus the gaps.
    var usable: CGFloat
    var rect: CGRect
    var id: String { "\(axis)-\(index)" }
}

/// Where the lines between tiles sit: cumulative edges as fractions of the usable extent.
struct TileFractions: Codable, Equatable {
    var columns: [Double]
    var rows: [Double]

    static func defaults(for layout: TileLayout) -> TileFractions {
        switch layout {
        case .single: TileFractions(columns: [], rows: [])
        case .halves: TileFractions(columns: [0.5], rows: [])
        case .thirds: TileFractions(columns: [1.0 / 3, 2.0 / 3], rows: [])
        case .mainPlusStack: TileFractions(columns: [0.6], rows: [0.5])
        case .grid: TileFractions(columns: [0.5], rows: [0.5])
        }
    }

    /// Keeps every tile at least `minW` × `minH`. When the space can't hold that, tiles share it equally.
    func clamped(_ layout: TileLayout, size: CGSize, minW: CGFloat = 220, minH: CGFloat = 160) -> TileFractions {
        let base = Self.defaults(for: layout)
        func fixed(_ values: [Double], expected: Int, total: CGFloat, minimum: CGFloat, segments: Int) -> [Double] {
            guard segments > 1 else { return [] }
            let usable = total - CGFloat(segments - 1) * TileLayout.gap
            let share = (1..<segments).map { Double($0) / Double(segments) }
            guard values.count == expected, values.allSatisfy(\.isFinite), usable > 0 else { return share }
            let floor = Double(minimum / usable)
            if floor * Double(segments) > 1 { return share }
            var out = values
            for k in out.indices { out[k] = max(out[k], (k == 0 ? 0 : out[k - 1]) + floor) }
            for k in out.indices.reversed() { out[k] = min(out[k], (k == out.count - 1 ? 1 : out[k + 1]) - floor) }
            return out
        }
        return TileFractions(
            columns: fixed(columns, expected: base.columns.count, total: size.width, minimum: minW, segments: layout.columnCount),
            rows: fixed(rows, expected: base.rows.count, total: size.height, minimum: minH, segments: layout.rowCount))
    }
}

/// Which layout is showing and which pane sits in which slot. Four panes exist for good; the
/// first `kind.count` of `order` are on screen and the rest keep their documents for undo and
/// for the ⌘\ round trip.
struct TileArrangement: Codable, Equatable {
    var kind: TileLayout = .single
    var order: [DocumentPaneID] = DocumentPaneID.allCases

    var visible: [DocumentPaneID] { Array(order.prefix(kind.count)) }
    func slot(of id: DocumentPaneID) -> Int? { visible.firstIndex(of: id) }

    /// Growing keeps the visible panes where they are and reveals the next ones in `order`.
    /// Shrinking keeps `anchor` and then the other visible panes in slot order, in their old slots' order.
    func resized(to layout: TileLayout, keeping anchor: DocumentPaneID) -> (TileArrangement, revealed: [DocumentPaneID]) {
        let old = visible, n = layout.count
        var result = self
        result.kind = layout
        if n >= old.count { return (result, Array(order[old.count..<n])) }
        var chosen = old.contains(anchor) ? [anchor] + old.filter { $0 != anchor }.prefix(n - 1) : Array(old.prefix(n))
        chosen.sort { old.firstIndex(of: $0)! < old.firstIndex(of: $1)! }
        let dropped = old.filter { !chosen.contains($0) }
        result.order = chosen + dropped + Array(order.dropFirst(old.count))
        return (result, [])
    }

    /// Closing a pane sends it to the back and collapses the layout. Focus goes to the previous
    /// slot, or to the new first slot when the first was closed. Nil for a single pane.
    func closing(_ id: DocumentPaneID) -> (TileArrangement, successor: DocumentPaneID)? {
        let old = visible
        guard kind != .single, let slot = old.firstIndex(of: id) else { return nil }
        var result = self
        result.order = order.filter { $0 != id } + [id]
        result.kind = kind.collapsed
        return (result, slot > 0 ? old[slot - 1] : result.order[0])
    }

    /// The next (or previous) visible pane, wrapping.
    func neighbor(of id: DocumentPaneID, step: Int) -> DocumentPaneID {
        let v = visible
        guard let i = v.firstIndex(of: id) else { return v.first ?? .primary }
        return v[((i + step) % v.count + v.count) % v.count]
    }

    /// An arrangement read from disk may be anything; this one is always a permutation of the four panes.
    func repaired() -> TileArrangement {
        var seen = Set<DocumentPaneID>(), fixed: [DocumentPaneID] = []
        for id in order where seen.insert(id).inserted { fixed.append(id) }
        for id in DocumentPaneID.allCases where seen.insert(id).inserted { fixed.append(id) }
        return TileArrangement(kind: kind, order: fixed)
    }
}

/// The layout the content area is in. Observed by the shell; `geometry` is separate so a
/// divider drag redraws only the container.
@MainActor
final class PaneTiling: ObservableObject {
    @Published private(set) var arrangement = TileArrangement()
    let geometry: TileGeometry

    init(geometry: TileGeometry? = nil) { self.geometry = geometry ?? TileGeometry() }

    func set(_ new: TileArrangement) { if new != arrangement { arrangement = new } }
    var visible: [DocumentPaneID] { arrangement.visible }
}

/// Divider positions per layout, shared by every vault like sidebar widths.
@MainActor
final class TileGeometry: ObservableObject {
    @Published var fractions: [TileLayout: TileFractions]

    init(fractions: [TileLayout: TileFractions]? = nil) { self.fractions = fractions ?? Defaults.tileFractions }

    func fractions(for layout: TileLayout) -> TileFractions { fractions[layout] ?? .defaults(for: layout) }
    func reset(_ layout: TileLayout) { fractions[layout] = nil; persist() }
    func persist() { Defaults.tileFractions = fractions }
}
