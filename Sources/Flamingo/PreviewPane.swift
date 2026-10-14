import SwiftUI
import FlamingoCore
import FlamingoDesign

/// The content column in Files mode: the selected file, rendered in place. Plan 01 owns.
///
/// `.pdf` goes to `PDFView` and audio/video to `AVPlayerView` so the shell always knows
/// the page or time you are on (`AppState.anchor`, `AppState.navigator`). Everything else
/// goes to Quick Look, and the shell steps through indexed sections itself.
struct PreviewPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if let file = state.selected, let url = state.url(for: file) {
            variant(for: file, url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Color.bg)
        } else {
            Color.clear
        }
    }

    /// Same kind: the document swaps in place (`updateNSView`). Different kind: each
    /// branch is its own view type, so SwiftUI swaps the subview. The modification
    /// date is an input so a file rewritten on disk re-renders on the next update.
    @ViewBuilder private func variant(for file: FileRef, url: URL) -> some View {
        let modified = PreviewKind.modificationDate(of: url)
        switch PreviewKind(ext: file.ext) {
        case .pdf:
            PDFPreview(state: state, file: file, url: url, modified: modified, jump: state.jumpRequest)
        case .media:
            MediaPreview(state: state, file: file, url: url, modified: modified, jump: state.jumpRequest)
        case .quickLook:
            QuickLookPreview(url: url, modified: modified)
        }
    }
}

/// Which view renders a file, by extension.
enum PreviewKind {
    case pdf, media, quickLook

    init(ext: String) {
        if ext == "pdf" {
            self = .pdf
        } else if MediaKind.isMedia(ext) {
            self = .media
        } else {
            self = .quickLook
        }
    }

    /// Content modification date, nil when the file is gone. One stat per update of the
    /// pane; SwiftUI only re-runs `updateNSView` when an input changes, so this is how
    /// a file rewritten on disk gets re-rendered.
    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
