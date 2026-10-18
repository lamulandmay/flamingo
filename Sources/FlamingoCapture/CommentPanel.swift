import SwiftUI
import AppKit
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
    /// The target is a folder's note: its glyph is the folder's.
    var isFolder = false
    /// Selected text from another app, `> ` lines, shown above the field and saved with the thought.
    var quote: String?
    var replyParent: String?
    /// Earlier thoughts like the draft (see `CaptureController.similarThoughts`).
    var similar: ((String) async -> [EchoHit])?
    var onJumpEcho: ((EchoHit) -> Void)?
    var onReplyEcho: ((EchoHit) -> Void)?
    /// Reports the panel's natural height so a hosting window can grow with the text.
    var onHeightChange: ((CGFloat) -> Void)?
    var initialText = ""
    var saving = false
    /// Shows "Saving…"; the controller sets it only when a save is slow.
    var showsSaving = false
    var error: String?
    var onTextChange: ((String) -> Void)?
    var onDiscard: (() -> Void)?

    @StateObject private var model = ThoughtEditorModel()
    @StateObject private var echo = ThoughtEchoModel()

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

    /// Glyphs of the files the thought links so far, as the link spells them.
    private var linkedExts: [String] {
        var seen = Set<String>(), out: [String] = []
        for raw in Wikilink.parse(model.text) where out.count < 3 {
            let name = (Wikilink.components(of: raw).target as NSString).lastPathComponent
            if seen.insert(name.lowercased()).inserted { out.append((name as NSString).pathExtension) }
        }
        return out
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let quote {
                Text(quote)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Theme.Space.m)
                    .padding(.horizontal, Theme.Space.l)
            }
            ThoughtEcho(model: echo, onJump: { onJumpEcho?($0) }, onReplyTo: { onReplyEcho?($0) })
                .padding(.top, quote == nil ? Theme.Space.xs : 0)
                .padding(.horizontal, Theme.Space.s)
            ThoughtTextView(model: model, editable: !saving, onSubmit: submit, onCancel: onCancel)
                .frame(height: model.textHeight)
                .padding(.top, quote == nil && echo.hits.isEmpty ? Theme.Space.m : Theme.Space.s)
                .padding(.horizontal, Theme.Space.l)

            if saving && showsSaving { Text("Saving…").font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary).padding(.horizontal, Theme.Space.l) }
            if let error {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(error).font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary).textSelection(.enabled)
                    HStack {
                        Button("Retry", action: submit).disabled(saving)
                        Button("Copy thought") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.text, forType: .string)
                        }
                    }.font(Theme.Font.small)
                }.padding(Theme.Space.l)
            }

            HStack(spacing: Theme.Space.xs) {
                if isFolder { FolderGlyph(size: 13) } else { FileGlyph(ext: label == nil ? target.ext : "md", size: 13) }
                Text(footer).lineLimit(1).truncationMode(.middle)
                if !linkedExts.isEmpty {
                    HStack(spacing: Theme.Space.xs) {
                        ForEach(Array(linkedExts.enumerated()), id: \.offset) { _, ext in FileGlyph(ext: ext, size: 13) }
                    }
                    .padding(.leading, Theme.Space.xs)
                    .transition(.opacity)
                }
                Spacer(minLength: Theme.Space.s)
                if let onDiscard, !model.text.isEmpty {
                    Button("Discard draft", action: onDiscard).buttonStyle(.press(shade: nil)).disabled(saving)
                }
            }
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
        .onAppear {
            echo.similar = similar
            model.onTextChange = { text in onTextChange?(text); echo.update(draft: text) }
            model.text = initialText
            model.setCandidates(candidates, recent: recent)
        }
        .onChange(of: candidates) { _, new in model.setCandidates(new, recent: recent) }
        .onChange(of: recent) { _, new in model.setCandidates(candidates, recent: new) }
    }

    private func submit() {
        guard !saving else { return }
        let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return onCancel() }
        echo.reset()
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
                    Squircle(radius: Theme.Radius.s)
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
