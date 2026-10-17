import SwiftUI
import AppKit
import FlamingoCore
import FlamingoDesign

/// A thought being written somewhere other than the capture panel, such as the inspector's
/// Thoughts tab. It is the panel's own text view, so `[[` completes file names the same way:
/// arrows and Return drive the list, Return otherwise submits, Shift-Return breaks the line,
/// Esc closes the list and then calls `onCancel`. It never takes the keyboard on its own.
public struct ThoughtField: View {
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String
    let candidates: [FileRef]
    let recent: [FileRef]
    let editable: Bool
    /// Bump to put the keyboard in the field, e.g. on a click beside the text.
    let focusRequest: Int
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @StateObject private var model = ThoughtEditorModel()

    public init(text: Binding<String>, focused: Binding<Bool>, placeholder: String, candidates: [FileRef], recent: [FileRef],
                editable: Bool = true, focusRequest: Int = 0, onSubmit: @escaping () -> Void, onCancel: @escaping () -> Void = {}) {
        _text = text; _focused = focused
        self.placeholder = placeholder; self.candidates = candidates; self.recent = recent
        self.editable = editable; self.focusRequest = focusRequest
        self.onSubmit = onSubmit; self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThoughtTextView(model: model, editable: editable, autofocus: false, onSubmit: onSubmit, onCancel: onCancel)
                .frame(height: model.textHeight)
                .overlay(alignment: .topLeading) {
                    if model.text.isEmpty {
                        Text(placeholder)
                            .font(Font(ThoughtStyle.font as CTFont))
                            .foregroundStyle(Theme.Color.textTertiary)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                }
            if model.isCompleting {
                Hairline().padding(.vertical, Theme.Space.s)
                LinkCompletionList(model: model)
                    .padding(.horizontal, -Theme.Space.s)
            }
        }
        .onAppear {
            model.text = text
            model.onTextChange = { new in if text != new { text = new } }
            model.setCandidates(candidates, recent: recent)
        }
        .onChange(of: text) { _, new in if model.text != new { model.text = new } }
        // Counts, not the arrays: the vault's file list can be hundreds of thousands long.
        .onChange(of: candidates.count) { model.setCandidates(candidates, recent: recent) }
        .onChange(of: recent) { _, new in model.setCandidates(candidates, recent: new) }
        .onChange(of: model.isFocused) { _, now in focused = now }
        .onChange(of: focusRequest) {
            guard let tv = model.textView else { return }
            tv.window?.makeFirstResponder(tv)
        }
    }
}
