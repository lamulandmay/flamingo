import AppKit
import SwiftUI
import FlamingoCore
import FlamingoDesign
import FlamingoAsk
import FlamingoIndex
import FlamingoThoughts

/// A memo, read in place: 640 pt wide, the body rendered with `MarkdownLite`, its `[[sources]]`
/// links that open the files.
struct MemoReader: View {
    let data: MemoCardData
    let thought: ThoughtRecord?
    let vault: Vault?
    let maxHeight: CGFloat
    let onClose: () -> Void
    let onOpenLink: (String) -> Void

    var body: some View {
        let shape = Squircle(radius: Theme.Radius.l)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(data.memo.title)
                        .font(Theme.Font.title)
                        .foregroundStyle(Theme.Color.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let symbol = MemoCardFacts.verdictSymbol(data.memo) {
                        Image(systemName: symbol).font(.system(size: Theme.Size.iconSmall)).foregroundStyle(Theme.Color.textSecondary)
                    }
                }
                if let line = thought?.comment.firstLine {
                    Text(BriefingFormat.plain(line)).font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary).lineLimit(2)
                }
            }
            .padding(Theme.Space.xl)
            Hairline()
            ScrollView {
                MemoText(markdown: data.memo.body, onOpenLink: onOpenLink)
                    .padding(Theme.Space.xl)
            }
            let sources = MemoCardFacts.sourceFiles(of: data.memo, limit: 6)
            if !sources.isEmpty {
                Hairline()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.m) {
                        ForEach(sources, id: \.self) { file in
                            Button { onOpenLink(file.relativePath) } label: {
                                HStack(spacing: Theme.Space.xs + 2) {
                                    FileGlyph(ext: file.ext, size: 11)
                                    Text(file.name).font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary).lineLimit(1)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.press)
                            .pointingHandCursor()
                        }
                    }
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.vertical, Theme.Space.m)
                }
            }
        }
        .frame(width: 640)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(shape.fill(Theme.Color.bgRaised))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.Color.hairline, lineWidth: Theme.Size.hairline))
        .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
    }
}

/// The memo's body as selectable text. `[[links]]` become accent links.
private struct MemoText: NSViewRepresentable {
    let markdown: String
    let onOpenLink: (String) -> Void

    static let scheme = "flamingo-open"

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView(frame: .zero)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.linkTextAttributes = [.foregroundColor: Theme.NS.accent, .cursor: NSCursor.pointingHand]
        tv.delegate = context.coordinator
        tv.textStorage?.setAttributedString(Self.render(markdown))
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        context.coordinator.parent = self
        let text = Self.render(markdown)
        if tv.textStorage?.isEqual(to: text) != true { tv.textStorage?.setAttributedString(text) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 560
        let text = Self.render(markdown)
        guard text.length > 0 else { return CGSize(width: width, height: 0) }
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    /// The markdown with each `[[target#anchor|alias]]` replaced by its readable name as a link.
    static func render(_ markdown: String) -> NSAttributedString {
        let styled = NSMutableAttributedString(attributedString: MemoMarkdown.attributed(markdown))
        guard let regex = try? NSRegularExpression(pattern: #"\[\[([^\]]+)\]\]"#) else { return styled }
        let matches = regex.matches(in: styled.string, range: NSRange(location: 0, length: styled.length))
        for m in matches.reversed() {
            let raw = (styled.string as NSString).substring(with: m.range(at: 1))
            let parts = Wikilink.components(of: raw)
            var shown = parts.alias ?? (parts.target as NSString).lastPathComponent
            if parts.alias == nil, let anchor = parts.anchor { shown += " \u{00B7} " + anchor }
            var attrs = styled.attributes(at: m.range.location, effectiveRange: nil)
            attrs[.foregroundColor] = Theme.NS.accent
            if let encoded = raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
               let url = URL(string: scheme + ":" + encoded) { attrs[.link] = url }
            styled.replaceCharacters(in: m.range, with: NSAttributedString(string: shown, attributes: attrs))
        }
        return styled
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MemoText
        init(_ parent: MemoText) { self.parent = parent }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.scheme == MemoText.scheme,
                  let raw = String(url.absoluteString.dropFirst(MemoText.scheme.count + 1)).removingPercentEncoding else { return false }
            parent.onOpenLink(raw)
            return true
        }
    }
}
