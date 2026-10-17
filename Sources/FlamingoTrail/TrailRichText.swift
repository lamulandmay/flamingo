import AppKit
import SwiftUI
import FlamingoCore
import FlamingoDesign

/// Native link handling keeps thought links actionable inside a selectable session row.
struct TrailRichText: NSViewRepresentable {
    let note: TrailNote
    let source: FileRef?
    let onOpenLink: ((String, FileRef) -> Void)?

    var attributed: NSAttributedString {
        let text = NSMutableAttributedString(string: "")
        if let anchor = note.anchor, source == nil {
            text.append(NSAttributedString(string: anchor.label + "  ", attributes: [
                .font: Theme.NS.monoSmall, .foregroundColor: Theme.NS.textTertiary,
            ]))
        }
        for segment in TrailPresentation.linkSegments(note.text) {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: Theme.NS.body, .foregroundColor: Theme.NS.text,
            ]
            if let target = segment.target {
                attributes[.foregroundColor] = Theme.NS.accent
                if source != nil, onOpenLink != nil, let url = Self.linkURL(for: target) {
                    attributes[.link] = url
                }
            }
            text.append(NSAttributedString(string: segment.text, attributes: attributes))
        }
        return text
    }

    static func linkURL(for target: String) -> URL? {
        guard !target.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "flamingo-trail-link"; components.host = "open"
        components.queryItems = [URLQueryItem(name: "target", value: target)]
        return components.url
    }

    static func linkTarget(from url: URL) -> String? {
        guard url.scheme == "flamingo-trail-link", url.host == "open",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = components.queryItems?.first(where: { $0.name == "target" })?.value,
              !target.isEmpty else { return nil }
        return target
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: false)
        view.isEditable = false; view.isSelectable = true; view.isRichText = true
        view.drawsBackground = false; view.textContainerInset = .zero
        view.isVerticallyResizable = false; view.isHorizontallyResizable = false
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.maximumNumberOfLines = 6
        view.textContainer?.lineBreakMode = .byTruncatingTail
        view.isAutomaticLinkDetectionEnabled = false
        view.linkTextAttributes = [.foregroundColor: Theme.NS.accent, .cursor: NSCursor.pointingHand]
        view.delegate = context.coordinator
        view.textStorage?.setAttributedString(attributed)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.parent = self
        let value = attributed
        if view.textStorage?.isEqual(to: value) != true { view.textStorage?.setAttributedString(value) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 10_000
        return context.coordinator.measure(attributed, width: width)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TrailRichText
        private let storage = NSTextStorage()
        private let layout = NSLayoutManager()
        private let container = NSTextContainer(size: .zero)

        init(_ parent: TrailRichText) {
            self.parent = parent
            super.init()
            container.lineFragmentPadding = 0
            container.maximumNumberOfLines = 6
            container.lineBreakMode = .byTruncatingTail
            layout.addTextContainer(container); storage.addLayoutManager(layout)
        }

        func measure(_ text: NSAttributedString, width: CGFloat) -> CGSize {
            storage.setAttributedString(text)
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url, let target = TrailRichText.linkTarget(from: url),
                  let source = parent.source, let onOpenLink = parent.onOpenLink else { return false }
            onOpenLink(target, source)
            return true
        }
    }
}
