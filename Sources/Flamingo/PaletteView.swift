import AppKit
import SwiftUI
import FlamingoCore
import FlamingoDesign
import FlamingoIndex
import FlamingoCapture

/// The palette's content: one field, then rows. No header, no footer, no empty state.
/// Plan 01 owns.
struct PaletteView: View {
    @ObservedObject var model: PaletteModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: model.query.hasPrefix(">") ? "command" : "magnifyingglass")
                    .foregroundStyle(Theme.Color.textTertiary)
                PaletteField(model: model)
                ForEach(model.filters, id: \.self) { filter in
                    Text(filter)
                        .font(Theme.Font.monoSmall)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .padding(.horizontal, Theme.Space.s)
                        .frame(height: 20)
                        .background(Squircle(radius: Theme.Radius.s).fill(Theme.Color.fill))
                }
                if model.searching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, Theme.Space.l).frame(height: PaletteController.fieldHeight + 6)
            Hairline()
            HStack(spacing: 0) {
                if let result = model.selectedResult, let state = model.state, let vault = model.vault {
                    results.frame(width: 340)
                    VHairline()
                    SearchResultDetail(state: state, vault: vault, result: result,
                                       query: UnifiedSearchQuery(raw: model.query).text, onHitChange: { model.previewHitID = $0?.id }) { result, hit, external in
                        let query = model.query
                        model.cancel()
                        state.openSearchResult(result, hit: hit, query: query, externally: external)
                    }
                } else {
                    results.frame(maxWidth: .infinity)
                }
            }
            .opacity(model.searching && !model.items.isEmpty ? 0.55 : 1)
            .animation(Theme.Motion.fast, value: model.searching)
            .frame(maxHeight: .infinity)
            if let notice = model.notice {
                Hairline()
                Text(notice).font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(Theme.Space.s)
            }
        }
        .background(Theme.Color.bgRaised)
        .clipShape(Squircle(radius: Theme.Radius.l))
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        if case .result(let result) = item, let vault = model.vault {
                            UnifiedSearchRow(result: result, selected: index == model.highlight)
                                .contentShape(Rectangle())
                                .pressFeedback(shade: Theme.Radius.s)
                                .onTapGesture(count: 2) { model.run(item) }
                                .onTapGesture { model.select(index) }
                                .onDrag { FileHandoff.itemProvider(url: vault.url(for: result.file), relativePath: result.file.relativePath) }
                                .contextMenu {
                                    Button("Open") { model.run(item) }
                                    Button("Open in Default App") { model.onRun?(item, true) }
                                    Button("Copy File") { _ = FileHandoff.copy(urls: [vault.url(for: result.file)]) }
                                }
                                .id(item.id)
                        } else {
                            PaletteRow(item: item, highlighted: index == model.highlight) { model.run(item) }.id(item.id)
                        }
                    }
                }.padding(Theme.Space.xs)
            }
            .onChange(of: model.highlight) { _, row in
                guard model.items.indices.contains(row) else { return }
                proxy.scrollTo(model.items[row].id)
            }
            .onChange(of: model.version) { _, _ in
                guard model.items.indices.contains(model.highlight) else { return }
                proxy.scrollTo(model.items[model.highlight].id)
            }
        }
    }
}

// MARK: - Rows

/// Keyboard moves the highlight; hover only tints; a click runs the row.
private struct PaletteRow: View {
    let item: PaletteItem
    let highlighted: Bool
    let action: () -> Void

    var body: some View {
        content
            .flamingoRow(selected: highlighted)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    @ViewBuilder private var content: some View {
        switch item {
        case .file(let ref): FileRowContent(ref: ref)
        case .command(let command): CommandRowContent(command: command)
        case .hit(let hit): HitRowContent(hit: hit)
        case .result(let result): UnifiedSearchRow(result: result, selected: highlighted)
        case .thought(let hit): ThoughtRowContent(hit: hit)
        }
    }
}

private struct FileRowContent: View {
    let ref: FileRef

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            FileGlyph(ext: ref.ext, size: Theme.Size.iconSmall)
                .frame(width: 16)
            Text(ref.name)
                .layoutPriority(1)
            Spacer(minLength: Theme.Space.s)
            if !ref.directory.isEmpty {
                Text(ref.directory)
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .truncationMode(.middle)
                    .frame(maxWidth: Theme.Size.panel * 0.45, alignment: .trailing)
            }
        }
        .frame(height: 28)
    }
}

private struct CommandRowContent: View {
    let command: PaletteCommand

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: command.symbol)
                .font(.system(size: Theme.Size.iconSmall))
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(command.title)
                .layoutPriority(1)
            Spacer(minLength: Theme.Space.s)
            if let keys = command.keys { KeyHint(keys) }
        }
        .frame(height: 28)
    }
}

/// A thought found by ⌘K: its kind, its first line, the file it is on and when.
private struct ThoughtRowContent: View {
    let hit: ThoughtHit

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            KindGlyph(kind: hit.record.kind, state: hit.record.state).frame(width: 16)
            Text(ThoughtLines.first(of: hit.record.comment.text))
                .foregroundStyle(hit.record.state == .done ? Theme.Color.textTertiary : Theme.Color.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: Theme.Space.s)
            Text(hit.record.file.name)
                .font(Theme.Font.small)
                .foregroundStyle(Theme.Color.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 120, alignment: .trailing)
            Text(hit.record.comment.timestamp.formatted(.dateTime.month(.abbreviated).day()))
                .font(Theme.Font.monoSmall)
                .foregroundStyle(Theme.Color.textTertiary)
                .fixedSize()
        }
        .frame(height: 28)
    }
}

private struct HitRowContent: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Space.s) {
                if hit.commentID != nil {
                    Image(systemName: "text.bubble")
                        .font(.system(size: Theme.Size.iconSmall))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                } else {
                    FileGlyph(ext: hit.file.ext, size: Theme.Size.iconSmall)
                        .frame(width: 16)
                }
                Text(hit.file.name)
                    .layoutPriority(1)
                if let anchor = hit.anchor {
                    Text(anchor.displayLabel)
                        .font(Theme.Font.mono)
                        .foregroundStyle(Theme.Color.textTertiary)
                }
                Spacer(minLength: 0)
            }
            Text(Snippet.attributed(hit.snippet))
                .font(Theme.Font.small)
                .foregroundStyle(Theme.Color.textSecondary)
                .truncationMode(.tail)
                .padding(.leading, 16 + Theme.Space.s)
        }
        .frame(height: 44)
    }
}

/// The index marks matches as `«…»`. Those runs read in `text`; the rest stays secondary.
enum Snippet {
    static func attributed(_ raw: String) -> AttributedString {
        var out = AttributedString()
        var run = ""
        var marked = false
        var pendingSpace = false
        var started = false
        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            if marked { piece.foregroundColor = Theme.Color.text }
            out.append(piece)
            run = ""
        }
        for ch in raw {
            switch ch {
            case "«":
                flush()
                marked = true
            case "»":
                flush()
                marked = false
            default:
                if ch.isWhitespace {
                    pendingSpace = started
                    continue
                }
                if pendingSpace {
                    run.append(" ")
                    pendingSpace = false
                }
                run.append(ch)
                started = true
            }
        }
        flush()
        return out
    }
}

// MARK: - Field

/// A bare `NSTextField`: no bezel, no placeholder, no focus ring. Arrow keys, Enter and Esc
/// go to the model through the delegate; everything else is ordinary text editing.
private struct PaletteField: NSViewRepresentable {
    @ObservedObject var model: PaletteModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> PaletteTextField {
        let field = PaletteTextField(frame: .zero)
        field.delegate = context.coordinator
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.NS.body
        field.textColor = Theme.NS.text
        field.placeholderString = nil
        field.lineBreakMode = .byClipping
        if let cell = field.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.wraps = false
            cell.isScrollable = true
        }
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.stringValue = model.query
        model.field = field
        return field
    }

    func updateNSView(_ field: PaletteTextField, context: Context) {
        if field.stringValue != model.query, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { field.stringValue = model.query }
        field.setAccessibilityLabel("Search files, folders and contents")
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: PaletteTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? field.intrinsicContentSize.width, height: field.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: PaletteModel
        init(model: PaletteModel) { self.model = model }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            model.query = field.stringValue
            model.submitPending = false
            model.queryDidChange?()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                model.moveHighlight(-1)
            case #selector(NSResponder.moveDown(_:)):
                model.moveHighlight(1)
            case #selector(NSResponder.insertNewline(_:)):
                // ⌘↩ opens the highlighted file outside; ↩ may show every file found (`submit`).
                if NSApp.currentEvent?.modifierFlags.contains(.command) == true { model.runHighlighted(externally: true) }
                else { model.submit() }
            case #selector(NSResponder.cancelOperation(_:)):
                model.cancel()
            default:
                return false
            }
            return true
        }
    }
}

final class PaletteTextField: NSTextField {
    override var acceptsFirstResponder: Bool { true }
}
