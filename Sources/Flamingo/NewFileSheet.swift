import AppKit
import SwiftUI
import FlamingoCore
import FlamingoDesign

/// ⌘N: what kind of file, then its name. Type a kind ("3d", "ppt", "excel", "py") and pick
/// from what it names: ↑↓ or Tab move, Return or a click picks. Text opens in Flamingo,
/// the rest in its own app; kinds only an app can start (a Shapr3D design) open that app.
/// `plan.pptx` typed straight in names and picks in one go. The file is made in the folder
/// on screen when ⌘N was pressed.
struct NewFileSheet: View {
    @Environment(AppState.self) var state
    @State private var query = ""
    @State private var name = ""
    @State private var highlight = 0
    @State private var chosen: DocumentFactory.Format?
    /// Plan 18: the Project kind was picked; the field takes its folder's name.
    @State private var projectChosen = false
    @State private var error: String?
    /// Each kind's app, looked up once per sheet: the row says where it opens, and kinds
    /// whose app isn't on this Mac are left out.
    @State private var apps: [String: URL] = [:]

    private enum Kind: Identifiable, Equatable {
        case file(DocumentFactory.Format)
        case folder
        /// A folder with the project structure (plan 18) and a git repo.
        case project
        var id: String {
            switch self {
            case .file(let f): f.ext
            case .folder: "/folder"
            case .project: "/project"
            }
        }
    }

    private var naming: Bool { chosen != nil || projectChosen }

    /// `plan.pptx`: a name and a kind in one.
    private var typed: (stem: String, format: DocumentFactory.Format)? {
        let ext = (query as NSString).pathExtension, stem = (query as NSString).deletingPathExtension
        guard !ext.isEmpty, !stem.trimmingCharacters(in: .whitespaces).isEmpty,
              let format = DocumentFactory.resolve(ext) ?? DocumentFactory.blank(ext: ext), available(format) else { return nil }
        return (stem, format)
    }

    private var kinds: [Kind] {
        if let typed { return [.file(typed.format)] }
        var found = DocumentFactory.search(query).filter(available).map(Kind.file)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty || ["folder", "directory"].contains(where: { $0.hasPrefix(q) }) { found.append(.folder) }
        if q.isEmpty || ["project", "repo", "repository", "code", "git"].contains(where: { $0.hasPrefix(q) }) { found.append(.project) }
        return found
    }

    private func available(_ format: DocumentFactory.Format) -> Bool {
        if case .text = format.source { return true }
        return apps[format.ext] != nil
    }

    private var place: String {
        guard let v = state.vault, let url = state.newFileDirectory else { return "" }
        if url.standardizedFileURL.path == v.root.standardizedFileURL.path { return v.name }
        return v.relativePath(of: url) ?? (url.path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        let kinds = self.kinds
        VStack(alignment: .leading, spacing: 0) {
            Text(place)
                .font(Theme.Font.small)
                .foregroundStyle(Theme.Color.textTertiary)
                .lineLimit(1).truncationMode(.head)
                .padding(.horizontal, Theme.Space.l)
                .padding(.top, Theme.Space.l)
            // One field for both steps, so the keyboard stays in it: first the kind, then
            // the name. Backspace in an empty name, or a click on the glyph, goes back.
            HStack(spacing: Theme.Space.s) {
                if let chosen {
                    Button { back() } label: { FileGlyph(ext: chosen.ext, size: 18) }
                        .buttonStyle(.press).focusable(false).help(chosen.title)
                } else if projectChosen {
                    Button { back() } label: { glyph(.project, size: 18) }
                        .buttonStyle(.press).focusable(false).help("Project")
                } else {
                    glyph(kinds.indices.contains(highlight) ? kinds[highlight] : nil, size: 18)
                }
                CommandField(text: naming ? $name : $query, placeholder: naming ? "Untitled" : "",
                             label: naming ? "Name" : "Kind of file") { command($0, kinds: kinds) }
                if let chosen {
                    Text("." + chosen.ext)
                        .font(Theme.Font.mono)
                        .foregroundStyle(Theme.Color.textTertiary)
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
            if !naming, !kinds.isEmpty {
                Hairline()
                list(kinds)
            }
            if let error {
                Hairline()
                Text(error)
                    .font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary)
                    .textSelection(.enabled)
                    .padding(Theme.Space.l)
            }
        }
        .frame(width: 460, alignment: .topLeading)
        .background(Theme.Color.bg)
        .onExitCommand { state.isNewFilePresented = false }
        .onChange(of: query) { highlight = 0; error = nil }
        .onChange(of: name) { error = nil }
        .onAppear { apps = Self.lookUpApps() }
    }

    private func list(_ kinds: [Kind]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(kinds.enumerated()), id: \.element.id) { index, kind in
                        row(kind)
                            .flamingoRow(selected: index == highlight)
                            .contentShape(Rectangle())
                            .onTapGesture { highlight = index; pick(kinds) }
                            .id(kind.id)
                    }
                }
                .padding(Theme.Space.xs)
            }
            .frame(height: min(CGFloat(kinds.count), 8.5) * 28 + Theme.Space.s)
            .onChange(of: highlight) { _, i in
                if kinds.indices.contains(i) { proxy.scrollTo(kinds[i].id) }
            }
        }
    }

    private func row(_ kind: Kind) -> some View {
        HStack(spacing: Theme.Space.s) {
            glyph(kind, size: Theme.Size.iconSmall).frame(width: 16)
            switch kind {
            case .file(let format):
                Text(format.title).lineLimit(1)
                Text("." + format.ext).font(Theme.Font.monoSmall).foregroundStyle(Theme.Color.textTertiary)
                Spacer(minLength: Theme.Space.s)
                if !format.isText, let app = apps[format.ext] {
                    Text(Self.appName(app))
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.Color.textTertiary)
                        .lineLimit(1)
                }
            case .folder:
                Text("Folder")
                Spacer(minLength: Theme.Space.s)
            case .project:
                Text("Project")
                Spacer(minLength: Theme.Space.s)
                Text("AGENTS.md, plans, docs, git")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(height: 28)
    }

    @ViewBuilder private func glyph(_ kind: Kind?, size: CGFloat) -> some View {
        switch kind {
        case .file(let format): FileGlyph(ext: format.ext, size: size)
        case .folder:
            Image(systemName: "folder").font(.system(size: size))
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: (size * 1.35).rounded())
        case .project:
            Image(systemName: "folder.badge.gearshape").font(.system(size: size))
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: (size * 1.35).rounded())
        case nil:
            Image(systemName: "doc").font(.system(size: size))
                .foregroundStyle(Theme.Color.textTertiary)
                .frame(width: (size * 1.35).rounded())
        }
    }

    /// The field's editing commands: ↑↓ and Tab move through the kinds, Return picks or
    /// creates, Esc closes, Backspace in an empty name goes back to the kinds.
    private func command(_ selector: Selector, kinds: [Kind]) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)): return step(1, in: kinds)
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)): return step(-1, in: kinds)
        case #selector(NSResponder.insertNewline(_:)):
            if naming { create() } else { pick(kinds) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            state.isNewFilePresented = false
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            guard naming, name.isEmpty else { return false }
            back()
            return true
        default:
            return false
        }
    }

    private func step(_ by: Int, in kinds: [Kind]) -> Bool {
        guard !naming else { return false }
        if !kinds.isEmpty { highlight = (highlight + by + kinds.count) % kinds.count }
        return true
    }

    private func pick(_ kinds: [Kind]) {
        if let typed {
            make(typed.format, named: typed.stem)
            return
        }
        guard kinds.indices.contains(highlight) else { NSSound.beep(); return }
        switch kinds[highlight] {
        case .folder:
            guard let v = state.vault, let url = state.newFileDirectory else { return }
            let root = v.root.standardizedFileURL.path
            guard let folder = url.standardizedFileURL.path == root ? "" : v.relativePath(of: url) else { NSSound.beep(); return }
            state.isNewFilePresented = false
            state.newFolder(in: folder)
        case .project:
            projectChosen = true
            name = ""
        case .file(let format) where !format.isFile:
            make(format, named: "")
        case .file(let format):
            chosen = format
            name = ""
        }
    }

    private func back() {
        chosen = nil
        projectChosen = false
        error = nil
    }

    private func create() {
        if projectChosen {
            guard let directory = state.newFileDirectory else { return }
            do { try state.agentProjects.createProject(named: name, in: directory) }
            catch { self.error = error.localizedDescription }
            return
        }
        guard let chosen else { return }
        make(chosen, named: name)
    }

    private func make(_ format: DocumentFactory.Format, named name: String) {
        guard let directory = state.newFileDirectory else { return }
        do { try state.createDocument(format, name: name, in: directory) }
        catch { self.error = error.localizedDescription }
    }

    private static func lookUpApps() -> [String: URL] {
        var apps: [String: URL] = [:]
        for format in DocumentFactory.formats where !format.isText {
            if let url = AppState.application(for: format) { apps[format.ext] = url }
        }
        return apps
    }

    private static func appName(_ url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

/// A one-line field whose keys arrive as editing commands (↑↓, Tab, Return, Esc, Backspace)
/// however they were delivered. AppKit, like the palette's. The New File sheet and connect
/// mode use it.
struct CommandField: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    let label: String
    var fontSize: CGFloat = 17
    /// Takes focus when it appears. A pane launcher turns this off: several can exist at once.
    var autofocus = true
    /// Hands over the field once made, so a host can focus it later.
    var onCreate: ((NSTextField) -> Void)? = nil
    let onCommand: (Selector) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(frame: .zero)
        field.delegate = context.coordinator
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = Theme.NS.text
        field.lineBreakMode = .byClipping
        if let cell = field.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.wraps = false
            cell.isScrollable = true
        }
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if autofocus { DispatchQueue.main.async { field.window?.makeFirstResponder(field) } }
        onCreate?(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { field.stringValue = text }
        if field.placeholderAttributedString?.string != placeholder {
            field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: Theme.NS.textTertiary])
        }
        field.setAccessibilityLabel(label)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? field.intrinsicContentSize.width, height: field.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandField
        init(_ parent: CommandField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            parent.onCommand(selector)
        }
    }
}
