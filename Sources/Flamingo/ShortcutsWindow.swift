import AppKit
import SwiftUI
import FlamingoDesign

/// Help ▸ Keyboard Shortcuts (⌘/): every key in `ShortcutCatalog`, filtered as you type. A
/// window of its own, like Settings, so it can stay beside the main window while you try the
/// keys out. ⌘/ again, ⌘W, or Esc in an empty field closes it. Plan 01 owns.
@MainActor
final class ShortcutsWindowController: NSWindowController {
    final class Content: ObservableObject {
        @Published var groups: [ShortcutGroup] = []
    }

    private static var shared: ShortcutsWindowController?
    private let content = Content()

    static func toggle(captureKeys: String) {
        if let window = shared?.window, window.isKeyWindow { window.performClose(nil); return }
        let controller = shared ?? ShortcutsWindowController()
        shared = controller
        // The capture key can change (⌃⌥⌘Space when ⌃⌥Space switches input sources).
        controller.content.groups = ShortcutCatalog.groups(captureKeys: captureKeys)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Keyboard Shortcuts"
        window.isReleasedWhenClosed = false
        window.backgroundColor = Theme.NS.bg
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 480, height: 360)
        super.init(window: window)
        let host = NSHostingController(rootView: ShortcutsView(content: content) { [weak window] in window?.performClose(nil) })
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: 640, height: 680))
        window.center()
        window.setFrameAutosaveName("FlamingoShortcuts")
    }

    required init?(coder: NSCoder) { fatalError() }
}

private struct ShortcutsView: View {
    @ObservedObject var content: ShortcutsWindowController.Content
    let close: () -> Void
    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let shown = ShortcutCatalog.filter(content.groups, query)
        VStack(spacing: 0) {
            SearchField(text: $query, focused: $fieldFocused,
                        onExit: { if query.isEmpty { close() } else { query = "" } })
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.m)
            Hairline()
            if shown.isEmpty {
                EmptyState("No shortcuts")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.xl) {
                        ForEach(shown) { ShortcutGroupView(group: $0) }
                    }
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.vertical, Theme.Space.l)
                }
            }
        }
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
        .background(Theme.Color.bg)
        .onAppear { fieldFocused = true }
    }
}

private struct ShortcutGroupView: View {
    let group: ShortcutGroup

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                SectionMarker(group.title)
                if let context = group.context {
                    Text(context)
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.Color.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.bottom, Theme.Space.xs)
            ForEach(group.items, id: \.self) { ShortcutRow(shortcut: $0) }
        }
    }
}

/// The action on the left, its keys on the right, as in a menu.
private struct ShortcutRow: View {
    let shortcut: Shortcut

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text(shortcut.action)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.m)
            HStack(spacing: Theme.Space.xs) {
                ForEach(Array(shortcut.keys.enumerated()), id: \.offset) { KeyCap(keys: $0.element) }
            }
            .fixedSize()
        }
        .frame(minHeight: Theme.Size.row)
        .accessibilityElement(children: .combine)
    }
}

private struct KeyCap: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(Theme.Font.body)
            .monospacedDigit()
            .foregroundStyle(Theme.Color.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Squircle(radius: Theme.Radius.s).fill(Theme.Color.fill))
    }
}
