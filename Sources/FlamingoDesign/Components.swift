import SwiftUI
import AppKit

/// Shared components. Plan 08 owns; signatures of existing components are frozen.
/// Every component uses `Theme` and nothing else.

// MARK: - Hairlines

/// 1pt horizontal separator. Use instead of borders and boxes.
public struct Hairline: View {
    public init() {}
    public var body: some View { Rectangle().fill(Theme.Color.hairline).frame(height: Theme.Size.hairline) }
}

/// 1pt vertical separator.
public struct VHairline: View {
    public init() {}
    public var body: some View { Rectangle().fill(Theme.Color.hairline).frame(width: Theme.Size.hairline) }
}

// MARK: - Glyphs

/// A file-type glyph: the family's SF Symbol, tinted by `Theme.Color.family(ext:)`,
/// accent when selected. Fixed width so names line up.
///
/// Selection comes from an enclosing `flamingoRow(selected:)`, or pass `selected:` directly
/// when the row is a native `List`/`NSOutlineView` row. For AppKit cells use `nsImage(ext:size:)`
/// with `Theme.NS.family(ext:selected:)` as the image view's `contentTintColor`.
public struct FileGlyph: View {
    public let ext: String
    public var size: CGFloat
    public var selected: Bool?
    @Environment(\.flamingoRowSelected) private var rowSelected
    public init(ext: String, size: CGFloat = 14) { self.ext = ext; self.size = size }
    public init(ext: String, size: CGFloat = 14, selected: Bool) { self.ext = ext; self.size = size; self.selected = selected }
    public var body: some View {
        Image(systemName: FileGlyph.symbol(for: ext))
            .font(.system(size: size))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle((selected ?? rowSelected) ? Theme.Color.accent : Theme.Color.family(ext: ext))
            .frame(width: (size * 1.35).rounded())
            .accessibilityHidden(true)
    }

    /// The glyph as a template `NSImage` for AppKit rows. Tint it with
    /// `Theme.NS.family(ext:selected:)` through `NSImageView.contentTintColor`.
    public static func nsImage(ext: String, size: CGFloat = 14) -> NSImage? {
        let img = NSImage(systemSymbolName: symbol(for: ext), accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
        img?.isTemplate = true
        return img
    }

    /// Folder glyph as a template `NSImage`. Tint with `Theme.NS.textSecondary`, or `accent` when selected.
    public static func nsFolderImage(size: CGFloat = 14) -> NSImage? {
        let img = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
        img?.isTemplate = true
        return img
    }

    /// SF Symbol name for an extension. Unknown extensions get a plain `doc`.
    public static func symbol(for ext: String) -> String {
        let e = ext.lowercased()
        if FileFamily.audio.contains(e) { return "waveform" }
        if e == "zip" || e == "tar" || e == "gz" || e == "tgz" || e == "7z" || e == "rar" || e == "dmg" { return "archivebox" }
        return FileFamily(ext: e)?.symbol ?? "doc"
    }
}

/// Folder glyph for the sidebar tree. Secondary, accent when its row is selected.
public struct FolderGlyph: View {
    public var size: CGFloat
    public var selected: Bool?
    @Environment(\.flamingoRowSelected) private var rowSelected
    public init(size: CGFloat = 14) { self.size = size }
    public init(size: CGFloat = 14, selected: Bool) { self.size = size; self.selected = selected }
    public var body: some View {
        Image(systemName: "folder")
            .font(.system(size: size))
            .foregroundStyle((selected ?? rowSelected) ? Theme.Color.accent : Theme.Color.textSecondary)
            .frame(width: (size * 1.35).rounded())
            .accessibilityHidden(true)
    }
}

/// The Flamingo mark as a shape. Same geometry as the app and menu bar icons.
public struct FlamingoMark: Shape {
    public init() {}
    public func path(in rect: CGRect) -> Path { Path(FlamingoMarkPath.path(in: rect, flipped: false)) }

    /// The mark as a template `NSImage` for an `NSStatusItem`: 22pt square, mark 18pt tall.
    /// Drawn in code, so it needs nothing from the bundle.
    public static func menuBarImage(pointSize: CGFloat = 22) -> NSImage {
        let img = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { r in
            let inset = r.height * 2 / 22
            let path = FlamingoMarkPath.path(in: r.insetBy(dx: 0, dy: inset), flipped: true)
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.addPath(path)
            c.setFillColor(NSColor.black.cgColor)
            c.fillPath()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Flamingo"
        return img
    }
}

// MARK: - Small text

/// An anchor or tag: `slide 7`, `cell Q3!B12`. Mono by default. Pass `action` to make it
/// clickable (the rail's jump-to-anchor); hover raises the fill, never the size.
public struct Chip: View {
    public let text: String
    public var mono: Bool
    public var action: (() -> Void)?
    @State private var hovering = false

    public init(text: String, mono: Bool = true, action: (() -> Void)? = nil) {
        self.text = text; self.mono = mono; self.action = action
    }
    public init(_ text: String, mono: Bool = true, action: (() -> Void)? = nil) {
        self.init(text: text, mono: mono, action: action)
    }

    public var body: some View {
        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .pointingHandCursor()
        } else {
            label
        }
    }

    private var label: some View {
        let shape = Squircle(radius: Theme.Radius.s)
        return Text(text)
            .font(mono ? Theme.Font.monoSmall : Theme.Font.small)
            .foregroundStyle(Theme.Color.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(shape.fill(Theme.Color.fill))
            .background(shape.fill(Theme.Color.fill).opacity(hovering ? 1 : 0))
            .animation(Theme.Motion.fast, value: hovering)
    }
}

/// A shortcut as menus show it: `⌘K`. Only in menus and the command palette.
public struct KeyHint: View {
    public let keys: String
    public init(_ keys: String) { self.keys = keys }
    public var body: some View {
        Text(keys)
            .font(Theme.Font.small)
            .monospacedDigit()
            .tracking(1)
            .foregroundStyle(Theme.Color.textTertiary)
            .lineLimit(1)
            .fixedSize()
    }
}

/// The only empty state there is: one short noun phrase, tertiary, centered in the space.
/// `EmptyState("No vault open")`. Never a sentence, never an exclamation mark.
public struct EmptyState: View {
    public let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Color.textTertiary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// An 11pt medium, tracked, uppercase marker for the rare section that needs one.
public struct SectionMarker: View {
    public let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).capsStyle().foregroundStyle(Theme.Color.textTertiary).lineLimit(1)
    }
}

// MARK: - Panels and surfaces

/// `NSVisualEffectView` for SwiftUI. Sidebar material by default.
/// `blending: nil` picks behind-window inside panels and borderless windows,
/// within-window everywhere else, which is what floating chrome wants.
public struct VisualEffect: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blending: NSVisualEffectView.BlendingMode?
    public var state: NSVisualEffectView.State

    public init(_ material: NSVisualEffectView.Material = .sidebar,
                blending: NSVisualEffectView.BlendingMode? = .behindWindow,
                state: NSVisualEffectView.State = .followsWindowActiveState) {
        self.material = material; self.blending = blending; self.state = state
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let v = AdaptiveEffectView()
        update(v)
        return v
    }
    public func updateNSView(_ v: NSVisualEffectView, context: Context) { update(v) }

    private func update(_ v: NSVisualEffectView) {
        v.material = material
        v.state = state
        (v as? AdaptiveEffectView)?.fixedBlending = blending
        (v as? AdaptiveEffectView)?.resolveBlending()
    }
}

final class AdaptiveEffectView: NSVisualEffectView {
    var fixedBlending: NSVisualEffectView.BlendingMode?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); resolveBlending() }
    func resolveBlending() {
        if let fixedBlending { blendingMode = fixedBlending; return }
        guard let w = window else { return }
        blendingMode = (w is NSPanel || !w.isOpaque || w.styleMask.contains(.borderless)) ? .behindWindow : .withinWindow
    }
}

/// Chrome for the command palette, search, and comment panel: sidebar material,
/// `Radius.l`, a hairline, a soft shadow. 560pt wide unless told otherwise.
/// Inside an `NSPanel`, pass `shadow: false` and let the window draw its own.
public struct PanelChrome<Content: View>: View {
    public var width: CGFloat?
    public var shadow: Bool
    public let content: Content

    public init(width: CGFloat? = Theme.Size.panel, shadow: Bool = true, @ViewBuilder content: () -> Content) {
        self.width = width; self.shadow = shadow; self.content = content()
    }

    public var body: some View {
        let shape = Squircle(radius: Theme.Radius.l)
        content
            .frame(width: width)
            .background(VisualEffect(.sidebar, blending: nil, state: .active))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.Color.hairline, lineWidth: Theme.Size.hairline))
            .shadow(color: .black.opacity(shadow ? 0.28 : 0), radius: 24, y: 10)
    }
}

/// A one-line notice at the bottom of a region, with at most one action (`Undo`).
public struct Toast: View {
    public let text: String
    public var actionTitle: String?
    public var action: (() -> Void)?

    public init(_ text: String, action actionTitle: String? = nil, perform action: (() -> Void)? = nil) {
        self.text = text; self.actionTitle = actionTitle; self.action = action
    }

    public var body: some View {
        HStack(spacing: Theme.Space.m) {
            Text(text).font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary).lineLimit(1)
            Spacer(minLength: 0)
            if let actionTitle {
                Button(actionTitle) { action?() }
                    .buttonStyle(.plain)
                    .font(Theme.Font.small.weight(.medium))
                    .foregroundStyle(Theme.Color.accent)
                    .pointingHandCursor()
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 28)
        .background(Squircle(radius: Theme.Radius.m).fill(Theme.Color.bgRaised))
        .overlay(Squircle(radius: Theme.Radius.m)
            .strokeBorder(Theme.Color.hairline, lineWidth: Theme.Size.hairline))
        .transition(.opacity)
    }
}

// MARK: - Controls

/// The four modes, in toolbar order. Plan 01 maps these to its own state.
public enum FlamingoMode: Int, CaseIterable, Identifiable, Hashable, Sendable {
    case files, graph, trail, ask
    public var id: Int { rawValue }
    public var symbol: String {
        switch self {
        case .files: "folder"
        case .graph: "point.3.connected.trianglepath.dotted"
        case .trail: "point.topleft.down.to.point.bottomright.curvepath"
        case .ask: "sparkle"
        }
    }
    /// For menus, tooltips and VoiceOver. Never drawn in the control itself.
    public var title: String {
        switch self {
        case .files: "Files"
        case .graph: "Graph"
        case .trail: "Trail"
        case .ask: "Chat"
        }
    }
    /// ⌘1–⌘4.
    public var key: KeyEquivalent { KeyEquivalent(Character(String(rawValue + 1))) }
    /// The views the toolbar switches between. Chat is a sidebar, not a view.
    public static let views: [FlamingoMode] = [.files, .graph, .trail]
}

/// Four SF Symbols, no text. Selected mode is accent on a raised segment.
public struct SegmentedModes: View {
    @Binding public var selection: FlamingoMode
    public init(selection: Binding<FlamingoMode>) { self._selection = selection }
    /// `0` files, `1` graph, `2` trail, `3` ask, so a shell enum's `rawValue` binds directly.
    public init(selection: Binding<Int>) {
        self._selection = Binding(
            get: { FlamingoMode(rawValue: selection.wrappedValue) ?? .files },
            set: { selection.wrappedValue = $0.rawValue })
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(FlamingoMode.views) { m in
                ModeSegment(mode: m, selected: selection == m) { selection = m }
            }
        }
        .padding(2)
        .background(Squircle(radius: Theme.Radius.m).fill(Theme.Color.hover))
        .animation(Theme.Motion.fast, value: selection)
    }
}

private struct ModeSegment: View {
    let mode: FlamingoMode
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: mode.symbol)
                .font(.system(size: Theme.Size.iconSmall))
                .foregroundStyle(selected ? Theme.Color.accent : Theme.Color.textSecondary)
                .opacity(selected || hovering ? 1 : Theme.Opacity.rest)
                .frame(width: 32, height: 22)
                .background(ConcentricSquircle(parentRadius: Theme.Radius.m, padding: 2)
                    .fill(Theme.Color.fill)
                    .opacity(selected ? 1 : 0))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fast, value: hovering)
        .help(mode.title)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A search field with no placeholder: a magnifier, the text, a clear button once there
/// is text. Accent focus ring.
///
/// Pass `focused` to drive focus from outside (the graph's filter takes focus when you type
/// on the canvas). Pass `onExit` to handle Esc in the field; without it Esc goes up the
/// responder chain, so a panel can dismiss itself.
public struct SearchField: View {
    @Binding public var text: String
    public var onSubmit: (() -> Void)?
    public var onExit: (() -> Void)?
    private var external: FocusState<Bool>.Binding?
    @FocusState private var focused: Bool

    public init(text: Binding<String>, focused: FocusState<Bool>.Binding? = nil,
                onSubmit: (() -> Void)? = nil, onExit: (() -> Void)? = nil) {
        self._text = text; self.external = focused; self.onSubmit = onSubmit; self.onExit = onExit
    }

    private var isFocused: Bool { external?.wrappedValue ?? focused }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Color.textTertiary)
                .accessibilityHidden(true)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .focused(external ?? $focused)
                .onSubmit { onSubmit?() }
                .onExitCommand(perform: onExit)
                .accessibilityLabel("Search")
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Color.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: Theme.Size.row)
        .background(Squircle(radius: Theme.Radius.m - 2).fill(Theme.Color.fill))
        .focusRing(isFocused, radius: Theme.Radius.m - 2)
        .animation(Theme.Motion.fast, value: text.isEmpty)
    }
}

/// A plain icon button: 13pt symbol, secondary, full opacity on hover, accent when `isOn`.
/// `help` becomes the tooltip and the VoiceOver label; it is never drawn.
public struct IconButton: View {
    public let systemName: String
    public var help: String
    public var isOn: Bool
    public let action: () -> Void
    @State private var hovering = false

    public init(_ systemName: String, help: String, isOn: Bool = false, action: @escaping () -> Void) {
        self.systemName = systemName; self.help = help; self.isOn = isOn; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: Theme.Size.iconSmall))
                .foregroundStyle(isOn ? Theme.Color.accent : Theme.Color.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hovering || isOn ? 1 : Theme.Opacity.rest)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fast, value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Thin accent progress line, 2pt. `value` 0…1 fills left to right and fades out at 1;
/// `nil` pulses for indeterminate work.
public struct ProgressHairline: View {
    public var value: Double?
    @State private var pulse = false
    public init(value: Double?) { self.value = value }

    public var body: some View {
        GeometryReader { g in
            if let value {
                Rectangle()
                    .fill(Theme.Color.accent)
                    .frame(width: g.size.width * min(max(value, 0), 1))
            } else {
                Rectangle()
                    .fill(Theme.Color.accent)
                    .opacity(pulse ? 0.9 : 0.25)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
                    }
            }
        }
        .frame(height: 2)
        .opacity((value ?? 0) >= 1 ? 0 : 1)
        .animation(Theme.Motion.normal, value: value)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(value.map { "\(Int($0 * 100)) percent" } ?? "")
    }
}

// MARK: - Modifiers

extension EnvironmentValues {
    /// True inside a selected `flamingoRow`. `FileGlyph` and `FolderGlyph` turn accent.
    @Entry public var flamingoRowSelected: Bool = false
}

extension View {
    /// A list row: 26pt minimum height, `Space.s` inset, hover fill, accent-tinted
    /// selection with `Radius.s`. For custom lists; a native `List` draws its own selection.
    public func flamingoRow(selected: Bool) -> some View { modifier(FlamingoRow(selected: selected)) }

    /// `Theme.Font.caps` + tracking + uppercase.
    public func capsStyle() -> some View {
        font(Theme.Font.caps).tracking(Theme.Font.capsTracking).textCase(.uppercase)
    }

    /// A 2pt accent ring just outside the view, the way macOS draws focus.
    public func focusRing(_ visible: Bool, radius: CGFloat = Theme.Radius.s) -> some View {
        overlay(
            // The child's own outline grown 2pt along its normals: concentric at every point.
            ConcentricSquircle(parentRadius: radius, padding: -2)
                .strokeBorder(Theme.Color.accent.opacity(0.55), lineWidth: 2)
                .padding(-2)
                .opacity(visible ? 1 : 0)
                .animation(Theme.Motion.fast, value: visible)
                .allowsHitTesting(false)
        )
    }

    /// Pointing-hand cursor while hovering. For chips and inline links.
    public func pointingHandCursor() -> some View { modifier(PointingHand()) }
}

private struct PointingHand: ViewModifier {
    @State private var pushed = false
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.link)
        } else {
            // Balance push/pop even if the view goes away mid-hover.
            content
                .onHover { inside in
                    if inside, !pushed { NSCursor.pointingHand.push(); pushed = true }
                    if !inside, pushed { NSCursor.pop(); pushed = false }
                }
                .onDisappear { if pushed { NSCursor.pop(); pushed = false } }
        }
    }
}

private struct FlamingoRow: ViewModifier {
    let selected: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Color.text)
            .lineLimit(1)
            .padding(.horizontal, Theme.Space.s)
            .frame(maxWidth: .infinity, minHeight: Theme.Size.row, alignment: .leading)
            .background(Squircle(radius: Theme.Radius.s)
                .fill(selected ? Theme.Color.selection : hovering ? Theme.Color.hover : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .environment(\.flamingoRowSelected, selected)
            .animation(Theme.Motion.fast, value: hovering)
            .animation(Theme.Motion.fast, value: selected)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
