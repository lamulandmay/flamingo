import SwiftUI
import FlamingoCore
import FlamingoDesign

/// Force-directed graph of the vault. Plan 06 owns.
public struct GraphView: View {
    public var graph: Graph
    public var selected: FileRef?
    public var onSelect: (FileRef) -> Void
    public init(graph: Graph, selected: FileRef? = nil, onSelect: @escaping (FileRef) -> Void) {
        self.graph = graph; self.selected = selected; self.onSelect = onSelect
    }
    public var body: some View {
        // TODO(plan 06)
        Color.clear
    }
}
