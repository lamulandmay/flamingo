import SwiftUI
import FlamingoCore
import FlamingoDesign

/// Placeholder flat list until the folder tree lands. Plan 01 owns.
struct Sidebar: View {
    @EnvironmentObject var state: AppState
    let topInset: CGFloat
    var body: some View {
        List(state.files, id: \.self, selection: Binding(
            get: { state.selected },
            set: { state.select($0, source: .sidebar) }
        )) { f in
            HStack(spacing: Theme.Space.s) { FileGlyph(ext: f.ext); Text(f.name).font(Theme.Font.body) }
        }
        .listStyle(.sidebar)
        .padding(.top, topInset)
    }
}
