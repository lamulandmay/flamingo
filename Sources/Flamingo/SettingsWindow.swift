import AppKit
import SwiftUI
import FlamingoAsk
import FlamingoCapture
import FlamingoCore
import FlamingoDesign

/// Flamingo ▸ Settings… (⌘,), laid out like Finder's: a toolbar of panes over plain controls.
/// Nothing here takes room in the main window. Plan 01 owns; the Chat pane is plan 09's
/// `AskSettingsPane`.
@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    enum Pane: String, CaseIterable {
        case general, chat, thoughts, capture, index

        var title: String {
            switch self {
            case .general: "General"
            case .chat: "Chat"
            case .thoughts: "Thoughts"
            case .capture: "Capture"
            case .index: "Index"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .chat: "bubble.left.and.text.bubble.right"
            case .thoughts: "text.bubble"
            case .capture: "keyboard"
            case .index: "externaldrive"
            }
        }
    }

    final class Selection: ObservableObject {
        @Published var pane: Pane = .general
    }

    private static var shared: SettingsWindowController?

    static func show(state: AppState, pane: Pane? = nil) {
        let controller = shared ?? SettingsWindowController(state: state)
        shared = controller
        controller.select(pane ?? Defaults.settingsPane.flatMap(Pane.init(rawValue:)) ?? .general)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private let selection = Selection()

    private init(state: AppState) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.backgroundColor = Theme.NS.bg
        window.tabbingMode = .disallowed
        let host = NSHostingController(rootView: SettingsRoot(selection: selection).environmentObject(state))
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "com.flamingo.settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.center()
        window.setFrameAutosaveName("FlamingoSettings")
    }

    required init?(coder: NSCoder) { fatalError() }

    func select(_ pane: Pane) {
        selection.pane = pane
        window?.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(pane.rawValue)
        window?.title = pane.title
        Defaults.settingsPane = pane.rawValue
    }

    @objc private func toolbarSelect(_ item: NSToolbarItem) {
        Pane(rawValue: item.itemIdentifier.rawValue).map(select)
    }

    // MARK: NSToolbarDelegate

    private var identifiers: [NSToolbarItem.Identifier] { Pane.allCases.map { NSToolbarItem.Identifier($0.rawValue) } }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = Pane(rawValue: id.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(toolbarSelect(_:))
        return item
    }
}

private struct SettingsRoot: View {
    @ObservedObject var selection: SettingsWindowController.Selection

    var body: some View {
        Group {
            switch selection.pane {
            case .general: GeneralSettings()
            case .chat: AskSettingsPane()
            case .thoughts: ThoughtSettings()
            case .capture: CaptureSettings()
            case .index: IndexSettings()
            }
        }
        .id(selection.pane)
        .padding(Theme.Space.xl)
        .frame(width: 560, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.Color.bg)
    }
}

/// One line of tertiary text under a control.
private func footnote(_ text: String) -> some View {
    Text(text)
        .font(Theme.Font.small)
        .foregroundStyle(Theme.Color.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
}

/// A UserDefaults string, empty when unset so the field's prompt shows the default.
private func storedName(_ key: String) -> String { UserDefaults.standard.string(forKey: key) ?? "" }
private func storeName(_ value: String, _ key: String) {
    let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
    UserDefaults.standard.set(name.isEmpty ? nil : name, forKey: key)
}

enum Appearance: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: General

private struct GeneralSettings: View {
    @EnvironmentObject var state: AppState
    @State private var appearance = Defaults.appearance
    @State private var inboxEachDay = Defaults.briefingAutoOpen
    @State private var offerProjects = Defaults.offerAgentProjects
    @State private var holdDelay = Defaults.radialHoldDelay
    @State private var writingFont = Defaults.writingFont
    @State private var writingSize = Defaults.writingSize

    var body: some View {
        Form {
            LabeledContent("Vault:") {
                HStack(spacing: Theme.Space.s) {
                    Text(state.vault.map { ($0.root.path as NSString).abbreviatingWithTildeInPath } ?? "None")
                        .font(Theme.Font.monoSmall)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .lineLimit(1).truncationMode(.head)
                    Button("Change…") { state.openVaultDialog() }
                }
            }
            Picker("Appearance:", selection: $appearance) {
                ForEach(Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()

            Divider().padding(.vertical, Theme.Space.s)

            Toggle("Reveal the open file in the sidebar", isOn: $state.autoReveal)
            Toggle("Open the inbox the first time each day", isOn: $inboxEachDay)
            Toggle("Offer to make folders agents work in into projects", isOn: $offerProjects)

            Divider().padding(.vertical, Theme.Space.s)

            LabeledContent("Recent files ring:") {
                HStack(spacing: Theme.Space.s) {
                    Slider(value: $holdDelay, in: 0.15...1).frame(width: 180)
                    Text(holdDelay.formatted(.number.precision(.fractionLength(2))) + " s")
                        .font(Theme.Font.small).monospacedDigit()
                        .foregroundStyle(Theme.Color.textSecondary)
                }
            }
            footnote("How long ⌘⌥ is held before the ring opens.")

            Divider().padding(.vertical, Theme.Space.s)

            Picker("Writing font:", selection: $writingFont) {
                ForEach(WritingFont.allCases, id: \.self) { Text($0.title).font(Font($0.font(13))).tag($0) }
            }
            .fixedSize()
            Picker("Text size:", selection: $writingSize) {
                ForEach(WritingFont.sizes, id: \.self) { Text("\(Int($0)) pt").tag($0) }
            }
            .fixedSize()
            footnote("Markdown notes. Code and plain text stay monospaced.")
        }
        .formStyle(.columns)
        .onChange(of: writingFont) { Defaults.writingFont = writingFont; NotificationCenter.default.post(name: .writingFontChanged, object: nil) }
        .onChange(of: writingSize) { Defaults.writingSize = writingSize; NotificationCenter.default.post(name: .writingFontChanged, object: nil) }
        .onChange(of: appearance) { Defaults.appearance = appearance; appearance.apply() }
        .onChange(of: inboxEachDay) { Defaults.briefingAutoOpen = inboxEachDay }
        .onChange(of: offerProjects) { Defaults.offerAgentProjects = offerProjects; state.agentProjects.settingChanged() }
        .onChange(of: holdDelay) {
            Defaults.radialHoldDelay = holdDelay
            RadialRecentsController.shared?.reloadHoldDelay()
        }
    }
}

// MARK: Thoughts

/// Everything that reads thoughts runs on this Mac, with no setting that sends them anywhere.
private struct ThoughtSettings: View {
    @EnvironmentObject var state: AppState
    @State private var nightShift = Defaults.nightShiftEnabled
    @State private var thoughtModel = storedName("FlamingoThoughtModel")
    @State private var titleModel = storedName("FlamingoTitleModel")

    var body: some View {
        Form {
            Toggle("Work on open thoughts overnight", isOn: $nightShift)
            Toggle("Analyze files saved from Flamingo", isOn: $state.automaticAnalysis)

            Divider().padding(.vertical, Theme.Space.s)

            LabeledContent("Thought model:") { modelField("Thought model", $thoughtModel) }
            LabeledContent("Titles and tags:") { modelField("Titles and tags model", $titleModel) }
            footnote("Ollama models on this Mac. Thoughts never leave it.")
        }
        .formStyle(.columns)
        .onChange(of: nightShift) { state.setNightShiftEnabled(nightShift) }
        .onChange(of: thoughtModel) { storeName(thoughtModel, "FlamingoThoughtModel") }
        .onChange(of: titleModel) { storeName(titleModel, "FlamingoTitleModel") }
    }
}

/// An Ollama model name; empty means the default, shown as the prompt.
private func modelField(_ name: String, _ text: Binding<String>) -> some View {
    TextField(name, text: text, prompt: Text("gemma3:4b"))
        .labelsHidden()
        .font(Theme.Font.mono)
        .frame(width: 200)
}

// MARK: Capture

private struct CaptureSettings: View {
    @EnvironmentObject var state: AppState
    @State private var captureGlobal = CaptureController.shared.isGlobalCaptureEnabled
    @State private var searchGlobal = SettingsWindowController.globalSearch?.isEnabled ?? false
    @State private var searchTaken = false

    var body: some View {
        Form {
            Toggle("Leave a thought from any app with \(state.captureGlobalKeys)", isOn: $captureGlobal)
            Toggle("Search from any app with ⌃⌥F", isOn: $searchGlobal)
            if searchTaken { footnote("⌃⌥F is already used by macOS or another app.") }

            Divider().padding(.vertical, Theme.Space.s)

            Toggle("Record the trail of files you open", isOn: $state.trailEnabled)
        }
        .formStyle(.columns)
        .onChange(of: captureGlobal) {
            guard state.captureGlobal != captureGlobal else { return }
            state.captureGlobal = captureGlobal
        }
        .onChange(of: searchGlobal) {
            guard let shortcut = SettingsWindowController.globalSearch, shortcut.isEnabled != searchGlobal else { return }
            searchTaken = !shortcut.toggle()
            searchGlobal = shortcut.isEnabled
        }
    }
}

extension SettingsWindowController {
    /// ⌃⌥F lives on the app delegate, which registers it at launch.
    static var globalSearch: GlobalSearchShortcut? { (NSApp.delegate as? AppDelegate)?.globalSearchShortcut }
}

// MARK: Index

/// The vault's `.flamingo/ignore`, editable in place. Saving rescans, so what is now excluded
/// drops out of the index and what is let back in gets read.
private struct IndexSettings: View {
    @EnvironmentObject var state: AppState
    @State private var text = ""
    @State private var saved = ""
    @State private var error: String?

    var body: some View {
        Form {
            if let vault = state.vault {
                LabeledContent("Skip:") {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        TextEditor(text: $text)
                            .font(Theme.Font.mono)
                            .scrollContentBackground(.hidden)
                            .padding(Theme.Space.xs)
                            .frame(height: 260)
                            .background(Squircle(radius: Theme.Radius.m).fill(Theme.Color.fill))
                        HStack(spacing: Theme.Space.s) {
                            Button("Save") { save(vault) }.disabled(text == saved)
                            Button("Revert") { text = saved }.disabled(text == saved)
                        }
                        if let error { footnote(error) }
                        footnote("gitignore patterns, one per line. Saving rescans the vault.")
                    }
                }

                Divider().padding(.vertical, Theme.Space.s)

                LabeledContent("Vault:") {
                    HStack(spacing: Theme.Space.s) {
                        Button("Workspace Health…") {
                            state.hostWindow?.makeKeyAndOrderFront(nil)
                            state.isHealthPresented = true
                        }
                        Button("Reindex") { state.reindex(force: true) }.disabled(state.indexStatus != nil)
                        Button("Full Disk Access…") { state.openFullDiskAccessSettings() }
                    }
                }
            } else {
                footnote("No vault open")
            }
        }
        .formStyle(.columns)
        .onAppear(perform: load)
        .onChange(of: state.vault?.root) { load() }
    }

    private func load() {
        guard let vault = state.vault else { return }
        saved = (try? String(contentsOf: vault.ignoreURL, encoding: .utf8)) ?? IgnoreRules.defaultText
        text = saved
        error = nil
    }

    private func save(_ vault: Vault) {
        do {
            try FileManager.default.createDirectory(at: vault.ignoreURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: vault.ignoreURL, options: .atomic)
            saved = text; error = nil
            state.reindex()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
