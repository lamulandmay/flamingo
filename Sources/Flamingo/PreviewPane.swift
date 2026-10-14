import SwiftUI
import Quartz
import FlamingoCore

/// Quick Look preview of the selected file. Placeholder until the PDF/media variants land. Plan 01 owns.
struct PreviewPane: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        if let f = state.selected, let url = state.url(for: f) {
            QuickLookView(url: url)
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
