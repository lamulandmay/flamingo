import SwiftUI
import FlamingoCore
import FlamingoDesign

struct Sidebar: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        List(state.files, id: \.self, selection: $state.selected) { f in
            HStack(spacing: Theme.Space.s) { FileGlyph(ext: f.ext); Text(f.name).font(Theme.Font.body) }
        }
        .listStyle(.sidebar)
    }
}
