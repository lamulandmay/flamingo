# Plan 06 — Graph view

**You own:** `Sources/FlamingoGraph/`.
**Read first:** `CONTRACT.md` (`Graph` model), `DESIGN.md`. `GraphView(graph:selected:onSelect:)`
is frozen.

## Mission

Obsidian's graph, but the nodes are your actual documents. Smooth at a thousand nodes,
beautiful at twenty. Pan, zoom, hover to see the neighborhood, click to open. This is the
screenshot people share.

## Milestones, in order

### M1 — Force layout
- Force-directed simulation (many-body repulsion with a Barnes-Hut quadtree, link springs,
  centering, mild collision). Own implementation in Swift; it's a few hundred lines. Run it
  on a background task, publish positions to the view at 60fps while alpha > threshold, then
  settle and stop.
- Deterministic initial positions (seeded by node id hash) so the graph looks the same on reopen.
- Persist positions to `<vault>/.flamingo/graph-layout.json` so reopening is instant and
  stable; new nodes enter near their neighbors.

### M2 — Rendering
- SwiftUI `Canvas`. Nodes are circles, radius 3 + log(commentCount + degree). Fill is
  `Theme.Color.textSecondary` at 70%; `link` edges hairline at 25%; `trail` edges dashed at
  15%. Selected node and its neighbors in accent; everything else dims to 30% while hovering.
- Labels: file name without extension, 11pt, appear when zoom > 1.2 or when the node is
  hovered/selected. Never overlap the node. Fade in 150ms.
- Color by family, subtly: decks, documents, sheets, pdf, images, media, 3D, code, notes.
  Ask plan 08 for a `Theme.Color.family(ext:)` token via REQUESTS.md and use grey until it exists.
- Pan with drag, zoom with pinch and scroll, double-click to fit. Drag a node to pin it; it
  stays pinned until double-clicked.

### M3 — Interaction and filters
- Hover tooltip: none. Hover shows the label; that's enough.
- Click → `onSelect`. The shell jumps to the file.
- A small filter field at the top-left corner of the canvas (no label): typing dims nodes that
  don't match. Prefix `ext:pptx` filters by type. `orphans` shows nodes with no edges.
- Keyboard: arrows move selection to the nearest neighbor in that direction. Enter opens.

### M4 — Local graph
- Add `LocalGraphView(graph:center:depth:onSelect:)`: the neighborhood of one file within N
  hops, laid out radially. The shell can embed it under the comments rail.

## Done means
Drop a 1,000-node, 3,000-edge graph in and it lays out in under 3 seconds and pans at 60fps.
A 30-node graph looks like something you'd put on a landing page.

## Don't
- No WebView, no d3. Native Canvas only.
- No legend, no title, no "Graph" label.

## Subagent ideas
One agent writes the simulation with a quadtree and a benchmark. One writes the Canvas
renderer against a fake positions array. One does gestures. Merge in `GraphView.swift`.
