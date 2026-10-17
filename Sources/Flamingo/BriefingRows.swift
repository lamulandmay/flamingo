import AppKit
import SwiftUI
import FlamingoCore
import FlamingoDesign
import FlamingoCapture
import FlamingoExtract
import FlamingoIndex
import FlamingoThoughts
import FlamingoTrail

// MARK: - Thumbnails

/// A Quick Look thumbnail of a vault file, cached; the file's glyph on a quiet fill until it arrives
/// (or when the file has no preview).
struct BriefingThumb: View {
    let file: FileRef
    let vault: Vault?
    var size: CGSize
    var radius: CGFloat

    @State private var image: NSImage?
    private static let cache = NSCache<NSString, NSImage>()

    private var key: NSString { "\(file.relativePath)|\(Int(size.width))x\(Int(size.height))" as NSString }

    var body: some View {
        let shape = Squircle(radius: radius)
        ZStack {
            shape.fill(Theme.Color.fill)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .transition(.opacity)
            } else {
                FileGlyph(ext: file.ext, size: max(13, min(size.width, size.height) * 0.36))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.Color.hairline, lineWidth: Theme.Size.hairline))
        .animation(Theme.Motion.normal, value: image == nil)
        .task(id: file) {
            if let hit = Self.cache.object(forKey: key) { image = hit; return }
            guard let vault else { return }
            let url = vault.url(for: file)
            let loaded = await Thumbnails.thumbnail(for: url, in: vault, size: CGSize(width: size.width * 2, height: size.height * 2), scale: 2)
            if let loaded { Self.cache.setObject(loaded, forKey: key); image = loaded }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Thought rows

/// The 44 pt row of "thoughts to address first": the thought on line one, its place on line two.
struct BriefingThoughtRow: View {
    @ObservedObject var model: BriefingModel
    let ranked: RankedThought
    let index: Int
    let now: Date
    let files: [FileRef]

    @State private var hovering = false

    private var record: ThoughtRecord { ranked.record }
    private var item: BriefingItem { .thought(ranked) }
    private var selected: Bool { model.selection == item.id }
    private var leaving: Bool { model.leaving.contains(item.id) }
    private var flash: Int? { model.flashing[item.id] }

    var body: some View {
        VStack(spacing: 0) {
            line
            if model.replying == item.id { reply.transition(.opacity) }
        }
        .opacity(leaving ? 0 : 1)
        .animation(Theme.Motion.fast, value: leaving)
        .fadesIn(model.visible, delay: 0.14 + 0.02 * Double(min(index, 6)))
    }

    private var line: some View {
        HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Space.s) {
                    leadingGlyph.frame(width: 16)
                    Text(BriefingFormat.plain(record.comment.firstLine))
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.Color.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HStack(spacing: Theme.Space.xs + 2) {
                    FileGlyph(ext: record.file.ext, size: 11).frame(width: 16)
                    Text(record.file.isVirtual ? "" : record.file.name)
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                    if let anchor = record.comment.anchor { Chip(text: anchor.displayLabel) }
                    Text(dateLabel)
                        .font(Theme.Font.monoSmall)
                        .foregroundStyle(Theme.Color.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 0)
                }
            }
            trailing.frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 44)
        .background(Squircle(radius: Theme.Radius.s).fill(selected ? Theme.Color.selection : hovering ? Theme.Color.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.select(item.id); model.open(item) }
        .animation(Theme.Motion.fast, value: hovering)
        .animation(Theme.Motion.fast, value: selected)
    }

    /// The kind's glyph; for the 150 ms after Done, a check tinted by the thought's strength.
    @ViewBuilder private var leadingGlyph: some View {
        if let level = flash {
            Image(systemName: "checkmark.circle")
                .font(.system(size: Theme.Size.iconSmall))
                .foregroundStyle(Theme.Color.thought(level))
        } else {
            KindGlyph(kind: record.kind, state: .open)
        }
    }

    @ViewBuilder private var trailing: some View {
        if hovering && !leaving {
            HStack(spacing: 0) {
                IconButton("checkmark", help: "Done") { model.select(item.id); model.done(item) }
                IconButton("moon", help: "Snooze") { model.select(item.id); model.snooze(item) }
            }
            .transition(.opacity)
        } else if let symbol = ranked.reason.symbol {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textTertiary)
                .frame(width: 24, height: 24)
                .transition(.opacity)
        }
    }

    private var dateLabel: String {
        if let due = record.due { return BriefingFormat.due(due, now: now) }
        return BriefingFormat.short(record.comment.timestamp, now: now)
    }

    private var reply: some View {
        ReplyField(model: model, files: files)
            .padding(.leading, Theme.Space.s + 16 + Theme.Space.s)
            .padding(.trailing, Theme.Space.s)
            .padding(.vertical, Theme.Space.xs)
    }
}

/// The inline reply: the same text view as the capture panel, so `[[` completes file names.
private struct ReplyField: View {
    @ObservedObject var model: BriefingModel
    let files: [FileRef]
    @State private var focused = false
    @State private var request = 0

    var body: some View {
        ThoughtField(text: $model.replyText, focused: $focused, placeholder: "", candidates: files, recent: [],
                     focusRequest: request, onSubmit: { model.submitReply() }, onCancel: { model.cancelInline() })
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.s)
            .background(Squircle(radius: Theme.Radius.m).fill(Theme.Color.fill))
            .focusRing(focused, radius: Theme.Radius.m)
            .onAppear { DispatchQueue.main.async { request += 1 } }
    }
}

// MARK: - Needs attention

/// One 26 pt row in the right-hand column.
struct BriefingAttentionRow: View {
    @ObservedObject var model: BriefingModel
    let item: BriefingItem
    let now: Date

    @State private var hovering = false
    private var selected: Bool { model.selection == item.id }
    private var leaving: Bool { model.leaving.contains(item.id) }

    var body: some View {
        VStack(spacing: 0) {
            row
            if model.attaching == item.id { AttachField(model: model).transition(.opacity) }
        }
        .opacity(leaving ? 0 : 1)
        .animation(Theme.Motion.fast, value: leaving)
        .fadesIn(model.visible, delay: 0.2)
    }

    private var row: some View {
        HStack(spacing: Theme.Space.s) {
            glyph.frame(width: 16)
            Text(title)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.s)
            trailing
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(maxWidth: .infinity, minHeight: Theme.Size.row, alignment: .leading)
        .background(Squircle(radius: Theme.Radius.s).fill(selected ? Theme.Color.selection : hovering ? Theme.Color.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.select(item.id); model.open(item) }
        .environment(\.flamingoRowSelected, selected)
        .animation(Theme.Motion.fast, value: hovering)
        .animation(Theme.Motion.fast, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var glyph: some View {
        switch item {
        case .edited(let e): FileGlyph(ext: e.file.ext, size: Theme.Size.iconSmall)
        case .suggestion(let s): FileGlyph(ext: s.other.ext, size: Theme.Size.iconSmall)
        case .loose: symbol("tray")
        case .draft: symbol("pencil.line")
        case .problems: symbol("exclamationmark.triangle")
        default: EmptyView()
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: Theme.Size.iconSmall)).foregroundStyle(Theme.Color.textSecondary)
    }

    private var title: String {
        switch item {
        case .edited(let e): e.file.name
        case .suggestion(let s): s.other.name
        case .loose(let r): BriefingFormat.plain(r.comment.firstLine)
        case .draft(_, let text): text
        case .problems: ""
        default: ""
        }
    }

    @ViewBuilder private var trailing: some View {
        switch item {
        case .edited(let e):
            mono(BriefingFormat.short(e.modified, now: now))
        case .loose(let r):
            mono(BriefingFormat.short(r.comment.timestamp, now: now))
        case .suggestion(let s):
            HStack(spacing: 0) {
                IconButton("checkmark", help: "Connect") { model.select(item.id); model.done(item) }
                IconButton("xmark", help: "Dismiss") { model.select(item.id); model.dismiss(item) }
            }
            .opacity(selected || hovering ? 1 : 0.55)
            .help(s.passage ?? "")
        case .problems(let p):
            mono("\(p.total)")
        default:
            EmptyView()
        }
    }

    private func mono(_ text: String) -> some View {
        Text(text).font(Theme.Font.monoSmall).foregroundStyle(Theme.Color.textTertiary).lineLimit(1).fixedSize()
    }
}

/// Where a loose capture goes: a field, then the files that match.
private struct AttachField: View {
    @ObservedObject var model: BriefingModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            SearchField(text: $model.attachQuery, focused: $focused,
                        onSubmit: { if let first = model.attachMatches.first { model.attach(to: first) } },
                        onExit: { model.cancelInline() })
            ForEach(model.attachMatches, id: \.self) { file in
                Button { model.attach(to: file) } label: {
                    HStack(spacing: Theme.Space.s) {
                        FileGlyph(ext: file.ext)
                        Text(file.name).lineLimit(1)
                        Spacer(minLength: Theme.Space.s)
                        Text(file.directory)
                            .font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary)
                            .lineLimit(1).truncationMode(.head)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .flamingoRow(selected: false)
            }
        }
        .padding(.leading, Theme.Space.s + 16 + Theme.Space.s)
        .padding(.vertical, Theme.Space.xs)
        .onChange(of: model.attachQuery) { model.searchTargets() }
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

// MARK: - Resume

/// A 96×64 thumbnail of a place to pick up from.
struct BriefingResumeTile: View {
    @ObservedObject var model: BriefingModel
    let index: Int
    let location: TrailLocation
    let vault: Vault?

    @State private var hovering = false
    private var item: BriefingItem { .resume(index, location) }
    private var selected: Bool { model.selection == item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
            BriefingThumb(file: location.file, vault: vault, size: Theme.Size.tile, radius: Theme.Radius.m)
                .overlay(ConcentricSquircle(parentRadius: Theme.Radius.m, padding: 0)
                    .strokeBorder(Theme.Color.accent.opacity(0.75), lineWidth: 1.5)
                    .opacity(selected ? 1 : 0))
                .opacity(hovering || selected ? 1 : Theme.Opacity.rest + 0.1)
            Text(location.file.name)
                .font(Theme.Font.small)
                .foregroundStyle(Theme.Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Theme.Size.tile.width, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.select(item.id); model.open(item) }
        .animation(Theme.Motion.fast, value: hovering)
        .animation(Theme.Motion.fast, value: selected)
        .fadesIn(model.visible, delay: 0.3 + Theme.Motion.staggerSeconds * Double(index))
    }
}

// MARK: - Fades

extension View {
    /// Opacity only: 0 until `visible`, then 220 ms ease-out after `delay`. Leaving is quick and not delayed.
    func fadesIn(_ visible: Bool, delay: Double) -> some View {
        opacity(visible ? 1 : 0)
            .animation(visible ? Theme.Motion.normal.delay(delay) : Theme.Motion.fast, value: visible)
    }
}

extension BriefingFormat {
    /// A due date the way the rail writes it: the weekday within the week (`fri`), else `Oct 23`.
    static func due(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 99
        let f = DateFormatter()
        f.locale = locale; f.calendar = calendar; f.timeZone = calendar.timeZone
        if (-6..<7).contains(days) {
            f.setLocalizedDateFormatFromTemplate("EEE")
            return f.string(from: date).lowercased()
        }
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: date)
    }
}
