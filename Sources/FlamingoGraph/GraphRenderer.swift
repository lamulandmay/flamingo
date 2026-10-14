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
    static func screenRadius(worldRadius: Double, zoom: CGFloat) -> CGFloat {
        let r = CGFloat(worldRadius) * radiusScale(zoom: zoom)
        return r >= Style.minScreenRadius ? r : Style.minScreenRadius
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

        struct Pair: Hashable { var a: Int, b: Int }
        var linked = Set<Pair>()
        for e in topo.edges where e.kind == .link { linked.insert(Pair(a: e.a, b: e.b)) }
        shadowed = topo.edges.map { $0.kind == .trail && linked.contains(Pair(a: $0.a, b: $0.b)) }

        let degree = topo.neighbors.map(\.count)
        priority = Array(0..<n).sorted { degree[$0] != degree[$1] ? degree[$0] > degree[$1] : $0 < $1 }
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
        var count = 0
        for i in 0..<n {
            let p = pos[i]
            let x = (p.x - cx) * zoom + hw
            let y = (p.y - cy) * zoom + hh
            var r = CGFloat(rad[i]) * scale
            if !(r >= minR) { r = minR }
            sx[i] = x; sy[i] = y; sr[i] = r
            // NaN fails every comparison, so a NaN position is never visible.
            let v = x + r >= -m && x - r <= maxX && y + r >= -m && y - r <= maxY
            visible[i] = v
            if v { count += 1 }
        }
        return count
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
        let neighbors = topo.neighbors
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

        // Opacity levels: bit 0 = dimmed by hover, bit 1 = dimmed by the filter.
        let dimmed = Theme.Opacity.dimmed
        let hoverDim = focusOn ? 1 - focusAmount * (1 - dimmed) : 1
        let levels: [Double] = [1, hoverDim, dimmed, hoverDim * dimmed]
        let selNode: Int = sel ?? -1, focusNode: Int = focus ?? -1, dragNode: Int = drag ?? -1

        drawEdges(topo, n: n, size: size, sel: selNode, focus: focusNode, drag: dragNode,
                  focusOn: focusOn, focusAmount: focusAmount, levels: levels,
                  fade: Self.edgeFade(zoom: frame.camera.zoom), pal: pal, in: &context)
        drawNodes(frame, n: n, sel: selNode, focus: focusNode, drag: dragNode,
                  focusOn: focusOn, focusAmount: focusAmount, levels: levels, pal: pal, in: &context)
        drawLabels(frame, n: n, bounds: bounds, sel: selNode, focus: focusNode, drag: dragNode,
                   focusAmount: focusAmount, levels: levels, focusOn: focusOn, pal: pal, in: &context)
    }

    @inline(__always)
    private static func valid(_ i: Int?, _ n: Int) -> Int? {
        guard let i, i >= 0, i < n else { return nil }
        return i
    }

    // MARK: Edges

    private func drawEdges(_ topo: GraphTopology, n: Int, size: CGSize, sel: Int, focus: Int, drag: Int,
                           focusOn: Bool, focusAmount: Double, levels: [Double], fade: Double, pal: Palette,
                           in context: inout GraphicsContext) {
        // Bucket = kind * 12 + emphasis * 4 + level. Emphasis: 0 normal, 1 focus, 2 selection.
        var paths: [CGMutablePath] = []
        paths.reserveCapacity(24)
        for _ in 0..<24 { paths.append(CGMutablePath()) }
        var used = [Bool](repeating: false, count: 24)

        let edges = topo.edges
        let m = Style.cullMargin
        let maxX = size.width + m, maxY = size.height + m
        let ringGap = Style.ringGap
        var drawn = 0
        for k in 0..<edges.count {
            if shadowed[k] { continue }
            let e = edges[k]
            let a = e.a, b = e.b
            if a >= n || b >= n { continue }
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
            let emphasis = (a == sel || b == sel) ? 2 : (touchesFocus ? 1 : 0)
            var level = 0
            if focusOn && !touchesFocus { level |= 1 }
            if (flags[a] | flags[b]) & Flag.filtered != 0 { level |= 2 }
            let bucket = (e.kind == .link ? 0 : 12) + emphasis * 4 + level
            let path = paths[bucket]
            path.move(to: CGPoint(x: ax + ux * ra, y: ay + uy * ra))
            path.addLine(to: CGPoint(x: bx - ux * rb, y: by - uy * rb))
            used[bucket] = true
            drawn += 1
        }
        stats.drawnEdges = drawn

        let solid = StrokeStyle(lineWidth: Style.edgeWidth)
        let dashed = StrokeStyle(lineWidth: Style.edgeWidth, dash: Style.trailDash)
        // Faint first so emphasis lands on top: level 3...0 within emphasis 0, then 1, then 2.
        for emphasis in 0..<3 {
            for level in stride(from: 3, through: 0, by: -1) {
                for kind in stride(from: 1, through: 0, by: -1) {
                    let bucket = kind * 12 + emphasis * 4 + level
                    guard used[bucket] else { continue }
                    let isLink = kind == 0
                    let color: Color.Resolved
                    var alpha: Double
                    switch emphasis {
                    case 2:
                        color = pal.accent
                        alpha = isLink ? Style.accentLinkOpacity : Style.accentTrailOpacity
                    case 1:
                        color = pal.secondary
                        let lo = (isLink ? Style.linkOpacity : Style.trailOpacity) * fade
                        let hi = isLink ? Style.linkFocusOpacity : Style.trailFocusOpacity
                        alpha = lo + (hi - lo) * focusAmount
                    default:
                        color = pal.secondary
                        alpha = (isLink ? Style.linkOpacity : Style.trailOpacity) * fade
                    }
                    alpha *= levels[level]
                    context.stroke(Path(paths[bucket]), with: Self.shade(color, alpha), style: isLink ? solid : dashed)
                    stats.batches += 1
                }
            }
        }
    }

    // MARK: Nodes

    private func drawNodes(_ frame: GraphFrame, n: Int, sel: Int, focus: Int, drag: Int,
                           focusOn: Bool, focusAmount: Double, levels: [Double], pal: Palette,
                           in context: inout GraphicsContext) {
        let families = pal.families.count
        let accentSlot = families
        // Missing files draw as hollow rings: a link to something that isn't there yet.
        let ghostSlot = families + 1
        let missing = frame.topology.missing
        let bucketCount = (families + 2) * 4
        var paths: [CGMutablePath] = []
        paths.reserveCapacity(bucketCount)
        for _ in 0..<bucketCount { paths.append(CGMutablePath()) }
        var used = [Bool](repeating: false, count: bucketCount)

        for i in 0..<n where visible[i] {
            if i == sel || i == focus || i == drag { continue }
            let f = flags[i]
            let slot = f & Flag.selSet != 0 ? accentSlot : (i < missing.count && missing[i] ? ghostSlot : family[i])
            var level = 0
            if focusOn && f & Flag.focusSet == 0 { level |= 1 }
            if f & Flag.filtered != 0 { level |= 2 }
            let r = sr[i]
            let bucket = slot * 4 + level
            paths[bucket].addEllipse(in: CGRect(x: sx[i] - r, y: sy[i] - r, width: r + r, height: r + r))
            used[bucket] = true
        }
        for level in stride(from: 3, through: 0, by: -1) {
            for slot in 0...ghostSlot {
                let bucket = slot * 4 + level
                guard used[bucket] else { continue }
                if slot == ghostSlot {
                    context.stroke(Path(paths[bucket]), with: Self.shade(pal.tertiary, levels[level]),
                                   lineWidth: Style.edgeWidth)
                } else {
                    let color = slot == accentSlot ? pal.accent : pal.families[slot]
                    context.fill(Path(paths[bucket]), with: Self.shade(color, Style.nodeOpacity * levels[level]))
                }
                stats.batches += 1
            }
        }

        // Pinned markers: one ring path per level.
        if !frame.pinned.isEmpty {
            var rings: [CGMutablePath?] = [nil, nil, nil, nil]
            let gap = Style.pinGap
            for i in frame.pinned where i >= 0 && i < n && visible[i] && i != sel {
                let f = flags[i]
                var level = 0
                if focusOn && f & Flag.focusSet == 0 { level |= 1 }
                if f & Flag.filtered != 0 { level |= 2 }
                let r = sr[i] + gap
                if rings[level] == nil { rings[level] = CGMutablePath() }
                rings[level]!.addEllipse(in: CGRect(x: sx[i] - r, y: sy[i] - r, width: r + r, height: r + r))
            }
            let style = StrokeStyle(lineWidth: Style.edgeWidth)
            for level in stride(from: 3, through: 0, by: -1) {
                guard let p = rings[level] else { continue }
                context.stroke(Path(p), with: Self.shade(pal.secondary, Style.pinRingOpacity * levels[level]), style: style)
                stats.batches += 1
            }
        }

        // The few nodes drawn on their own, on top: dragged, hovered, then selected.
        var specials: [Int] = []
        if drag >= 0, drag != sel { specials.append(drag) }
        if focus >= 0, focus != sel, focus != drag { specials.append(focus) }
        for i in specials where visible[i] {
            let f = flags[i]
            let color = f & Flag.selSet != 0 ? pal.accent : pal.families[family[i]]
            let strength = i == drag ? 1 : focusAmount
            var alpha = Style.nodeOpacity + (1 - Style.nodeOpacity) * strength
            if f & Flag.filtered != 0 { alpha *= levels[2] }
            context.fill(Path(ellipseIn: Self.circle(sx[i], sy[i], sr[i])), with: Self.shade(color, alpha))
            stats.batches += 1
        }
        if sel >= 0, visible[sel] {
            // Never dimmed: see the filter note in `draw`.
            let r = sr[sel]
            context.fill(Path(ellipseIn: Self.circle(sx[sel], sy[sel], r)), with: Self.shade(pal.accent, 1))
            context.stroke(Path(ellipseIn: Self.circle(sx[sel], sy[sel], r + Style.ringGap)),
                           with: Self.shade(pal.accent, Style.selectionRingOpacity),
                           style: StrokeStyle(lineWidth: Style.edgeWidth))
            stats.batches += 2
        }
    }

    @inline(__always)
    private static func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGRect {
        CGRect(x: x - r, y: y - r, width: r + r, height: r + r)
    }

    // MARK: Labels

    private func drawLabels(_ frame: GraphFrame, n: Int, bounds: CGRect, sel: Int, focus: Int, drag: Int,
                            focusAmount: Double, levels: [Double], focusOn: Bool, pal: Palette,
                            in context: inout GraphicsContext) {
        let labelAmount = frame.labelAmount.isFinite ? min(max(frame.labelAmount, 0), 1) : 0
        let zoomLabels = labelAmount > Style.labelCutoff
        guard zoomLabels || sel >= 0 || focus >= 0 || drag >= 0 else { return }

        generation &+= 1
        if generation == 0 { for i in 0..<stamp.count { stamp[i] = 0 }; generation = 1 }
        placer.reset()
        placedNode.removeAll(keepingCapacity: true)
        placedRect.removeAll(keepingCapacity: true)
        placedAlpha.removeAll(keepingCapacity: true)
        placedStrong.removeAll(keepingCapacity: true)

        let ctx = LabelPass(labelAmount: labelAmount, focusAmount: focusAmount, focusOn: focusOn,
                            levels: levels, sel: sel, focus: focus, drag: drag, bounds: bounds)
        // Priority: selected, dragged, hovered, hovered's neighbors, then (only when zoom labels
        // are showing) selected's neighbors and everything else by degree.
        if sel >= 0 { consider(sel, ctx, &context) }
        if drag >= 0 { consider(drag, ctx, &context) }
        if focus >= 0 {
            consider(focus, ctx, &context)
            for j in frame.topology.neighbors[focus] where j < n { consider(j, ctx, &context) }
        }
        if zoomLabels {
            // Labels that only show because of zoom also keep clear of other nodes; the ones
            // above (selected, dragged, hovered and its neighbors) always show.
            for i in 0..<n where visible[i] {
                placer.insertObstacle(LabelLayout.obstacleRect(center: CGPoint(x: sx[i], y: sy[i]), radius: sr[i]), owner: i)
            }
            if sel >= 0 {
                for j in frame.topology.neighbors[sel] where j < n { consider(j, ctx, &context) }
            }
            for i in priority where i < n && visible[i] { consider(i, ctx, &context) }
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
        var levels: [Double]
        var sel: Int, focus: Int, drag: Int
        var bounds: CGRect
    }

    private func consider(_ i: Int, _ p: LabelPass, _ context: inout GraphicsContext) {
        if stamp[i] == generation { return }
        stamp[i] = generation
        // Labels can hang off-screen while their node is barely outside; nodes far outside can't.
        let x = sx[i], y = sy[i]
        guard x.isFinite, y.isFinite else { return }

        let f = flags[i]
        let filterAlpha = f & Flag.filtered != 0 ? p.levels[2] : 1
        var level = 0
        if p.focusOn && f & Flag.focusSet == 0 && i != p.sel { level |= 1 }
        if f & Flag.filtered != 0 { level |= 2 }
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
