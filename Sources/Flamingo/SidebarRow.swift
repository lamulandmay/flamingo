import SwiftUI
import FlamingoCore
import FlamingoAgents
import FlamingoDesign

/// One row of the sidebar tree: glyph, name, and the comment count that shows on hover.
/// Hosted in the outline view's reusable cells; its environment carries `AppState` so the
/// count stays current without reloading the tree. Plan 01 owns.
struct SidebarRow: View {
    let node: FileNode
    @Environment(AppState.self) var state
    @Environment(\.flamingoRowSelected) private var selected
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if let ref = node.ref {
                FileGlyph(ext: ref.ext)
            } else {
                FolderGlyph()
            }
            Text(node.name)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.s)
            if node.isPin {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.Color.textTertiary)
                    .opacity(hovering || selected ? 0.9 : 0.55)
                    .accessibilityLabel("Pinned folder")
            }
            if node.isFolder, !node.id.isEmpty { AgentDot(model: state.agentProjects, path: node.id) }
            if let ref = node.ref, let count = state.commentCounts[ref], count > 0 {
                Text(String(count))
                    .font(Theme.Font.small)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Color.textTertiary)
                    .opacity(hovering ? 1 : 0)
            }
        }
        .padding(.trailing, Theme.Space.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .opacity(node.isFolder && !node.isWithinPin && !selected && !hovering ? 0.68 : 1)
        .help(node.isPin ? "Pinned folder · " + (node.id.isEmpty ? state.vault?.name ?? "" : node.id) : node.id)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fast, value: hovering)
    }
}

/// What each outline cell hosts: the row plus its environment. `selected` is pushed in by
/// the row view when the selection moves, so glyphs turn accent without a reload.
struct SidebarRowHost: View {
    let node: FileNode
    let state: AppState
    var selected: Bool

    var body: some View {
        SidebarRow(node: node)
            .environment(state)
            .environment(\.flamingoRowSelected, selected)
            .id(ObjectIdentifier(node))   // a reused cell starts its hover state afresh
    }
}

/// Plan 18: the dot on a folder an agent works in that isn't a project yet, and on every
/// folder above it. A click opens Make Project for that folder (or the first one inside).
struct AgentDot: View {
    @ObservedObject var model: AgentProjectsModel
    let path: String

    var body: some View {
        if model.dotted.contains(path), let offer = model.offer(under: path) {
            Button { model.present(offer.root) } label: {
                Squircle(radius: 3)
                    .fill(Theme.Color.textSecondary)
                    .frame(width: 6, height: 6)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Set(offer.activity.map(\.harness.name)).sorted().joined(separator: ", ") + " · " + offer.root.lastPathComponent)
            .accessibilityLabel("Make \(offer.root.lastPathComponent) a project")
            .transition(.opacity)
        }
    }
}
