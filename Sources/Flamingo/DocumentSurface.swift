import SwiftUI
import FlamingoCore
import FlamingoExtract
import FlamingoDesign

struct DocumentSurface: View {
    @EnvironmentObject var state: AppState
    let file: FileRef
    let url: URL
    @ObservedObject var pane: DocumentPane
    /// The pointer is somewhere in this pane (brightens •••).
    var paneHovering = false
    static let textExtensions = TextExtractor.extensions.subtracting(["rtf", "rtfd", "ipynb"])
    private var editable: Bool { Self.textExtensions.contains(file.ext) }
    private var sourceIsRequired: Bool {
        guard let anchor = pane.jumpRequest?.anchor, pane.jumpRequest?.file == file else { return false }
        return ![FileAnchor.Kind.page, .time].contains(anchor.kind) || file.ext != "pdf" && !MediaKind.isMedia(file.ext)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.xs) {
                Breadcrumb(file: file) { folder in pane.activate(); state.revealFolder(folder) }
                Spacer(minLength: Theme.Space.s)
                if !editable, file.ext != "pdf", !MediaKind.isMedia(file.ext) {
                    IconButton("text.alignleft", help: pane.readSource ? "Show Preview" : "Show Extracted Text", isOn: pane.readSource) {
                        pane.readSource.toggle()
                    }
                    .onChange(of: pane.readSource) { if !pane.readSource { clearSourceJump() } }
                }
                IconButton("arrow.up.forward.app", help: "Open in " + (state.defaultAppName(for: file) ?? "Default App")) {
                    pane.activate(); state.openExternally(file)
                }
            }
            .padding(.leading, Theme.Space.m).padding(.trailing, Theme.Space.s)
            .frame(height: 30)
            .overlay(alignment: .center) {
                // Tiled panes carry ••• in their own header.
                if !state.splitVisible { TileHandle(paneID: pane.id, paneHovering: paneHovering) }
            }
            Hairline()
            if editable, pane.jumpRequest?.file != file || pane.jumpRequest?.anchor.kind == .line || pane.jumpRequest == nil,
               let buffer = state.textBuffer(for: file) {
                TextDocumentEditor(buffer: buffer, pane: pane).id(url)
            } else if sourceIsRequired {
                ExactSourceReader(file: file, url: url, pane: pane).id(url)
            } else if file.ext == "pdf" {
                PDFPreview(pane: pane, file: file, url: url, modified: PreviewKind.modificationDate(of: url), jump: pane.jumpRequest)
            } else if MediaKind.isMedia(file.ext) {
                MediaPreview(pane: pane, file: file, url: url, modified: PreviewKind.modificationDate(of: url), jump: pane.jumpRequest)
            } else if pane.readSource || sourceIsRequired {
                ExactSourceReader(file: file, url: url, pane: pane).id(url)
            } else {
                QuickLookPreview(url: url, modified: PreviewKind.modificationDate(of: url))
            }
        }
        .background(PaneActivationView(pane: pane, fallbackFocus: !editable && file.ext != "pdf" && !MediaKind.isMedia(file.ext) && !pane.readSource && !sourceIsRequired))
        .onChange(of: pane.jumpRequest) { if sourceIsRequired { pane.readSource = true } }
        .onChange(of: file) { pane.readSource = sourceIsRequired }
        .onAppear { if sourceIsRequired { pane.readSource = true } }
    }
    private func clearSourceJump() {
        if state.activePaneID == pane.id { state.clearSourceJump() }
        else { pane.jumpRequest = nil; pane.anchor = nil; pane.sourceHighlight = "" }
    }
}

/// The file's folders as quiet links, `research / interviews`; the vault's name at its root.
private struct Breadcrumb: View {
    @EnvironmentObject var state: AppState
    let file: FileRef
    let open: (String) -> Void

    var body: some View {
        let parts = file.directory.split(separator: "/").map(String.init)
        HStack(spacing: Theme.Space.xs) {
            if parts.isEmpty {
                crumb(state.vault?.name ?? "", path: "")
            }
            ForEach(Array(parts.enumerated()), id: \.offset) { i, name in
                if i > 0 { Text("/").foregroundStyle(Theme.Color.textTertiary) }
                crumb(name, path: parts[...i].joined(separator: "/"))
            }
        }
        .font(Theme.Font.small)
        .lineLimit(1)
        .truncationMode(.head)
    }

    private func crumb(_ name: String, path: String) -> some View {
        Button { open(path) } label: { Text(name).foregroundStyle(Theme.Color.textTertiary) }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Show " + (path.isEmpty ? name : path))
    }
}

struct ExactSourceReader: View {
    @EnvironmentObject var state: AppState
    let file: FileRef
    let url: URL
    @ObservedObject var pane: DocumentPane
    @State private var sections: [FlamingoExtract.Section] = []
    @State private var selectedIndex = 0
    @State private var loading = false
    @State private var failure: String?
    @State private var missing: String?
    @State private var cell: FlamingoExtract.Section?
    @State private var locationGeneration = UUID()
    private var selected: FlamingoExtract.Section? { cell ?? (sections.indices.contains(selectedIndex) ? sections[selectedIndex] : nil) }

    var body: some View {
        VStack(spacing: 0) {
            if let selected {
                HStack(spacing: Theme.Space.xs) {
                    Menu {
                        ForEach(sections.indices, id: \.self) { i in
                            Button(Self.title(of: sections[i])) {
                                locationGeneration = UUID(); cell = nil; selectedIndex = i; publishLocation()
                            }
                        }
                    } label: {
                        Text(Self.title(of: selected))
                            .font(Theme.Font.small)
                            .foregroundStyle(Theme.Color.textSecondary)
                            .lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.visible)
                    .tint(Theme.Color.textSecondary)
                    .fixedSize()
                    .help("Go to a section")
                    Spacer(minLength: Theme.Space.s)
                    IconButton("chevron.left", help: "Previous") { step(-1) }.disabled(selectedIndex == 0)
                    Text("\(selectedIndex + 1) / \(sections.count)")
                        .font(Theme.Font.monoSmall)
                        .foregroundStyle(Theme.Color.textTertiary)
                        .monospacedDigit()
                    IconButton("chevron.right", help: "Next") { step(1) }.disabled(selectedIndex + 1 >= sections.count)
                }
                .padding(.leading, Theme.Space.m).padding(.trailing, Theme.Space.s)
                .frame(height: 30)
                if let cell { Text(cell.anchor.displayLabel).font(Theme.Font.mono).foregroundStyle(Theme.Color.accent).padding(.horizontal, Theme.Space.m).padding(.bottom, Theme.Space.s) }
                if let missing { Text(missing).font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary).padding(.horizontal, Theme.Space.m).padding(.bottom, Theme.Space.s) }
                Hairline()
                SourceTextView(text: selected.text, file: file, query: pane.sourceHighlight, onActivate: { pane.activate() }, onAttach: { view in
                    pane.requestFocus = { [weak view] in if let view { view.window?.makeFirstResponder(view) } }
                })
                    .id(selected.anchor)
            } else if loading {
                ProgressHairline(value: nil).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                VStack(spacing: Theme.Space.m) {
                    Text(failure ?? "No text").font(Theme.Font.body).foregroundStyle(Theme.Color.textTertiary)
                        .multilineTextAlignment(.center)
                    Button("Open in " + (state.defaultAppName(for: file) ?? "Default App")) { state.openExternally(file) }
                        .buttonStyle(.plain).foregroundStyle(Theme.Color.accent).font(Theme.Font.body)
                }.padding(Theme.Space.xl).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url.path + "|" + String(PreviewKind.modificationDate(of: url)?.timeIntervalSince1970 ?? 0)) {
            loading = true; failure = nil; sections = []; cell = nil; selectedIndex = 0; missing = nil
            locationGeneration = UUID()
            do {
                let result = try await Extract.extractInBackground(url)
                guard !Task.isCancelled else { return }
                sections = result.sections
                if sections.isEmpty, !result.text.isEmpty { sections = [.init(anchor: .init(kind: .line, value: "1"), text: result.text)] }
                applyJump(restoring: true)
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
            loading = false
        }
        .onChange(of: pane.jumpRequest) { applyJump() }
    }

    /// `slide 3 · Pricing`, `Arc Pricing` for a heading, `sheet Q3`.
    static func title(of section: FlamingoExtract.Section) -> String {
        let label = section.anchor.displayLabel
        guard let t = section.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t != label else { return label }
        return label + " · " + t
    }

    private func step(_ delta: Int) { locationGeneration = UUID(); cell = nil; selectedIndex = min(max(0, selectedIndex + delta), max(0, sections.count - 1)); publishLocation() }
    private func publishLocation() { if let selected { pane.anchor = selected.anchor } }
    private func applyJump(restoring: Bool = false) {
        locationGeneration = UUID()
        let generation = locationGeneration
        missing = nil
        cell = nil
        let requested = pane.jumpRequest.flatMap { $0.file == file ? $0 : nil }
        let requestedAnchor = restoring ? (pane.anchor ?? requested?.anchor) : requested?.anchor
        let requestID = requested?.id
        guard let requestedAnchor else {
            selectedIndex = min(selectedIndex, max(0, sections.count - 1)); publishLocation(); return
        }
        if let index = sections.firstIndex(where: { $0.anchor == requestedAnchor }) {
            selectedIndex = index; publishLocation()
        } else if requestedAnchor.kind == .cell,
                  let index = sections.firstIndex(where: { $0.anchor.kind == .sheet && requestedAnchor.value.hasPrefix($0.anchor.value + "!") }) {
            selectedIndex = index
            let target = requestedAnchor
            Task {
                do {
                    let resolved = try await Task.detached(priority: .userInitiated) { try XLSXExtractor().cell(target, in: url) }.value
                    guard locationGeneration == generation, pane.jumpRequest?.id == requestID, sections.indices.contains(index) else { return }
                    if let resolved { cell = resolved; pane.anchor = resolved.anchor }
                    else { missing = "Cell \(target.value) could not be resolved. Showing sheet \(sections[index].anchor.value)."; publishLocation() }
                } catch {
                    guard locationGeneration == generation, pane.jumpRequest?.id == requestID else { return }
                    missing = error.localizedDescription; publishLocation()
                }
            }
        } else if !sections.isEmpty {
            selectedIndex = 0
            missing = "The location ‘\(requestedAnchor.label)’ is no longer in this file. Showing \(sections[0].anchor.label)."
            publishLocation()
        }
    }
}
