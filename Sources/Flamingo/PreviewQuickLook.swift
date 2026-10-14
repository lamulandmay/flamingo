import SwiftUI
import Quartz

/// Quick Look for everything that is not a PDF or media. No navigator: the shell steps
/// through indexed sections itself. Plan 01 owns.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL
    let modified: Date?

    @MainActor final class Coordinator {
        var url: URL?
        var modified: Date?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.shouldCloseWithWindow = false
        return view
    }

    /// The view is reused across files; only the item changes. A file rewritten on disk
    /// (same URL, new modification date) is redisplayed; a vanished one shows nothing.
    func updateNSView(_ view: QLPreviewView, context: Context) {
        let shown = context.coordinator
        guard url != shown.url || modified != shown.modified else { return }
        let sameFile = url == shown.url
        shown.url = url
        shown.modified = modified
        if modified == nil {
            view.previewItem = nil
        } else if sameFile, view.previewItem != nil {
            view.refreshPreviewItem()
        } else {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        view.close()
    }
}
