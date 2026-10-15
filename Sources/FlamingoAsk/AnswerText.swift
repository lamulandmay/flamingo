import AppKit
import SwiftUI
import FlamingoCore
import FlamingoDesign

/// The answer as selectable text. Citations are accent links; hovering one shows the file
/// and anchor it points at, clicking it opens there.
struct AnswerText: View {
    var markdown: String
    var streaming: Bool
    var sources: [Int: Citation]
    var onOpen: (Citation) -> Void

    @State private var hover: CitationHover?

    var body: some View {
        AnswerTextView(
            text: MarkdownLite.render(markdown, sources: sources, streaming: streaming),
            onLink: { n in if let c = sources[n] { onOpen(c) } },
            onHover: { hover = $0 }
        )
        .overlay {
            ZStack {
                if let hover, let citation = sources[hover.number] {
                    ChipPlacement(anchor: hover.rect) { CitationChip(citation: citation) }
                        .transition(.opacity)
                }
            }
            .allowsHitTesting(false)
            .animation(Theme.Motion.fast, value: hover)
        }
    }
}

struct CitationHover: Equatable {
    var number: Int
    var rect: CGRect
}

/// File glyph, name, and anchor. Shown over a hovered citation.
struct CitationChip: View {
    let citation: Citation

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            FileGlyph(ext: citation.file.ext, size: 11)
            Text(citation.file.name)
                .font(Theme.Font.small)
                .foregroundStyle(Theme.Color.text)
                .lineLimit(1)
            if let anchor = citation.anchor {
                Text("\(anchor.kind.rawValue) \(anchor.value)")
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xs)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.s).fill(Theme.Color.bgRaised))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s).strokeBorder(Theme.Color.hairline, lineWidth: 1))
    }
}

/// Puts the chip just above the anchor rect, kept inside the view horizontally.
private struct ChipPlacement: Layout {
    var anchor: CGRect

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let chip = subviews.first else { return }
        let size = chip.sizeThatFits(.unspecified)
        let x = min(max(bounds.minX, bounds.minX + anchor.minX), max(bounds.minX, bounds.maxX - size.width))
        let y = bounds.minY + anchor.minY - size.height - Theme.Space.xs
        chip.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
    }
}

// MARK: - NSTextView bridge

private struct AnswerTextView: NSViewRepresentable {
    var text: NSAttributedString
    var onLink: (Int) -> Void
    var onHover: (CitationHover?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CitationTextView {
        let tv = CitationTextView(usingTextLayoutManager: false)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.allowsUndo = false
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.linkTextAttributes = [
            .foregroundColor: Theme.NS.accent,
            .cursor: NSCursor.pointingHand,
        ]
        tv.delegate = context.coordinator
        tv.onHover = { [weak coordinator = context.coordinator] hover in coordinator?.hoverChanged(hover) }
        tv.textStorage?.setAttributedString(text)
        return tv
    }

    func updateNSView(_ tv: CitationTextView, context: Context) {
        context.coordinator.parent = self
        guard let storage = tv.textStorage, !storage.isEqual(to: text) else { return }
        storage.setAttributedString(text)
        tv.refreshHover()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CitationTextView, context: Context) -> CGSize? {
        let finite = proposal.width.map { $0.isFinite } ?? false
        let width = finite ? proposal.width! : 10_000
        let used = context.coordinator.measure(text, width: width)
        return CGSize(width: finite ? width : ceil(used.width), height: ceil(used.height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AnswerTextView
        private var lastHover: CitationHover?
        // A separate TextKit 1 stack so measuring a proposed width never disturbs the visible layout.
        private let storage = NSTextStorage()
        private let layout = NSLayoutManager()
        private let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))

        init(_ parent: AnswerTextView) {
            self.parent = parent
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
        }

        func measure(_ text: NSAttributedString, width: CGFloat) -> CGSize {
            guard text.length > 0 else { return .zero }
            if !storage.isEqual(to: text) { storage.setAttributedString(text) }
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            return layout.usedRect(for: container).size
        }

        func hoverChanged(_ hover: CitationHover?) {
            guard hover != lastHover else { return }
            lastHover = hover
            // Never mutate SwiftUI state from inside a view update.
            DispatchQueue.main.async { [parent] in parent.onHover(hover) }
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let storage = textView.textStorage, charIndex < storage.length,
                  let n = storage.attribute(.flamingoCitation, at: charIndex, effectiveRange: nil) as? Int
            else { return false }
            parent.onLink(n)
            return true
        }
    }
}

/// Reports which citation, if any, is under the mouse and where it is drawn.
private final class CitationTextView: NSTextView {
    var onHover: (CitationHover?) -> Void = { _ in }
    private var area: NSTrackingArea?
    private var mouse: NSPoint?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero,
                               options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        mouse = convert(event.locationInWindow, from: nil)
        refreshHover()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        mouse = nil
        onHover(nil)
    }

    func refreshHover() {
        guard let mouse else { return }
        onHover(citation(at: mouse))
    }

    private func citation(at point: NSPoint) -> CitationHover? {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let p = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let glyph = lm.glyphIndex(for: p, in: tc, fractionOfDistanceThroughGlyph: &fraction)
        guard lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).contains(p) else { return nil }
        let index = lm.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        var run = NSRange()
        guard let n = storage.attribute(.flamingoCitation, at: index, longestEffectiveRange: &run,
                                        in: NSRange(location: 0, length: storage.length)) as? Int
        else { return nil }
        let glyphs = lm.glyphRange(forCharacterRange: run, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphs, in: tc).offsetBy(dx: origin.x, dy: origin.y)
        return CitationHover(number: n, rect: rect)
    }
}
