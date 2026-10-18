import AppKit
import SwiftUI
import FlamingoCore
import FlamingoDesign
import FlamingoThoughts

/// The morning inbox, laid over the whole window. Mounted by `RootLayout` while the model says so.
struct BriefingOverlay: View {
    @ObservedObject var model: BriefingModel
    let topInset: CGFloat
    @Environment(AppState.self) var state

    var body: some View {
        if model.isPresented {
            BriefingView(model: model, topInset: topInset, vault: state.vault, files: state.files)
                .opacity(model.visible ? 1 : 0)
        }
    }
}

/// A centred page up to 1080 pt wide on a 12-column grid with 24 pt gutters: the date, last night's
/// memos, the thoughts to address first beside what needs attention, and where you left off.
/// No headers; position and hairlines tell the regions apart.
struct BriefingView: View {
    @ObservedObject var model: BriefingModel
    let topInset: CGFloat
    let vault: Vault?
    let files: [FileRef]

    private let gutter = Theme.Space.xl
    private let cardCompactWidth: CGFloat = 280

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 900
            let width = max(320, min(1080, geo.size.width - (compact ? 48 : 96)))
            // A short window has no room for a pinned strip: it follows the lists instead.
            let pinned = geo.size.height >= 700
            ZStack {
                Theme.Color.bg
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: 0) {
                                page(width: width, compact: compact)
                                if !model.resume.isEmpty, !pinned { resumeStrip(width: width, compact: compact) }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .onChange(of: model.selection) { _, id in
                            guard let id else { return }
                            withAnimation(Theme.Motion.fast) { proxy.scrollTo(id) }
                        }
                        // Rows fade out over the last 24 pt instead of being cut mid-row by the strip.
                        .mask(alignment: .bottom) {
                            VStack(spacing: 0) {
                                Rectangle()
                                if !model.resume.isEmpty, pinned {
                                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 24)
                                }
                            }
                        }
                    }
                    if !model.resume.isEmpty, pinned { resumeStrip(width: width, compact: compact) }
                }
                if let memo = model.openMemo {
                    ZStack {
                        Theme.Color.bg.opacity(0.9)
                            .contentShape(Rectangle())
                            .onTapGesture { model.openMemo = nil; model.requestFocus() }
                        MemoReader(data: memo, thought: model.thought(for: memo), vault: vault,
                                   maxHeight: max(240, geo.size.height - 2 * topInset - Theme.Space.xl),
                                   onClose: { model.openMemo = nil; model.requestFocus() },
                                   onOpenLink: { model.openLink($0) })
                    }
                    .transition(.opacity)
                }
            }
            .animation(Theme.Motion.fast, value: model.openMemo?.id)
            .background(BriefingKeyCatcher(model: model, request: model.focusRequest))
        }
    }

    // MARK: Page

    private func page(width: CGFloat, compact: Bool) -> some View {
        let now = model.now()
        return VStack(alignment: .leading, spacing: 0) {
            dateLine(now)
                .fadesIn(model.visible, delay: 0)
                .padding(.bottom, Theme.Space.xxl)
            if !model.memos.isEmpty || !model.placeholders.isEmpty {
                cards(width: width, compact: compact)
                    .padding(.bottom, Theme.Space.xxl)
            }
            if !model.address.isEmpty || !model.attention.isEmpty {
                Hairline()
                    .fadesIn(model.visible, delay: 0.1)
                    .padding(.bottom, Theme.Space.l)
                lists(width: width, compact: compact, now: now)
            }
        }
        .frame(width: width, alignment: .leading)
        .padding(.top, topInset + Theme.Space.xxl)
        .padding(.bottom, Theme.Space.xl)
    }

    private func dateLine(_ now: Date) -> some View {
        (Text(BriefingFormat.weekday(now)).foregroundStyle(Theme.Color.text)
            + Text(" " + BriefingFormat.monthDay(now)).foregroundStyle(Theme.Color.textTertiary))
            .font(Theme.Font.display)
            .lineLimit(1)
    }

    // MARK: Cards

    /// Memos then placeholders, in one run so a row is as tall as its tallest card.
    private enum CardSlot: Identifiable {
        case memo(Int, MemoCardData)
        case placeholder(BriefingPlaceholder)
        var id: String {
            switch self {
            case .memo(_, let m): return "memo-" + m.id
            case .placeholder(let p): return "placeholder-\(p.id)"
            }
        }
    }

    private var cardSlots: [CardSlot] {
        model.memos.enumerated().map { CardSlot.memo($0.offset, $0.element) } + model.placeholders.map { CardSlot.placeholder($0) }
    }

    @ViewBuilder private func cardView(_ slot: CardSlot) -> some View {
        switch slot {
        case .memo(let i, let memo):
            let item = BriefingItem.memo(memo)
            MemoCard(data: memo, thought: model.thought(for: memo), vault: vault, selected: model.selection == item.id) {
                model.select(item.id); model.open(item)
            }
            .id(item.id)
            .fadesIn(model.visible, delay: 0.06 + Theme.Motion.staggerSeconds * Double(i))
        case .placeholder(let placeholder):
            MemoPlaceholderCard(placeholder: placeholder, vault: vault)
        }
    }

    /// Cards hug their content; every card in a row is as tall as the tallest.
    @ViewBuilder private func cards(width: CGFloat, compact: Bool) -> some View {
        let cardWidth = compact ? cardCompactWidth : (width - 2 * gutter) / 3
        let slots = cardSlots
        if compact {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: gutter) {
                    ForEach(slots) { cardView($0).frame(width: cardWidth).frame(maxHeight: .infinity, alignment: .top) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            let rows = stride(from: 0, to: slots.count, by: 3).map { Array(slots[$0..<min($0 + 3, slots.count)]) }
            VStack(alignment: .leading, spacing: gutter) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: gutter) {
                        ForEach(row) { cardView($0).frame(width: cardWidth).frame(maxHeight: .infinity, alignment: .top) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Lists

    @ViewBuilder private func lists(width: CGFloat, compact: Bool, now: Date) -> some View {
        let column = (width - 11 * gutter) / 12
        let left = 7 * column + 6 * gutter
        let right = 5 * column + 4 * gutter
        let hasAddress = !model.address.isEmpty, hasAttention = !model.attention.isEmpty
        if compact {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if hasAddress { thoughts(now: now) }
                if hasAddress && hasAttention { Hairline() }
                if hasAttention { attention(now: now) }
            }
        } else {
            HStack(alignment: .top, spacing: 0) {
                if hasAddress { thoughts(now: now).frame(width: left) }
                if hasAddress && hasAttention {
                    VHairline().frame(width: gutter)
                }
                if hasAttention { attention(now: now).frame(width: hasAddress ? right : right) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func thoughts(now: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(model.address.enumerated()), id: \.element.id) { i, ranked in
                BriefingThoughtRow(model: model, ranked: ranked, index: i, now: now, files: files)
                    .id(BriefingItem.thought(ranked).id)
            }
        }
        .padding(.horizontal, -Theme.Space.s)
    }

    private func attention(now: Date) -> some View {
        VStack(spacing: 2) {
            ForEach(model.attention) { item in
                BriefingAttentionRow(model: model, item: item, now: now).id(item.id)
            }
        }
        .padding(.horizontal, -Theme.Space.s)
        .padding(.leading, 0)
    }

    // MARK: Resume

    private func resumeStrip(width: CGFloat, compact: Bool) -> some View {
        VStack(spacing: 0) {
            Hairline().frame(width: width).fadesIn(model.visible, delay: 0.25)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: gutter) {
                    ForEach(Array(model.resume.enumerated()), id: \.offset) { i, location in
                        BriefingResumeTile(model: model, index: i, location: location, vault: vault)
                            .id(BriefingItem.resume(i, location).id)
                    }
                }
                .padding(.vertical, Theme.Space.l)
                .padding(.horizontal, 2)
                .frame(minWidth: width, alignment: .leading)
            }
            .frame(width: width + 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, Theme.Space.s)
    }
}

// MARK: - Keys

/// The page's keyboard: an AppKit first responder, so the sidebar's type-to-select never sees the
/// letters. Arrows and j/k move, Return opens, e / s / r / a triage, ⌫ dismisses, Esc leaves.
struct BriefingKeyCatcher: NSViewRepresentable {
    let model: BriefingModel
    let request: Int

    func makeNSView(context: Context) -> BriefingKeyView {
        let view = BriefingKeyView()
        view.model = model
        view.lastRequest = request
        return view
    }

    func updateNSView(_ view: BriefingKeyView, context: Context) {
        view.model = model
        if view.lastRequest != request {
            view.lastRequest = request
            DispatchQueue.main.async { view.takeKeyboard() }
        }
    }
}

final class BriefingKeyView: NSView {
    weak var model: BriefingModel?
    var lastRequest = 0

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.takeKeyboard() }
    }

    func takeKeyboard() {
        guard let window, window.firstResponder !== self else { return }
        // A reply or attach field in the page keeps the keyboard until it is done.
        if let responder = window.firstResponder as? NSView, responder !== self, responder.isDescendant(of: window.contentView ?? self),
           responder is NSText, model?.replying != nil || model?.attaching != nil { return }
        window.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let action = BriefingKeys.action(characters: event.charactersIgnoringModifiers, keyCode: event.keyCode,
                                         modifiers: event.modifierFlags)
        guard action != .none, let model else { return super.keyDown(with: event) }
        MainActor.assumeIsolated { model.handle(action) }
    }
}
