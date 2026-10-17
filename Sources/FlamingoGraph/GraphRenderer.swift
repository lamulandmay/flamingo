import SwiftUI
import CoreGraphics
import FlamingoCore
import FlamingoDesign

/// Draws a `GraphFrame` into a `Canvas`. One instance per canvas. Main thread only.
///
/// `draw` is a pure function of the frame plus caches keyed by `frame.topology.token` (family
/// buckets, trail-under-link edges, label priority, per-node label sizes), rebuilt when the token
/// changes. Measured label text is also cached by file name across topologies.
///
/// Cost model: every node, edge and label is culled to the viewport, then batched. Edges go into
/// one path per (kind, emphasis, opacity) bucket and nodes into one path per (color, opacity)
/// bucket, so a 1,000-node / 3,000-edge frame is a few dozen fill and stroke calls plus one text
/// draw per visible label. Colors are resolved once per appearance, not per node.
final class GraphRenderer {

    /// Geometry and opacity. Colors and fonts all come from `Theme`; these are the graph's own
    /// proportions, which `Theme` has no tokens for.
    enum Style {
        /// Smallest on-screen node radius, so a zoomed-out graph still reads as a field of dots.
        static let minScreenRadius: CGFloat = 1.5
        /// Above 1x zoom, radius grows as zoom^damping instead of zoom: zooming in separates
        /// nodes instead of inflating them.
        static let zoomDamping: CGFloat = 0.6
        static let nodeOpacity = 0.7
        static let linkOpacity = 0.25
        static let trailOpacity = 0.15
        /// Edges touching the hovered node, at `hoverAmount` 1.
        static let linkFocusOpacity = 0.6
        static let trailFocusOpacity = 0.4
        /// Edges touching the selected node.
        static let accentLinkOpacity = 0.6
        static let accentTrailOpacity = 0.45
        static let selectionRingOpacity = 0.55
        static let pinRingOpacity = 0.55
        /// Below 1x zoom, resting edges fade toward this fraction of their opacity (reached at
        /// `edgeFadeZoom`) so a zoomed-out graph reads as a field of nodes, not a mesh. Width stays 1pt.
        static let edgeFadeFloor = 0.55
        static let edgeFadeZoom: CGFloat = 0.25
        static let edgeWidth: CGFloat = Theme.Size.hairline
        static let trailDash: [CGFloat] = [3, 3]
        /// Folder containment is structure, not a connection: drawn at this share of a link.
        static let folderEdgeFactor = 0.55
        /// Selection ring sits this far outside the node.
        static let ringGap: CGFloat = 3
        /// Pinned marker ring.
        static let pinGap: CGFloat = 2
        /// Between the node's edge and the top of its label.
        static let labelGap: CGFloat = 2
        /// Minimum clear space between two labels.
        static let labelPadding: CGFloat = 2
        static let labelMaxCharacters = 28
        /// Lower bound on a label's height (11pt text), for the pre-measure collision probe.
        static let labelSliverHeight: CGFloat = 11
        /// Nodes this far outside the canvas still count as visible (rings, antialiasing).
        static let cullMargin: CGFloat = 8
        /// Labels below this opacity are not laid out at all.
        static let labelCutoff = 0.02
        /// Detail below this opacity contributes neither geometry nor labels.
        static let detailCutoff = 0.02
        /// Keeps emerging nodes and edges batched as their detail opacity changes.
        static let detailLevels = 16
        /// Suggested (dashed) edges are drawn only for the selected or hovered node, and only
        /// its strongest few. Explicit links always draw.
        static let suggestionsShown = 5
        /// With a file selected (and on screen), everything outside it and its neighbors
        /// recedes to this, as Obsidian's graph does on hover.
        static let selectionDim = 0.18
        /// The most connected nodes on screen are always named, at any zoom.
        static let alwaysLabeled = 12
        /// Zoom at which more names start fading in, most connected first, until every node
        /// is named at `GraphCamera.labelZoom`.
        static let labelRampStart: CGFloat = 0.45
        /// Names fade in over this many places in the priority order as zoom grows.
        static let labelFadeSpan = 4.0
        /// Past this many visible nodes, zoom-driven names skip the node-obstacle pass.
        static let obstacleLimit = 4000
    }

    /// What the last `draw` did. For tests and the harness.
    struct Stats: Equatable {
        var visibleNodes = 0
        var drawnEdges = 0
        var labels = 0
        /// Fill and stroke calls issued (batches), excluding labels.
        var batches = 0
    }

    private(set) var stats = Stats()

    init() {}

    // MARK: - Geometry shared with hit testing

    /// Multiplier from world radius to screen radius at `zoom` (before the minimum clamp).
    static func radiusScale(zoom: CGFloat) -> CGFloat {
        guard zoom.isFinite, zoom > 0 else { return 1 }
        return zoom <= 1 ? zoom : pow(zoom, Style.zoomDamping)
    }

    /// Multiplier on resting edge opacity at `zoom`: 1 at 1x and above, `edgeFadeFloor` when far out.
    static func edgeFade(zoom: CGFloat) -> Double {
        guard zoom.isFinite, zoom < 1 else { return 1 }
        let t = Double(max(0, min(1, (zoom - Style.edgeFadeZoom) / (1 - Style.edgeFadeZoom))))
        return Style.edgeFadeFloor + (1 - Style.edgeFadeFloor) * t
    }

    /// On-screen radius of a node. Use this for hit testing so it matches what's drawn.
    static func screenRadius(worldRadius: Double, zoom: CGFloat,
                             detailOpacity: Double = 1, isFolder: Bool = false) -> CGFloat {
        let r = CGFloat(worldRadius) * radiusScale(zoom: zoom)
        let base = r >= Style.minScreenRadius ? r : Style.minScreenRadius
        return isFolder ? base * CGFloat(0.8 + 0.2 * clampedDetailOpacity(detailOpacity)) : base
    }

    @inline(__always)
    private static func clampedDetailOpacity(_ opacity: Double) -> Double {
        opacity.isFinite ? min(1, max(0, opacity)) : 0
    }

    // MARK: - Topology cache

    private var token: UUID?
    /// Per node: index into `familyExts` / `palette.families`.
    private var family: [Int] = []
    /// One representative extension per family slot; resolved with `Theme.Color.family(ext:)`.
    private var familyExts: [String] = []
    /// Per edge: a `trail` edge whose pair also has a `link` edge. The link is drawn instead.
    private var shadowed: [Bool] = []
    /// Node indices by degree descending, then index: the label priority after the focus sets.
    private var priority: [Int] = []
    /// Per node: its strongest suggested edges (indices into `topology.edges`).
    private var topSuggestions: [[Int]] = []
    /// Per node: neighbors as drawn at rest. Explicit and folder edges, plus the node's own
    /// strongest suggestions. Hover and selection light these, not every inferred neighbor.
    private var shownNeighbors: [[Int]] = []
    /// `topology.labels`, untruncated.
    private var labelSource: [String] = []
    /// Measured label size; width -1 = not yet measured.
    private var labelSize: [CGSize] = []
    private var labelText: [GraphicsContext.ResolvedText?] = []
    /// Measured labels by file name. Survives topology changes, so a graph rebuild (a file
    /// added, a comment written) doesn't re-measure every visible label.
    private var measured: [String: MeasuredLabel] = [:]
    private struct MeasuredLabel {
        var size: CGSize
        var text: GraphicsContext.ResolvedText?
    }
    private static let measuredLimit = 20_000
    /// Per-frame de-duplication of label candidates.
    private var stamp: [UInt32] = []
    private var generation: UInt32 = 0

    private func rebuild(_ topo: GraphTopology) {
        token = topo.token
        let n = topo.count
        var slots: [String: Int] = [:]
        var exts: [String] = []
        family = [Int](repeating: 0, count: n)
        for i in 0..<n {
            let ext = i < topo.exts.count ? topo.exts[i] : ""
            let key = FileFamily(ext: ext)?.rawValue ?? ""
            if let s = slots[key] { family[i] = s } else {
                slots[key] = exts.count
                family[i] = exts.count
                exts.append(key.isEmpty ? "" : ext)
            }
        }
        familyExts = exts

        // The topology already merges each pair into one edge of its strongest kind.
        shadowed = [Bool](repeating: false, count: topo.edges.count)

        let edges = topo.edges
        var inferred = [[Int]](repeating: [], count: n)
        var shown = [Set<Int>](repeating: [], count: n)
        for (k, e) in edges.enumerated() where e.a < n && e.b < n {
            if e.strokeClass == 1 {
                inferred[e.a].append(k); inferred[e.b].append(k)
            } else {
                shown[e.a].insert(e.b); shown[e.b].insert(e.a)
            }
        }
        topSuggestions = inferred.map { ks in
            Array(ks.sorted { edges[$0].weight != edges[$1].weight ? edges[$0].weight > edges[$1].weight : $0 < $1 }
                .prefix(Style.suggestionsShown))
        }
        for i in 0..<n {
            for k in topSuggestions[i] { shown[i].insert(edges[k].a == i ? edges[k].b : edges[k].a) }
        }
        shownNeighbors = shown.map { $0.sorted() }
        let degree = topo.neighbors.map(\.count)
        let calmDegree = shownNeighbors.map(\.count)
        priority = Array(0..<n).sorted {
            calmDegree[$0] != calmDegree[$1] ? calmDegree[$0] > calmDegree[$1]
                : degree[$0] != degree[$1] ? degree[$0] > degree[$1] : $0 < $1
        }
        labelSource = topo.labels
        if measured.count > Self.measuredLimit { measured.removeAll() }
        labelSize = [CGSize](repeating: CGSize(width: -1, height: -1), count: n)
        labelText = [GraphicsContext.ResolvedText?](repeating: nil, count: n)
        stamp = [UInt32](repeating: 0, count: n)
        generation = 0
        palette = nil
    }

    // MARK: - Palette

    private struct Palette {
        var bg: Color.Resolved
        var text: Color.Resolved
        var secondary: Color.Resolved
        var accent: Color.Resolved
        var families: [Color.Resolved]
        /// Ghost nodes (no file behind them).
        var tertiary: Color.Resolved
    }

    private struct PaletteKey: Equatable {
        var token: UUID?
        var scheme: ColorScheme
        var contrast: ColorSchemeContrast
    }

    private var palette: Palette?
    private var paletteKey: PaletteKey?

    private func resolvePalette(_ env: EnvironmentValues) -> Palette {
        let key = PaletteKey(token: token, scheme: env.colorScheme, contrast: env.colorSchemeContrast)
        if let p = palette, paletteKey == key { return p }
        let p = Palette(
            bg: Theme.Color.bgSunken.resolve(in: env),
            text: Theme.Color.text.resolve(in: env),
            secondary: Theme.Color.textSecondary.resolve(in: env),
            accent: Theme.Color.accent.resolve(in: env),
            families: familyExts.map { Theme.Color.family(ext: $0).resolve(in: env) },
            tertiary: Theme.Color.textTertiary.resolve(in: env))
        palette = p
        paletteKey = key
        return p
    }

    @inline(__always)
    private static func shade(_ c: Color.Resolved, _ alpha: Double) -> GraphicsContext.Shading {
        var c = c
        c.opacity *= Float(alpha)
        return .color(Color(c))
    }

    // MARK: - Per-frame buffers

    private var sx: [CGFloat] = []
    private var sy: [CGFloat] = []
    private var sr: [CGFloat] = []
    private var detailOpacity: [Double] = []
    private var detailLevel: [Int] = []
    private var detailBatchCount = 1
    private var visible: [Bool] = []
    private var flags: [UInt8] = []
    private var placer = LabelPlacer()
    /// Labels the last `draw` showed, in placement order, and their screen rects.
    private(set) var placedNode: [Int] = []
    private(set) var placedRect: [CGRect] = []
    private var placedAlpha: [Double] = []
    private var placedStrong: [Bool] = []

    private enum Flag {
        /// Hovered (or dragged) node or one of its neighbors.
        static let focusSet: UInt8 = 1 << 0
        static let focusNode: UInt8 = 1 << 1
        /// Selected node or one of its neighbors.
        static let selSet: UInt8 = 1 << 2
        static let filtered: UInt8 = 1 << 3
    }

    private func ensureBuffers(_ n: Int) {
        if sx.count != n {
            sx = [CGFloat](repeating: 0, count: n)
            sy = [CGFloat](repeating: 0, count: n)
            sr = [CGFloat](repeating: 0, count: n)
            detailOpacity = [Double](repeating: 1, count: n)
            detailLevel = [Int](repeating: 0, count: n)
            visible = [Bool](repeating: false, count: n)
            flags = [UInt8](repeating: 0, count: n)
        }
    }

    /// Projects nodes to the screen and culls them. Fills `sx`, `sy`, `sr`, `visible`.
    /// Returns the number of visible nodes.
    @discardableResult
    func project(_ frame: GraphFrame, size: CGSize) -> Int {
        let n = min(frame.topology.count, frame.positions.count, frame.topology.radius.count)
        ensureBuffers(n)
        let cam = frame.camera
        let zoom = (cam.zoom.isFinite && cam.zoom > 0) ? cam.zoom : 1
        let scale = Self.radiusScale(zoom: zoom)
        let minR = Style.minScreenRadius
        let cx = cam.center.x, cy = cam.center.y
        let hw = size.width / 2, hh = size.height / 2
        let m = Style.cullMargin
        let maxX = size.width + m, maxY = size.height + m
        let pos = frame.positions, rad = frame.topology.radius
        let detail = frame.detailOpacity, folders = frame.topology.isFolder
        detailBatchCount = 1
        var count = 0
        for i in 0..<n {
            let opacity = i < detail.count ? Self.clampedDetailOpacity(detail[i]) : 1
            detailOpacity[i] = opacity
            detailLevel[i] = max(1, Int((opacity * Double(Style.detailLevels)).rounded())) - 1
            if opacity >= Style.detailCutoff && opacity < 1 { detailBatchCount = Style.detailLevels }
            let p = pos[i]
            let x = (p.x - cx) * zoom + hw
            let y = (p.y - cy) * zoom + hh
            var r = CGFloat(rad[i]) * scale
            if !(r >= minR) { r = minR }
            if i < folders.count && folders[i] { r *= CGFloat(0.8 + 0.2 * opacity) }
            sx[i] = x; sy[i] = y; sr[i] = r
            // NaN fails every comparison, so a NaN position is never visible.
            let v = opacity >= Style.detailCutoff && x + r >= -m && x - r <= maxX && y + r >= -m && y - r <= maxY
            visible[i] = v
            if v { count += 1 }
        }
        return count
    }

    @inline(__always)
    private func detailBucket(_ node: Int) -> Int {
        detailBatchCount == 1 ? 0 : detailLevel[node]
    }

    @inline(__always)
    private func detailBatchOpacity(_ bucket: Int) -> Double {
        detailBatchCount == 1 ? 1 : Double(bucket + 1) / Double(Style.detailLevels)
    }

    /// Indices of nodes `draw` would consider on screen (including the cull margin).
    func visibleNodes(_ frame: GraphFrame, size: CGSize) -> [Int] {
        project(frame, size: size)
        var out: [Int] = []
        for i in 0..<visible.count where visible[i] { out.append(i) }
        return out
    }

    // MARK: - Draw

    func draw(_ frame: GraphFrame, in context: inout GraphicsContext, size: CGSize) {
        let topo = frame.topology
        if token != topo.token { rebuild(topo) }
        let pal = resolvePalette(context.environment)
        stats = Stats()
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return }
        let bounds = CGRect(origin: .zero, size: size)
        context.fill(Path(bounds), with: .color(Color(pal.bg)))

        stats.visibleNodes = project(frame, size: size)
        let n = sx.count
        guard n > 0 else { return }

        // Roles.
        for i in 0..<n { flags[i] = 0 }
        let sel = Self.valid(frame.selected, n)
        let hov = Self.valid(frame.hovered, n)
        let drag = Self.valid(frame.dragging, n)
        let focus = hov ?? drag
        let rawHover = frame.hoverAmount.isFinite ? min(max(frame.hoverAmount, 0), 1) : 0
        let focusAmount = hov != nil ? rawHover : (drag != nil ? 1 : 0)
        let focusOn = focus != nil && focusAmount > 0.001
        // A calm frame lights only what is drawn; a local graph shows every neighbor.
        let neighbors = frame.calm ? shownNeighbors : topo.neighbors
        if let f = focus {
            flags[f] |= Flag.focusSet | Flag.focusNode
            for j in neighbors[f] where j < n { flags[j] |= Flag.focusSet }
        }
        if let d = drag { flags[d] |= Flag.focusSet | Flag.focusNode }
        if let s = sel {
            flags[s] |= Flag.selSet
            for j in neighbors[s] where j < n { flags[j] |= Flag.selSet }
        }
        if let mask = frame.filterMask {
            for i in 0..<min(n, mask.count) where !mask[i] { flags[i] |= Flag.filtered }
            // The selection is the user's cursor: neither the filter nor hover dims it.
            if let s = sel { flags[s] &= ~Flag.filtered }
        }

        // Opacity levels: bit 0 = dimmed by hover, bit 1 = dimmed by the filter, bit 2 =
        // outside the selection's neighborhood. Hovering hands the dimming over to the hover.
        let dimmed = Theme.Opacity.dimmed
        let hoverDim = focusOn ? 1 - focusAmount * (1 - dimmed) : 1
        let spotlight = frame.calm && sel.map { visible[$0] } == true
        let selDim = spotlight ? 1 - (1 - Style.selectionDim) * (1 - (focusOn ? focusAmount : 0)) : 1
        let levels: [Double] = (0..<8).map { bits in
            (bits & 1 != 0 ? hoverDim : 1) * (bits & 2 != 0 ? dimmed : 1) * (bits & 4 != 0 ? selDim : 1)
        }
        let selNode: Int = sel ?? -1, focusNode: Int = focus ?? -1, dragNode: Int = drag ?? -1
        var suggested = Set<Int>()
        if frame.calm {
            for i in [sel, focus, drag] { if let i, i < topSuggestions.count { suggested.formUnion(topSuggestions[i]) } }
        }

        drawEdges(topo, n: n, size: size, sel: selNode, focus: focusNode, drag: dragNode,
                  focusOn: focusOn, focusAmount: focusAmount, levels: levels, spotlight: spotlight,
                  suggested: frame.calm ? suggested : nil,
                  fade: Self.edgeFade(zoom: frame.camera.zoom), pal: pal, in: &context)
        drawNodes(frame, n: n, sel: selNode, focus: focusNode, drag: dragNode,
                  focusOn: focusOn, focusAmount: focusAmount, levels: levels, spotlight: spotlight, pal: pal, in: &context)
        if let link = frame.link { drawLink(link, n: n, pal: pal, in: &context) }
        if let c = frame.celebration { drawCelebration(c, n: n, in: &context) }
        if let caption = frame.caption {
            let text = context.resolve(Text(caption).font(Theme.Font.mono).foregroundColor(Color(pal.secondary)))
            context.draw(text, at: CGPoint(x: Theme.Space.l, y: size.height - Theme.Space.l), anchor: .bottomLeading)
        }
        drawLabels(frame, n: n, bounds: bounds, sel: selNode, focus: focusNode, drag: dragNode,
                   focusAmount: focusAmount, levels: levels, focusOn: focusOn, spotlight: spotlight,
                   neighbors: neighbors, pal: pal, in: &context)
    }

    /// The connection being drawn with ⌥-drag: a dashed accent line from the node, snapping
    /// to the file under the pointer, which gets a ring.
    private func drawLink(_ link: (from: Int, to: CGPoint, over: Int?), n: Int, pal: Palette,
                          in context: inout GraphicsContext) {
        guard link.from < n, link.from < sx.count else { return }
        let start = CGPoint(x: sx[link.from], y: sy[link.from])
        var end = link.to
        if let o = link.over, o < n { end = CGPoint(x: sx[o], y: sy[o]) }
        var line = Path()
        line.move(to: start)
        line.addLine(to: end)
        context.stroke(line, with: Self.shade(pal.accent, 0.9),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 3]))
        if let o = link.over, o < n {
            let r = sr[o] + Style.ringGap + 1
            context.stroke(Path(ellipseIn: CGRect(x: end.x - r, y: end.y - r, width: 2 * r, height: 2 * r)),
                           with: Self.shade(pal.accent, 0.9), lineWidth: 1.5)
        }
    }

    /// A new connection: a line in the thought's tint grows from rim to rim with a drop of
    /// light at its head, rings ripple out where it leaves and lands, both ends stay ringed
    /// while it holds, and everything fades into the ordinary edge underneath.
    private func drawCelebration(_ c: GraphFrame.Celebration, n: Int, in context: inout GraphicsContext) {
        guard c.from < n, c.from < sx.count else { return }
        let T = CelebrationTime.self
        let tint = Theme.Color.thought(c.level)
        let level = CGFloat(c.level)
        let alone = c.to.isEmpty
        let shown = 1 - Self.clamp01((c.t - T.fadeStart(alone: alone)) / T.fade)
        let a = CGPoint(x: sx[c.from], y: sy[c.from])

        func ripple(_ p: CGPoint, _ radius: CGFloat, since t0: Double) {
            let dt = c.t - t0
            guard dt >= 0, dt < T.ripple else { return }
            let e = Self.easeOut(dt / T.ripple)
            let r = radius + Style.ringGap + CGFloat(e) * (14 + 4 * level)
            context.stroke(Path(ellipseIn: Self.circle(p.x, p.y, r)), with: .color(tint.opacity((1 - e) * 0.8)),
                           style: StrokeStyle(lineWidth: 1.5 + CGFloat(1 - e)))
        }
        func ring(_ p: CGPoint, _ radius: CGFloat, since t0: Double) {
            let on = Self.clamp01((c.t - t0) / 0.15) * shown
            guard on > 0 else { return }
            context.stroke(Path(ellipseIn: Self.circle(p.x, p.y, radius + Style.ringGap)),
                           with: .color(tint.opacity(0.9 * on)), lineWidth: 1.5)
        }

        ripple(a, sr[c.from], since: T.depart)
        ring(a, sr[c.from], since: T.depart)
        for b in c.to where b < n && b < sx.count {
            let end = CGPoint(x: sx[b], y: sy[b])
            let dx = end.x - a.x, dy = end.y - a.y
            let d = max(hypot(dx, dy), 0.001)
            let ux = dx / d, uy = dy / d
            let from = CGPoint(x: a.x + ux * (sr[c.from] + Style.ringGap), y: a.y + uy * (sr[c.from] + Style.ringGap))
            let to = CGPoint(x: end.x - ux * (sr[b] + Style.ringGap), y: end.y - uy * (sr[b] + Style.ringGap))
            let p = CGFloat(Self.easeOut((c.t - T.depart) / T.travel))
            guard p > 0, d > sr[c.from] + sr[b] + 2 * Style.ringGap else { continue }
            let head = CGPoint(x: from.x + (to.x - from.x) * p, y: from.y + (to.y - from.y) * p)
            var line = Path()
            line.move(to: from)
            line.addLine(to: head)
            context.stroke(line, with: .color(tint.opacity(0.95 * shown)),
                           style: StrokeStyle(lineWidth: 2 + 0.5 * level, lineCap: .round))
            if p < 1 {
                let r: CGFloat = 3 + 0.5 * level
                var halo = context
                halo.addFilter(.blur(radius: 5))
                halo.fill(Path(ellipseIn: Self.circle(head.x, head.y, 2.2 * r)), with: .color(tint.opacity(0.35 + 0.15 * Double(level))))
                context.fill(Path(ellipseIn: Self.circle(head.x, head.y, r)), with: .color(tint))
            }
            ripple(end, sr[b], since: T.arrive)
            ring(end, sr[b], since: T.arrive)
        }
        stats.batches += 1
    }

    private static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
    private static func easeOut(_ x: Double) -> Double { let u = 1 - clamp01(x); return 1 - u * u * u }

    @inline(__always)
    private static func valid(_ i: Int?, _ n: Int) -> Int? {
        guard let i, i >= 0, i < n else { return nil }
        return i
    }

    // MARK: Edges

    /// `suggested` nil draws every suggested edge (a local graph); otherwise only these.
    private func drawEdges(_ topo: GraphTopology, n: Int, size: CGSize, sel: Int, focus: Int, drag: Int,
                           focusOn: Bool, focusAmount: Double, levels: [Double], spotlight: Bool,
                           suggested: Set<Int>?, fade: Double, pal: Palette,
                           in context: inout GraphicsContext) {
        // Bucket = (kind * 32 + emphasis * 8 + level) * detailCount + detail.
        // Emphasis: 0 normal, 1 focus, 2 a link of the selection (accent), 3 a suggestion of
        // the selection (grey, at focus strength). Allocate only occupied detail buckets.
        let detailCount = detailBatchCount
        var paths = [CGMutablePath?](repeating: nil, count: 96 * detailCount)

        let edges = topo.edges
        let m = Style.cullMargin
        let maxX = size.width + m, maxY = size.height + m
        let ringGap = Style.ringGap
        var drawn = 0
        for k in 0..<edges.count {
            if shadowed[k] { continue }
            let e = edges[k]
            if e.strokeClass == 1, let suggested, !suggested.contains(k) { continue }
            let a = e.a, b = e.b
            if a >= n || b >= n { continue }
            if min(detailOpacity[a], detailOpacity[b]) < Style.detailCutoff { continue }
            let ax = sx[a], ay = sy[a], bx = sx[b], by = sy[b]
            if (ax < -m && bx < -m) || (ax > maxX && bx > maxX)
                || (ay < -m && by < -m) || (ay > maxY && by > maxY) { continue }
            let dx = bx - ax, dy = by - ay
            let d = (dx * dx + dy * dy).squareRoot()
            var ra = sr[a], rb = sr[b]
            if a == sel { ra += ringGap }
            if b == sel { rb += ringGap }
            // Also rejects NaN.
            if !(d > ra + rb + 0.5) { continue }
            let ux = dx / d, uy = dy / d

            let touchesFocus = a == focus || b == focus || a == drag || b == drag
            let touchesSel = a == sel || b == sel
            let emphasis = touchesSel ? (e.strokeClass == 0 ? 2 : 3) : (touchesFocus ? 1 : 0)
            var level = 0
            if focusOn && !touchesFocus { level |= 1 }
            if (flags[a] | flags[b]) & Flag.filtered != 0 { level |= 2 }
            if spotlight && !touchesSel && !(focusOn && touchesFocus) { level |= 4 }
            let detail = min(detailBucket(a), detailBucket(b))
            let bucket = (e.strokeClass * 32 + emphasis * 8 + level) * detailCount + detail
            if paths[bucket] == nil { paths[bucket] = CGMutablePath() }
            let path = paths[bucket]!
            path.move(to: CGPoint(x: ax + ux * ra, y: ay + uy * ra))
            path.addLine(to: CGPoint(x: bx - ux * rb, y: by - uy * rb))
            drawn += 1
        }
        stats.drawnEdges = drawn

        let solid = StrokeStyle(lineWidth: Style.edgeWidth)
        let dashed = StrokeStyle(lineWidth: Style.edgeWidth, dash: Style.trailDash)
        // Faint first so emphasis lands on top: level 7...0 within emphasis 0, then 1, 3, 2.
        for emphasis in [0, 1, 3, 2] {
            for level in stride(from: 7, through: 0, by: -1) {
                for kind in stride(from: 2, through: 0, by: -1) {
                    // 0 explicit: solid. 1 inferred: dashed. 2 folder containment: solid, fainter.
                    let isLink = kind != 1
                    let structural = kind == 2 ? Style.folderEdgeFactor : 1
                    let color: Color.Resolved
                    var alpha: Double
                    switch emphasis {
                    case 2:
                        color = pal.accent
                        alpha = isLink ? Style.accentLinkOpacity : Style.accentTrailOpacity
                    case 3:
                        color = pal.secondary
                        alpha = isLink ? Style.linkFocusOpacity : Style.trailFocusOpacity
                    case 1:
                        color = pal.secondary
                        let lo = (isLink ? Style.linkOpacity : Style.trailOpacity) * fade
                        let hi = isLink ? Style.linkFocusOpacity : Style.trailFocusOpacity
                        alpha = lo + (hi - lo) * focusAmount
                    default:
                        color = pal.secondary
                        alpha = (isLink ? Style.linkOpacity : Style.trailOpacity) * fade
                    }
                    alpha *= levels[level] * structural
                    for detail in 0..<detailCount {
                        let bucket = (kind * 32 + emphasis * 8 + level) * detailCount + detail
                        guard let path = paths[bucket] else { continue }
                        context.stroke(Path(path), with: Self.shade(color, alpha * detailBatchOpacity(detail)),
                                       style: isLink ? solid : dashed)
                        stats.batches += 1
                    }
                }
            }
        }
    }

    // MARK: Nodes

    private func drawNodes(_ frame: GraphFrame, n: Int, sel: Int, focus: Int, drag: Int,
                           focusOn: Bool, focusAmount: Double, levels: [Double], spotlight: Bool, pal: Palette,
                           in context: inout GraphicsContext) {
        let families = pal.families.count
        let accentSlot = families
        // Missing files draw as hollow rings: a link to something that isn't there yet.
        let ghostSlot = families + 1
        // Folders are hollow too, in the secondary color.
        let folderSlot = families + 2
        let missing = frame.topology.missing
        let isFolder = frame.topology.isFolder
        let detailCount = detailBatchCount
        let bucketCount = (families + 3) * 8 * detailCount
        var paths = [CGMutablePath?](repeating: nil, count: bucketCount)

        for i in 0..<n where visible[i] {
            if i == sel || i == focus || i == drag { continue }
            let f = flags[i]
            // Neighbors of the selection keep their family colour; only the selection is coral.
            let slot = i < isFolder.count && isFolder[i] ? folderSlot : (i < missing.count && missing[i] ? ghostSlot : family[i])
            let level = nodeLevel(f, focusOn: focusOn, spotlight: spotlight)
            let r = sr[i]
            let bucket = (slot * 8 + level) * detailCount + detailBucket(i)
            if paths[bucket] == nil { paths[bucket] = CGMutablePath() }
            paths[bucket]!.addEllipse(in: CGRect(x: sx[i] - r, y: sy[i] - r, width: r + r, height: r + r))
        }
        for level in stride(from: 7, through: 0, by: -1) {
            for slot in 0...folderSlot {
                for detail in 0..<detailCount {
                    let bucket = (slot * 8 + level) * detailCount + detail
                    guard let path = paths[bucket] else { continue }
                    let alpha = levels[level] * detailBatchOpacity(detail)
                    if slot == folderSlot {
                        context.stroke(Path(path), with: Self.shade(pal.secondary, 0.8 * alpha),
                                       lineWidth: Style.edgeWidth * 1.5)
                    } else if slot == ghostSlot {
                        context.stroke(Path(path), with: Self.shade(pal.tertiary, alpha),
                                       lineWidth: Style.edgeWidth)
                    } else {
                        let color = slot == accentSlot ? pal.accent : pal.families[slot]
                        context.fill(Path(path), with: Self.shade(color, Style.nodeOpacity * alpha))
                    }
                    stats.batches += 1
                }
            }
        }

        // Pinned markers: one ring path per dimming and detail level.
        if !frame.pinned.isEmpty {
            var rings = [CGMutablePath?](repeating: nil, count: 8 * detailCount)
            let gap = Style.pinGap
            for i in frame.pinned where i >= 0 && i < n && visible[i] && i != sel {
                let level = nodeLevel(flags[i], focusOn: focusOn, spotlight: spotlight)
                let r = sr[i] + gap
                let bucket = level * detailCount + detailBucket(i)
                if rings[bucket] == nil { rings[bucket] = CGMutablePath() }
                rings[bucket]!.addEllipse(in: CGRect(x: sx[i] - r, y: sy[i] - r, width: r + r, height: r + r))
            }
            let style = StrokeStyle(lineWidth: Style.edgeWidth)
            for level in stride(from: 7, through: 0, by: -1) {
                for detail in 0..<detailCount {
                    guard let p = rings[level * detailCount + detail] else { continue }
                    context.stroke(Path(p),
                                   with: Self.shade(pal.secondary, Style.pinRingOpacity * levels[level] * detailBatchOpacity(detail)),
                                   style: style)
                    stats.batches += 1
                }
            }
        }

        // The few nodes drawn on their own, on top: dragged, hovered, then selected.
        var specials: [Int] = []
        if drag >= 0, drag != sel { specials.append(drag) }
        if focus >= 0, focus != sel, focus != drag { specials.append(focus) }
        for i in specials where visible[i] {
            let f = flags[i]
            let color = pal.families[family[i]]
            let strength = i == drag ? 1 : focusAmount
            var alpha = Style.nodeOpacity + (1 - Style.nodeOpacity) * strength
            if f & Flag.filtered != 0 { alpha *= levels[2] }
            alpha *= detailOpacity[i]
            let shape = Path(ellipseIn: Self.circle(sx[i], sy[i], sr[i]))
            if isFolder[i] || missing[i] { context.stroke(shape, with: Self.shade(color, alpha), lineWidth: Style.edgeWidth * 1.5) }
            else { context.fill(shape, with: Self.shade(color, alpha)) }
            stats.batches += 1
        }
        if sel >= 0, visible[sel] {
            // Never dimmed: see the filter note in `draw`.
            let r = sr[sel]
            let shape = Path(ellipseIn: Self.circle(sx[sel], sy[sel], r))
            if isFolder[sel] || missing[sel] { context.stroke(shape, with: Self.shade(pal.accent, detailOpacity[sel]), lineWidth: Style.edgeWidth * 1.5) }
            else { context.fill(shape, with: Self.shade(pal.accent, detailOpacity[sel])) }
            context.stroke(Path(ellipseIn: Self.circle(sx[sel], sy[sel], r + Style.ringGap)),
                           with: Self.shade(pal.accent, Style.selectionRingOpacity * detailOpacity[sel]),
                           style: StrokeStyle(lineWidth: Style.edgeWidth))
            stats.batches += 2
        }
        for i in frame.multiSelected where i >= 0 && i < n && visible[i] {
            context.stroke(Path(ellipseIn: Self.circle(sx[i], sy[i], sr[i] + Style.ringGap + 3)),
                           with: Self.shade(pal.accent, detailOpacity[i]), lineWidth: 2)
            stats.batches += 1
        }
        if let p = frame.pulse, visible.indices.contains(p.node), visible[p.node] {
            // Ease-out ring: grows ~16pt past the node and fades to nothing.
            let e = 1 - pow(1 - p.progress, 3)
            let r = sr[p.node] + Style.ringGap + CGFloat(e) * 16
            let alpha = (1 - e) * 0.7 * detailOpacity[p.node]
            context.stroke(Path(ellipseIn: Self.circle(sx[p.node], sy[p.node], r)),
                           with: Self.shade(pal.accent, alpha),
                           style: StrokeStyle(lineWidth: Style.edgeWidth * (1 + CGFloat(1 - e))))
            stats.batches += 1
        }
    }

    /// A node's dimming bits: outside the hover, filtered out, outside the selection's light.
    @inline(__always)
    private func nodeLevel(_ f: UInt8, focusOn: Bool, spotlight: Bool) -> Int {
        var level = 0
        if focusOn && f & Flag.focusSet == 0 { level |= 1 }
        if f & Flag.filtered != 0 { level |= 2 }
        if spotlight && f & Flag.selSet == 0 && !(focusOn && f & Flag.focusSet != 0) { level |= 4 }
        return level
    }

    @inline(__always)
    private static func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGRect {
        CGRect(x: x - r, y: y - r, width: r + r, height: r + r)
    }

    // MARK: Labels

    private func drawLabels(_ frame: GraphFrame, n: Int, bounds: CGRect, sel: Int, focus: Int, drag: Int,
                            focusAmount: Double, levels: [Double], focusOn: Bool, spotlight: Bool,
                            neighbors: [[Int]], pal: Palette, in context: inout GraphicsContext) {
        let labelAmount = frame.labelAmount.isFinite ? min(max(frame.labelAmount, 0), 1) : 0
        // How many names zoom allows: the most connected few always, then more as zoom grows,
        // in priority order, each fading in over `labelFadeSpan` places.
        let visibleCount = stats.visibleNodes
        let zoom = frame.camera.zoom.isFinite ? frame.camera.zoom : 1
        let t = min(1, max(0, Double((zoom - Style.labelRampStart) / (GraphCamera.labelZoom - Style.labelRampStart))))
        let ramp = t * t * (3 - 2 * t)
        var budget = Double(Style.alwaysLabeled) + Double(max(0, visibleCount - Style.alwaysLabeled)) * max(ramp, labelAmount)
        if let limit = frame.labelLimit { budget = min(budget, Double(limit)) }
        let zoomLabels = budget > 0
        guard zoomLabels || sel >= 0 || focus >= 0 || drag >= 0 else { return }

        generation &+= 1
        if generation == 0 { for i in 0..<stamp.count { stamp[i] = 0 }; generation = 1 }
        placer.reset()
        placedNode.removeAll(keepingCapacity: true)
        placedRect.removeAll(keepingCapacity: true)
        placedAlpha.removeAll(keepingCapacity: true)
        placedStrong.removeAll(keepingCapacity: true)

        let ctx = LabelPass(labelAmount: 1, focusAmount: focusAmount, focusOn: focusOn, spotlight: spotlight,
                            levels: levels, sel: sel, focus: focus, drag: drag, bounds: bounds)
        // Priority: selected, dragged, hovered, hovered's neighbors, then (only when zoom labels
        // are showing) selected's neighbors and everything else by degree.
        if sel >= 0 { consider(sel, ctx, &context) }
        if drag >= 0 { consider(drag, ctx, &context) }
        if focus >= 0 {
            consider(focus, ctx, &context)
            for j in neighbors[focus] where j < n { consider(j, ctx, &context) }
        }
        if zoomLabels {
            // Labels that only show because of zoom also keep clear of other nodes; the ones
            // above (selected, dragged, hovered and its neighbors) always show.
            if visibleCount <= Style.obstacleLimit {
                for i in 0..<n where visible[i] {
                    placer.insertObstacle(LabelLayout.obstacleRect(center: CGPoint(x: sx[i], y: sy[i]), radius: sr[i]), owner: i)
                }
            }
            if sel >= 0, frame.labelLimit == nil {
                for j in neighbors[sel] where j < n { consider(j, ctx, &context) }
            }
            var rank = 0.0
            for i in frame.labelOrder ?? priority where i < n && visible[i] {
                guard rank < budget else { break }
                var pass = ctx
                pass.labelAmount = min(1, (budget - rank) / Style.labelFadeSpan)
                consider(i, pass, &context)
                rank += 1
            }
        }

        // Draw faint labels first so the strong ones sit on top where antialiasing touches.
        for pass in 0..<2 {
            for k in 0..<placedNode.count where placedStrong[k] == (pass == 1) {
                let i = placedNode[k]
                guard var text = labelText[i] else { continue }
                text.shading = Self.shade(placedStrong[k] ? pal.text : pal.secondary, placedAlpha[k])
                let r = placedRect[k]
                context.draw(text, at: CGPoint(x: r.midX, y: r.minY), anchor: .top)
            }
        }
        stats.labels = placedNode.count
    }

    private struct LabelPass {
        var labelAmount: Double
        var focusAmount: Double
        var focusOn: Bool
        var spotlight: Bool
        var levels: [Double]
        var sel: Int, focus: Int, drag: Int
        var bounds: CGRect
    }

    private func consider(_ i: Int, _ p: LabelPass, _ context: inout GraphicsContext) {
        if stamp[i] == generation { return }
        stamp[i] = generation
        guard detailOpacity[i] >= Style.detailCutoff else { return }
        // Labels can hang off-screen while their node is barely outside; nodes far outside can't.
        let x = sx[i], y = sy[i]
        guard x.isFinite, y.isFinite else { return }

        let f = flags[i]
        let filterAlpha = f & Flag.filtered != 0 ? p.levels[2] : 1
        var level = 0
        if p.focusOn && f & Flag.focusSet == 0 && i != p.sel { level |= 1 }
        if f & Flag.filtered != 0 { level |= 2 }
        if p.spotlight && f & Flag.selSet == 0 && !(p.focusOn && f & Flag.focusSet != 0) { level |= 4 }
        var alpha = p.labelAmount * p.levels[level]
        var strong = false
        if i == p.sel || i == p.drag {
            alpha = 1
            strong = true
        } else if i == p.focus {
            // Leads the neighborhood: full by the time the hover fade is half done.
            alpha = max(alpha, min(1, 2 * p.focusAmount))
            strong = true
        } else if f & Flag.focusSet != 0 {
            alpha = max(alpha, p.focusAmount * filterAlpha)
        }
        alpha *= detailOpacity[i]
        guard alpha > Style.labelCutoff else { return }

        if labelSize[i].width < 0 {
            // Measuring is the expensive part of a first frame. If even a sliver where the label
            // would go is already taken, the label can't be placed: skip measuring for now.
            let below = CGRect(x: x - 0.5, y: y + sr[i] + Style.labelGap, width: 1, height: Style.labelSliverHeight)
            let above = CGRect(x: x - 0.5, y: y - sr[i] - Style.labelGap - Style.labelSliverHeight, width: 1, height: Style.labelSliverHeight)
            if placer.collides(below, padding: Style.labelPadding, owner: i),
               placer.collides(above, padding: Style.labelPadding, owner: i) { return }
            measure(i, &context)
        }
        let size = labelSize[i]
        guard size.width > 0, size.height > 0 else { return }
        var placed: CGRect?
        for rect in LabelLayout.rects(center: CGPoint(x: x, y: y), radius: sr[i], size: size, gap: Style.labelGap)
        where LabelPlacer.overlaps(rect, p.bounds) {
            if placer.tryPlace(rect, padding: Style.labelPadding, owner: i) { placed = rect; break }
        }
        guard let rect = placed else { return }
        placedNode.append(i)
        placedRect.append(rect)
        placedAlpha.append(alpha)
        placedStrong.append(strong)
    }

    private func measure(_ i: Int, _ context: inout GraphicsContext) {
        let source = i < labelSource.count ? labelSource[i] : ""
        if let m = measured[source] {
            labelSize[i] = m.size
            labelText[i] = m.text
            return
        }
        let s = LabelLayout.truncated(source, limit: Style.labelMaxCharacters)
        var m = MeasuredLabel(size: .zero, text: nil)
        if !s.isEmpty {
            // No foreground style: `shading` is set per draw, so one resolve serves every
            // color, opacity and appearance.
            let text = context.resolve(Text(verbatim: s).font(Theme.Font.small))
            let size = text.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
            m = MeasuredLabel(size: CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up)), text: text)
        }
        measured[source] = m
        labelSize[i] = m.size
        labelText[i] = m.text
    }
}
