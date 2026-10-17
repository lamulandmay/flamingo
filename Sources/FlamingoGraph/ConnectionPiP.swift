import SwiftUI
import AppKit
import QuartzCore
import FlamingoCore
import FlamingoDesign

/// A connection to show off: `source` now links each of `targets`, at a thought strength
/// `level` (0 spark, 1 solid, 2 woven) that picks the tint. A new `id` plays it again.
public struct GraphCelebration: Equatable, Sendable {
    public var id: Int
    public var source: FileRef
    public var targets: [FileRef]
    public var level: Int
    public init(id: Int, source: FileRef, targets: [FileRef], level: Int) {
        self.id = id; self.source = source; self.targets = targets; self.level = level
    }
}

/// The graph in a corner, picture-in-picture, for a connection made while the graph isn't on
/// screen. It opens on the file's neighborhood, settles on the new connection, draws it in,
/// and goes. Hovering holds it; a click opens the graph on that file.
///
/// It floats at the top right of Flamingo's window when Flamingo is in front, and at the top
/// right of the screen when the thought came from another app. It never takes focus.
@MainActor
public final class ConnectionPiP {
    public static let shared = ConnectionPiP()
    /// A click on the PiP. The shell opens the graph on this file.
    public var onOpen: (FileRef) -> Void = { _ in }

    public static let size = CGSize(width: 320, height: 208)
    /// Left on screen after the connection fades, so it can be read.
    static let linger: TimeInterval = 0.4

    private let panel = PiPPanel()
    private var model: GraphModel?
    private var generation = 0
    private var hovering = false
    private var finished = false

    /// Shows `celebration` against `graph` (the whole vault graph; it may not have the new
    /// link yet, and may be empty). `window` is Flamingo's main window.
    public func show(_ celebration: GraphCelebration, in graph: Graph, over window: NSWindow?) {
        generation += 1
        let gen = generation
        Task.detached(priority: .userInitiated) {
            let local = Self.neighborhood(celebration, in: graph)
            await MainActor.run { [weak self] in
                guard let self, self.generation == gen else { return }
                self.present(celebration, local: local, over: window, gen: gen)
            }
        }
    }

    /// The source's neighborhood with the new links in it, laid out in rings around the source.
    nonisolated static func neighborhood(_ c: GraphCelebration, in graph: Graph) -> RadialLayout.Local {
        var sub = RadialLayout.neighborhood(of: c.source.relativePath, in: graph, depth: 1)
        func node(_ f: FileRef) -> Graph.Node { Graph.Node(id: f.relativePath, name: f.name, ext: f.ext) }
        if sub.nodes.isEmpty { sub.nodes = [node(c.source)] }
        let ids = Set(sub.nodes.map(\.id))
        for t in c.targets where !ids.contains(t.relativePath) { sub.nodes.append(node(t)) }
        for t in c.targets {
            let linked = sub.edges.contains {
                $0.kind.isExplicit && Set([$0.source, $0.target]) == Set([c.source.relativePath, t.relativePath])
            }
            if !linked { sub.edges.append(Graph.Edge(source: c.source.relativePath, target: t.relativePath, kind: .link)) }
        }
        let topology = GraphTopology(sub)
        let root = topology.index[c.source.relativePath]
        var positions = RadialLayout.positions(for: topology, root: root)
        // Turn the rings so the first new link sits to the right: the line runs level, under
        // no one's name (names hang below their nodes).
        if let first = c.targets.first.flatMap({ topology.index[$0.relativePath] }), let root {
            let o = positions[root], p = positions[first]
            let turn = -atan2(p.y - o.y, p.x - o.x)
            positions = positions.map { q in
                let x = q.x - o.x, y = q.y - o.y
                return CGPoint(x: o.x + x * cos(turn) - y * sin(turn), y: o.y + x * sin(turn) + y * cos(turn))
            }
        }
        return RadialLayout.Local(graph: sub, positions: positions, center: root)
    }

    private func present(_ c: GraphCelebration, local: RadialLayout.Local, over window: NSWindow?, gen: Int) {
        let model = GraphModel(fixedGraph: local.graph, positions: local.positions)
        model.setFixed(graph: local.graph, positions: local.positions, selected: local.center)
        model.alwaysShowLabels = true
        model.calm = false
        model.labelLimit = RadialLayout.labeledNeighbors + 1
        model.fitPadding = Theme.Space.xl
        model.fitMaxZoom = 2
        model.onCelebrationEnded = { [weak self] in self?.celebrationEnded(gen) }
        model.onCelebrationMissed = { [weak self] _, _, _ in self?.celebrationEnded(gen) }
        model.celebrate(from: c.source, to: c.targets, level: c.level, zoom: true)
        self.model = model
        finished = false
        hovering = false

        let view = PiPView(model: model,
                           open: { [weak self] in self?.dismiss(); self?.onOpen(c.source) },
                           hover: { [weak self] in self?.hovering = $0; if !$0 { self?.leaveIfDone(gen) } })
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.alphaValue = 0
        panel.parent?.removeChildWindow(panel)
        if let window, Self.inWindow(window) {
            // Rides on Flamingo's window: moves with it, stays on its Space, under other apps.
            panel.level = window.level
            panel.collectionBehavior = [.transient, .ignoresCycle]
            panel.setFrame(Self.frame(in: window.convertToScreen(window.contentLayoutRect)), display: false)
            window.addChildWindow(panel, ordered: .above)
        } else {
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            panel.setFrame(Self.frame(in: screen?.visibleFrame ?? .zero), display: false)
            panel.orderFrontRegardless()
        }
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.Motion.fastSeconds
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// Flamingo is in front, so the window is where the person is looking. QA builds in the
    /// background pass `FLAMINGO_PIP_IN_WINDOW=1` to keep the PiP off the person's screen.
    public static func inWindow(_ window: NSWindow) -> Bool {
        guard window.isVisible else { return false }
        if ProcessInfo.processInfo.environment["FLAMINGO_PIP_IN_WINDOW"] == "1" { return true }
        return NSApp.isActive && window.isOnActiveSpace
    }

    /// The top right corner of `area`, inset.
    static func frame(in area: NSRect) -> NSRect {
        let inset = Theme.Space.l
        return NSRect(x: area.maxX - size.width - inset, y: area.maxY - size.height - inset,
                      width: size.width, height: size.height)
    }

    private func celebrationEnded(_ gen: Int) {
        guard gen == generation else { return }
        finished = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.linger) { [weak self] in self?.leaveIfDone(gen) }
    }

    private func leaveIfDone(_ gen: Int) {
        guard gen == generation, finished, !hovering else { return }
        dismiss()
    }

    /// Fades out and lets the graph go.
    public func dismiss() {
        generation += 1
        let gen = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Theme.Motion.normalSeconds
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                self.panel.parent?.removeChildWindow(self.panel)
                self.panel.orderOut(nil)
                self.panel.contentView = nil
                self.model = nil
            }
        })
    }
}

/// The PiP's surface: the graph on its sunken canvas, clipped to a squircle with a hairline.
private struct PiPView: View {
    let model: GraphModel
    let open: () -> Void
    let hover: (Bool) -> Void

    var body: some View {
        let shape = Squircle(radius: Theme.Radius.l)
        GraphCanvas(model: model, redraw: model.redraw)
            .frame(width: ConnectionPiP.size.width, height: ConnectionPiP.size.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.Color.hairline, lineWidth: Theme.Size.hairline))
            .contentShape(shape)
            .onTapGesture(perform: open)
            .onHover(perform: hover)
            .pointingHandCursor()
            .accessibilityElement()
            .accessibilityLabel("New connection")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open() }
    }
}

/// Floats over everything, on every Space, and never becomes key, so typing stays where it was.
final class PiPPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
