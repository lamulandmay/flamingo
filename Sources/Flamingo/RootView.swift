import SwiftUI
import FlamingoCore
import FlamingoDesign

/// Sidebar + content. Plan 01 owns.
struct RootView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        HSplitView {
            Sidebar().frame(minWidth: 200, idealWidth: 240, maxWidth: 360)
            PreviewPane().frame(minWidth: 400)
        }
        .onAppear { state.restoreLastVault() }
    }
}
