import SwiftUI
import Quartz
import FlamingoCore

/// Quick Look preview of the selected file. Plan 01 owns.
struct PreviewPane: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        if let v = state.vault, let f = state.selected {
            QuickLookView(url: v.url(for: f))
        } else {
            Color.clear
        }
    }
}

struct QuickLookView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal)!
        v.autostarts = true
        v.previewItem = url as NSURL
        return v
    }
    func updateNSView(_ v: QLPreviewView, context: Context) {
        if (v.previewItem as? NSURL) as URL? != url { v.previewItem = url as NSURL }
    }
}
