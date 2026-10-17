import AppKit
import SwiftUI
import FlamingoCore
import FlamingoDesign
import FlamingoIndex
import FlamingoThoughts

/// What a night-shift memo is about, as the card shows it.
enum MemoCardFacts {
    /// Up to three distinct source files, from the memo's `sources` lines (`path#anchor · time`).
    static func sourceFiles(of memo: WorkMemo, limit: Int = 3) -> [FileRef] {
        var out: [FileRef] = []
        func add(_ raw: String) {
            let head = raw.components(separatedBy: " \u{00B7} ").first ?? raw
            let path = head.split(separator: "#", maxSplits: 1).first.map(String.init) ?? head
            let ref = FileRef(relativePath: path.trimmingCharacters(in: .whitespaces))
            if !ref.relativePath.isEmpty, !out.contains(ref) { out.append(ref) }
        }
        memo.sources.forEach(add)
        if out.isEmpty { add(memo.on) }
        return Array(out.prefix(limit))
    }

    /// A monochrome glyph for the verdict, or for the recipe when it has none.
    static func verdictSymbol(_ memo: WorkMemo) -> String? {
        switch memo.verdict {
        case "conflict": return "exclamationmark.triangle"
        case "consistent": return "checkmark.circle"
        case "changed": return "arrow.left.arrow.right"
        case "same": return "equal.circle"
        case "unclear": return "questionmark.circle"
        default: break
        }
        switch memo.recipe {
        case "summarize": return "text.alignleft"
        case "answer": return "text.bubble"
        case "find-related": return "link"
        default: return nil
        }
    }
}

/// Source thumbnails side by side, each overlapping the last by 12 pt behind a ring.
struct MemoThumbnails: View {
    let files: [FileRef]
    let vault: Vault?

    var body: some View {
        HStack(spacing: -12) {
            ForEach(Array(files.enumerated()), id: \.element) { i, file in
                BriefingThumb(file: file, vault: vault, size: CGSize(width: Theme.Size.thumbnail, height: Theme.Size.thumbnail),
                              radius: Theme.Radius.s)
                    .padding(2)
                    .background(Squircle(radius: Theme.Radius.s + 2).fill(Theme.Color.bg))
                    .zIndex(Double(files.count - i))
            }
        }
        .padding(-2)
    }
}

/// A memo the night shift wrote: its sources, title, TL;DR, your thought and its verdict. Click opens the reader.
struct MemoCard: View {
    let data: MemoCardData
    let thought: ThoughtRecord?
    let vault: Vault?
    let selected: Bool
    let onOpen: () -> Void

    @State private var hovering = false

    var body: some View {
        let shape = Squircle(radius: Theme.Radius.l)
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top) {
                MemoThumbnails(files: MemoCardFacts.sourceFiles(of: data.memo), vault: vault)
                Spacer(minLength: Theme.Space.s)
                if let symbol = MemoCardFacts.verdictSymbol(data.memo) {
                    Image(systemName: symbol)
                        .font(.system(size: Theme.Size.iconSmall))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .padding(.top, 2)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(data.memo.title)
                    .font(Theme.Font.title)
                    .foregroundStyle(Theme.Color.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(BriefingFormat.plain(data.tldr))
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text(BriefingFormat.plain(thought?.comment.firstLine ?? " "))
                .font(Theme.Font.small)
                .foregroundStyle(Theme.Color.textTertiary)
                .lineLimit(1)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 232, alignment: .top)
        .background(shape.fill(Theme.Color.bgRaised))
        .overlay(shape.fill(Theme.Color.hover).opacity(hovering ? 0.6 : 0))
        .overlay(shape.strokeBorder(selected ? Theme.Color.accent.opacity(0.7) : Theme.Color.hairline,
                                    lineWidth: selected ? 1.5 : Theme.Size.hairline))
        .contentShape(shape)
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .animation(Theme.Motion.fast, value: hovering)
        .animation(Theme.Motion.fast, value: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A memo being written while the night shift catches up: the file's thumbnail, the thought's
/// line, and a line that pulses until the memo lands.
struct MemoPlaceholderCard: View {
    let placeholder: BriefingPlaceholder
    let vault: Vault?

    var body: some View {
        let shape = Squircle(radius: Theme.Radius.l)
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            MemoThumbnails(files: [placeholder.file], vault: vault)
            Text(BriefingFormat.plain(placeholder.line))
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.textSecondary)
                .lineLimit(4, reservesSpace: true)
            Spacer(minLength: 0)
            ProgressHairline(value: nil)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 232, alignment: .top)
        .background(shape.fill(Theme.Color.bgRaised))
        .overlay(shape.strokeBorder(Theme.Color.hairline, lineWidth: Theme.Size.hairline))
        .clipShape(shape)
        .transition(.opacity)
    }
}
