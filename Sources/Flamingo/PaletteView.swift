import AppKit
import SwiftUI
import FlamingoCore
import FlamingoDesign
import FlamingoIndex

/// The palette's content: one field, then rows. No header, no footer, no empty state.
/// Plan 01 owns.
struct PaletteView: View {
    @ObservedObject var model: PaletteModel

    var body: some View {
        PanelChrome(shadow: false) {
            VStack(spacing: 0) {
                field
                if !model.items.isEmpty {
                    Hairline()
                    results
                }
                if let status = model.status {
                    Hairline()
                    Text(status)
                        .font(Theme.Font.small)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Color.textTertiary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.Space.m)
                        .frame(height: PaletteController.statusHeight)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// The magnifier is the only sign of search mode.
    private var field: some View {
        HStack(spacing: Theme.Space.s) {
            if model.mode == .search {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: Theme.Size.iconSmall))
                    .foregroundStyle(Theme.Color.textTertiary)
                    .accessibilityHidden(true)
            }
            PaletteField(model: model)
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: PaletteController.fieldHeight)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        PaletteRow(item: item, highlighted: index == model.highlight) { model.run(item) }
                            .id(item.id)
                    }
                }
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, Theme.Space.xs)
            }
            .onChange(of: model.highlight) { _, row in
                guard model.items.indices.contains(row) else { return }
                proxy.scrollTo(model.items[row].id)
            }
            .onChange(of: model.version) { _, _ in
                guard let first = model.items.first else { return }
                proxy.scrollTo(first.id, anchor: .top)
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
                    Text(anchor.label)
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
        if field.stringValue != model.query { field.stringValue = model.query }
        field.setAccessibilityLabel(model.mode == .search ? "Search" : "Open Quickly")
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
            model.queryDidChange?()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                model.moveHighlight(-1)
            case #selector(NSResponder.moveDown(_:)):
                model.moveHighlight(1)
            case #selector(NSResponder.insertNewline(_:)):
                model.runHighlighted(externally: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
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
