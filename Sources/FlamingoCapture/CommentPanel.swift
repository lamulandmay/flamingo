import SwiftUI
import FlamingoCore
import FlamingoDesign

/// The floating "leave a thought" field. One text view and a single tertiary line naming
/// where the thought will land. Enter saves, Shift-Enter breaks the line, Esc cancels.
/// `[[` completes file names from `candidates`. Plan 03 owns.
public struct CommentPanel: View {
    public let target: FileRef
    public var anchor: FileAnchor?
    public var onSubmit: (Comment) -> Void
    public var onCancel: () -> Void
    /// Files offered by `[[` completion.
    public var candidates: [FileRef] = []
    /// Recently used files, most recent first. Shown for a bare `[[` and ranked ahead on ties.
    public var recent: [FileRef] = []

    /// Replaces the footer's file name, e.g. for the daily inbox note.
    var label: String?
    /// Reports the panel's natural height so a hosting window can grow with the text.
    var onHeightChange: ((CGFloat) -> Void)?

    @StateObject private var model = ThoughtEditorModel()

    public init(target: FileRef, anchor: FileAnchor? = nil, onSubmit: @escaping (Comment) -> Void, onCancel: @escaping () -> Void) {
        self.target = target; self.anchor = anchor; self.onSubmit = onSubmit; self.onCancel = onCancel
    }

    public init(target: FileRef, anchor: FileAnchor? = nil, candidates: [FileRef], recent: [FileRef] = [],
                onSubmit: @escaping (Comment) -> Void, onCancel: @escaping () -> Void) {
        self.init(target: target, anchor: anchor, onSubmit: onSubmit, onCancel: onCancel)
        self.candidates = candidates; self.recent = recent
    }

    var footer: String {
        var parts = [label ?? target.name]
        if let anchor { parts.append("\(anchor.kind.rawValue) \(anchor.value)") }
        return parts.joined(separator: " · ")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThoughtTextView(model: model, onSubmit: submit, onCancel: onCancel)
                .frame(height: model.textHeight)
                .padding(.top, Theme.Space.m)
                .padding(.horizontal, Theme.Space.l)

            Text(footer)
                .font(Theme.Font.mono)
                .foregroundStyle(Theme.Color.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, Theme.Space.s)
                .padding(.bottom, Theme.Space.m)
                .padding(.horizontal, Theme.Space.l)

            if model.isCompleting {
                Hairline()
                LinkCompletionList(model: model)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(PanelChromeModifier(windowed: onHeightChange != nil))
        .background(GeometryReader { proxy in
            Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(PanelHeightKey.self) { h in onHeightChange?(h) }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { model.setCandidates(candidates, recent: recent) }
        .onChange(of: candidates) { _, new in model.setCandidates(new, recent: recent) }
        .onChange(of: recent) { _, new in model.setCandidates(candidates, recent: new) }
    }

    private func submit() {
        let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return onCancel() }
        onSubmit(Comment(anchor: anchor, text: text))
    }
}

/// `PanelChrome` at panel width. In the capture window the window draws the shadow.
private struct PanelChromeModifier: ViewModifier {
    var windowed: Bool
    func body(content: Content) -> some View {
        PanelChrome(shadow: !windowed) { content }
    }
}

private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Vault files matching the link being typed. Arrow keys move, Enter or a click completes.
struct LinkCompletionList: View {
    @ObservedObject var model: ThoughtEditorModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.results.enumerated()), id: \.element.id) { i, c in
                HStack(spacing: Theme.Space.s) {
                    FileGlyph(ext: c.ref.ext)
                    Text(c.ref.name)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Color.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Theme.Space.m)
                    Text(c.folder)
                        .font(Theme.Font.mono)
                        .foregroundStyle(Theme.Color.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .padding(.horizontal, Theme.Space.s)
                .frame(height: Theme.Size.row)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.s)
                        .fill(i == model.selection ? Theme.Color.selection : Color.clear)
                )
                .contentShape(Rectangle())
                .onTapGesture { model.accept(i) }
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xs)
    }
}
