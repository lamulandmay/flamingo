import SwiftUI
import FlamingoCore
import FlamingoDesign

/// One row of the sidebar tree: glyph, name, and the comment count that shows on hover.
/// Hosted in the outline view's reusable cells; its environment carries `AppState` so the
/// count stays current without reloading the tree. Plan 01 owns.
struct SidebarRow: View {
    let node: FileNode
    @EnvironmentObject var state: AppState
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
            .environmentObject(state)
            .environment(\.flamingoRowSelected, selected)
            .id(ObjectIdentifier(node))   // a reused cell starts its hover state afresh
    }
}
