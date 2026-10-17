import AppKit
import SwiftUI
import FlamingoDesign

/// Native selectable text owns its links; row-selection gestures must not intercept them.
struct RailRichText: NSViewRepresentable {
    var text: String
    var onLink: (String) -> Void
    /// A finished thought: the words in `textTertiary`. Links keep the accent.
    var dimmed = false

    static func attributed(_ text: String, dimmed: Bool = false) -> NSAttributedString {
        let out = NSMutableAttributedString(string: "")
        for segment in RailText.segments(text) {
            var attributes: [NSAttributedString.Key: Any] = [.font: Theme.NS.body, .foregroundColor: dimmed ? Theme.NS.textTertiary : Theme.NS.text]
            if let target = segment.target, let url = RailText.linkURL(for: target) {
                attributes[.link] = url
                attributes[.foregroundColor] = Theme.NS.accent
            }
            out.append(NSAttributedString(string: segment.text, attributes: attributes))
        }
        return out
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
        view.isAutomaticLinkDetectionEnabled = false
        view.linkTextAttributes = [.foregroundColor: Theme.NS.accent, .cursor: NSCursor.pointingHand]
        view.delegate = context.coordinator
        view.textStorage?.setAttributedString(Self.attributed(text, dimmed: dimmed))
        return view
    }
    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.parent = self
        let value = Self.attributed(text, dimmed: dimmed)
        if view.textStorage?.isEqual(to: value) != true { view.textStorage?.setAttributedString(value) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 10_000
        return context.coordinator.measure(Self.attributed(text, dimmed: dimmed), width: width)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RailRichText
        private let storage = NSTextStorage()
        private let layout = NSLayoutManager()
        private let container = NSTextContainer(size: .zero)
        init(_ parent: RailRichText) {
            self.parent = parent
            super.init()
            container.lineFragmentPadding = 0; layout.addTextContainer(container); storage.addLayoutManager(layout)
        }
        func measure(_ text: NSAttributedString, width: CGFloat) -> CGSize {
            storage.setAttributedString(text)
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url, let target = RailText.linkTarget(from: url) else { return false }
            parent.onLink(target)
            return true
        }
    }
}
