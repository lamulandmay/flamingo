import SwiftUI
import FlamingoCore
import FlamingoDesign

struct CaptureInboxItem: Identifiable, Sendable {
    var source: FileRef
    var comment: Comment
    var id: String { source.relativePath + ":" + comment.id.uuidString }
}

enum CaptureInboxStore {
    /// Reads only capture's inbox folder, never the entire file catalog.
    static func load(vault: Vault) throws -> [CaptureInboxItem] {
        let folder = vault.notesDir.appendingPathComponent("_inbox", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let store = SidecarStore(vault: vault)
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "md" }
        return try urls.flatMap { url -> [CaptureInboxItem] in
            guard let source = store.target(ofSidecar: url) else { return [] }
            return try store.comments(for: source).map { CaptureInboxItem(source: source, comment: $0) }
        }.sorted { $0.comment.timestamp > $1.comment.timestamp }
    }
}

@MainActor
final class CaptureInboxModel: ObservableObject {
    @Published var items: [CaptureInboxItem] = []
    @Published var selected: String?
    @Published var matches: [FileRef] = []
    @Published var target: FileRef?
    @Published var query = "" { didSet { match() } }
    @Published var error: String?
    @Published var loading = false
    @Published var attaching = false
    let vault: Vault
    let files: [FileRef]
    private var matcher: LinkMatcher?
    private var matching: Task<Void, Never>?

    init(vault: Vault, files: [FileRef]) { self.vault = vault; self.files = files }
    var item: CaptureInboxItem? { items.first { $0.id == selected } }

    func load() async {
        loading = true
        do {
            let vault = vault, files = files
            let loaded = try await Task.detached { try CaptureInboxStore.load(vault: vault) }.value
            let prepared = await Task.detached { LinkMatcher(candidates: files) }.value
            guard !Task.isCancelled else { return }
            items = loaded; matcher = prepared
            if !loaded.contains(where: { $0.id == selected }) { selected = loaded.first?.id }
            error = nil; match()
        } catch { self.error = "Inbox could not be read: " + error.localizedDescription }
        loading = false
    }

    private func match() {
        matching?.cancel()
        guard let matcher else { return }
        let query = query
        matching = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let matches = await Task.detached { matcher.matches(query, limit: 12).map(\.ref) }.value
            guard !Task.isCancelled else { return }
            self.matches = matches
        }
    }

    func attach(using save: @escaping (Comment, FileRef, FileRef) async throws -> Void) async {
        guard let item, let target, !attaching else { return }
        attaching = true; error = nil
        do {
            try await save(item.comment, item.source, target)
            items.removeAll { $0.id == item.id }
            selected = items.first?.id
        } catch { self.error = "Thought remains in Inbox: " + error.localizedDescription }
        attaching = false
    }
}

/// Reviews capture thoughts whose original document could not be matched to an open vault.
/// The shell acknowledges an attach only after the target write and inbox removal succeed.
public struct CaptureInboxView: View {
    @StateObject private var model: CaptureInboxModel
    private let onOpen: (FileRef, FileAnchor?) -> Void
    private let onAttach: (Comment, FileRef, FileRef) async throws -> Void

    public init(vault: Vault, files: [FileRef], onOpen: @escaping (FileRef, FileAnchor?) -> Void,
                onAttach: @escaping (Comment, FileRef, FileRef) async throws -> Void) {
        _model = StateObject(wrappedValue: CaptureInboxModel(vault: vault, files: files))
        self.onOpen = onOpen; self.onAttach = onAttach
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if model.loading { ProgressHairline(value: nil) }
            if let error = model.error { Text(error).font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary).textSelection(.enabled) }
            if model.items.isEmpty && !model.loading {
                EmptyState("Inbox empty")
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.items) { item in
                                Button { model.selected = item.id } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.comment.text).font(Theme.Font.body).foregroundStyle(Theme.Color.text)
                                            .lineLimit(2).multilineTextAlignment(.leading)
                                        Text(item.comment.provenance?.appName ?? item.source.name)
                                            .font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, Theme.Space.s).padding(.horizontal, Theme.Space.s)
                                    .background(Squircle(radius: Theme.Radius.s)
                                        .fill(model.selected == item.id ? Theme.Color.selection : .clear))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.press)
                            }
                        }
                    }
                    .frame(width: 260)
                    .disabled(model.attaching)
                    VHairline().padding(.horizontal, Theme.Space.m)
                    if let item = model.item {
                        ScrollView {
                            VStack(alignment: .leading, spacing: Theme.Space.m) {
                                Text(item.comment.text).font(Theme.Font.body).textSelection(.enabled)
                                HStack(spacing: Theme.Space.s) {
                                    Text(RailText.timestamp(item.comment.timestamp))
                                    if let p = item.comment.provenance {
                                        Text([p.appName, p.windowTitle].compactMap { $0 }.joined(separator: " · ")).lineLimit(1)
                                        if let source = p.sourceURL, let url = URL(string: source) {
                                            Link(destination: url) { Image(systemName: "arrow.up.forward.square") }.help(source)
                                        }
                                    }
                                }
                                .font(Theme.Font.monoSmall).foregroundStyle(Theme.Color.textTertiary)
                                Hairline()
                                SearchField(text: $model.query)
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(model.matches, id: \.self) { file in
                                        Button { model.target = file } label: {
                                            HStack(spacing: Theme.Space.s) {
                                                FileGlyph(ext: file.ext, selected: model.target == file)
                                                Text(file.name).font(Theme.Font.body).foregroundStyle(Theme.Color.text).lineLimit(1)
                                                Spacer(minLength: Theme.Space.s)
                                                Text(file.directory).font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary)
                                                    .lineLimit(1).truncationMode(.head)
                                            }
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.press)
                                        .flamingoRow(selected: model.target == file)
                                        .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen(file, nil) })
                                    }
                                }
                                if let target = model.target {
                                    Button { Task { await model.attach(using: onAttach) } } label: {
                                        Text("Attach to " + target.name).lineLimit(1)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .keyboardShortcut(.defaultAction)
                                    .disabled(model.attaching)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, Theme.Space.s)
                        }.disabled(model.attaching)
                    }
                }
            }
        }
        .padding(Theme.Space.l)
        .frame(minWidth: 720, minHeight: 460)
        .task { await model.load() }
    }
}
