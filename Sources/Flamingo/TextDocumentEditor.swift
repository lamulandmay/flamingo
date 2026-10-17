import AppKit
import SwiftUI
import FlamingoCore
import FlamingoDesign
import CryptoKit

@MainActor
final class TextBuffer: ObservableObject {
    struct Draft: Codable, Sendable { let path: String; let text: String; let baseline: Data }
    let file: FileRef
    let url: URL
    let draftURL: URL
    @Published var text = ""
    @Published var error: String?
    @Published var dirty = false
    @Published var saving = false
    @Published var loaded = false
    @Published var recovered = false
    @Published var focusRequested = false
    @Published private(set) var draftBackedUp = false
    private var baseline = Data()
    private var editGeneration = 0
    private var pendingDraftGeneration: UInt64 = 0
    private var draftWritable = true
    private var relocating = false
    private var successor: TextBuffer?
    let draftWriter: DraftWriter
    weak var actionHistory: ActionHistory?
    var onSaved: (() -> Void)?

    init(file: FileRef, vault: Vault, draftDirectory: URL? = nil) {
        self.file = file; url = vault.url(for: file)
        let name = SHA256.hash(data: Data(url.path.utf8)).map { String(format: "%02x", $0) }.joined()
        // Independent of the source's volume: a disconnected/read-only vault still has a recoverable draft.
        let drafts = draftDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Flamingo/Drafts", isDirectory: true)
        draftURL = drafts.appendingPathComponent(name + ".json")
        draftWriter = DraftWriter.shared(for: draftURL)
    }

    func load() async {
        guard !loaded else { return }
        let source = url
        let result = await Task.detached(priority: .userInitiated) { Result { try SafeTextFile.read(source) } }.value
        // The same per-path queue is used by a previous buffer, so reopening cannot race its final write.
        let recovery = await draftWriter.read(expectedPath: source.path)
        guard !loaded else { return }
        draftWritable = recovery.writable
        switch result {
        case .success(let disk):
            baseline = disk.data; text = disk.text; loaded = true
            if let draft = recovery.draft, Data(draft.text.utf8) != disk.data {
                text = draft.text; baseline = draft.baseline; dirty = true; recovered = true; draftBackedUp = true
                if draft.baseline != disk.data { error = DocumentError.changedOnDisk.localizedDescription }
            } else if recovery.draft != nil {
                // A previously committed draft is redundant; remove it in the same ordered stream.
                enqueueDraft()
            }
            if let warning = recovery.warning, error == nil { error = warning }
        case .failure(let failure):
            if let draft = recovery.draft {
                text = draft.text; baseline = draft.baseline; loaded = true; dirty = true; recovered = true; draftBackedUp = true
            }
            error = failure.localizedDescription + (recovery.warning.map { " · " + $0 } ?? "")
        }
    }

    func changed(_ text: String) {
        if let successor { successor.changed(text); return }
        self.text = text
        editGeneration += 1
        // The byte comparison and JSON encoding are both deferred; typing never serializes a large document.
        dirty = true; draftBackedUp = false
        enqueueDraft()
    }

    private func enqueueDraft() {
        guard loaded else { return }
        guard draftWritable else {
            if dirty { error = "Couldn’t back up your draft: the recovery file is unavailable. Save a copy before closing." }
            return
        }
        let draft = Draft(path: url.path, text: text, baseline: baseline)
        pendingDraftGeneration = draftWriter.enqueue(draft) { [weak self] outcome in
            Task { @MainActor in self?.apply(outcome) }
        }
    }

    private func apply(_ outcome: DraftWriter.Outcome) {
        guard outcome.generation == pendingDraftGeneration else { return }
        dirty = outcome.dirty
        draftBackedUp = outcome.dirty && outcome.failure == nil
        if let failure = outcome.failure { error = "Couldn’t back up your draft: " + failure }
        else if error?.hasPrefix("Couldn’t back up your draft:") == true { error = nil }
    }

    /// Close/switch hooks need a real durability boundary, not an unowned background task.
    /// Encoding and disk I/O still run on the writer queue; only this explicit boundary waits.
    @discardableResult
    func persistDraft() -> Bool {
        if let successor { return successor.persistDraft() }
        guard loaded else { return true }
        guard draftWritable else { return !dirty }
        enqueueDraft()
        let outcome = draftWriter.flush()
        apply(outcome)
        return outcome.failure == nil
    }

    @discardableResult
    func flushDraft() async -> Bool {
        if let successor { return await successor.flushDraft() }
        guard loaded else { return true }
        guard draftWritable else { return !dirty }
        enqueueDraft()
        let outcome = await draftWriter.flushAsync()
        apply(outcome)
        return outcome.failure == nil
    }

    func save() async {
        if let successor { await successor.save(); return }
        guard loaded, dirty, !saving, !relocating else { return }
        saving = true
        let historyContext = actionHistory?.contextID
        let content = text, expected = baseline, destination = url, generation = editGeneration
        defer { saving = false }
        let backedUp = await flushDraft()
        do {
            let savedIdentity = try FileIdentity.id(for: destination)
            let data = try await Task.detached(priority: .userInitiated) {
                try SafeTextFile.save(content, to: destination, replacing: expected)
            }.value
            baseline = data; error = nil; recovered = false
            if actionHistory?.contextID == historyContext { actionHistory?.register(name: "Save " + file.name, undo: { [self] in
                try restoreSavedBytes(expected, replacing: data, identity: savedIdentity)
            }, redo: { [self] in
                try restoreSavedBytes(data, replacing: expected, identity: savedIdentity)
            }) }
            if editGeneration == generation { dirty = false; draftBackedUp = false }
            // A clean snapshot is an ordered removal. A newer edit is rewritten with the new baseline.
            // Either invalidates older queued generations before they can recreate a committed draft.
            await flushDraft()
            onSaved?()
        } catch {
            self.error = error.localizedDescription + (backedUp ? "" : " · Draft backup is unavailable; keep this window open or save a copy.")
        }
    }

    private func restoreSavedBytes(_ bytes: Data, replacing expected: Data, identity: UUID) throws {
        if let successor { try successor.restoreSavedBytes(bytes, replacing: expected, identity: identity); return }
        guard !saving, !relocating, try FileIdentity.existingID(for: url) == identity else { throw DocumentError.changedOnDisk }
        _ = try SafeTextFile.save(String(decoding: bytes, as: UTF8.self), to: url, replacing: expected)
        baseline = bytes
        dirty = Data(text.utf8) != bytes
        editGeneration += 1
        _ = persistDraft()
        onSaved?()
    }

    func reloadDisk() async {
        if let successor { await successor.reloadDisk(); return }
        guard !saving, !relocating else { return }
        let historyContext = actionHistory?.contextID
        saving = true
        defer { saving = false }
        let generation = editGeneration, source = url
        let snapshot = Draft(path: url.path, text: text, baseline: baseline)
        do {
            // Explicit reload preserves a separate recovery copy even after the active draft is removed.
            if dirty { try await draftWriter.archive(snapshot) }
            let disk = try await Task.detached(priority: .userInitiated) { try SafeTextFile.read(source) }.value
            guard editGeneration == generation else {
                error = "Editing continued while reloading. Your current draft is retained; reload again when ready."
                return
            }
            baseline = disk.data; text = disk.text; loaded = true; dirty = false; recovered = false; error = nil
            if actionHistory?.contextID == historyContext { actionHistory?.register(name: "Reload " + file.name, undo: { [self] in
                try restoreReloadedDraft(snapshot, expectingText: disk.text)
            }, redo: { [self] in
                try restoreReloadedDraft(Draft(path: url.path, text: disk.text, baseline: disk.data), expectingText: snapshot.text)
            }) }
            editGeneration += 1
            await flushDraft()
        } catch { self.error = "Couldn’t reload without preserving your draft: " + error.localizedDescription }
    }

    private func restoreReloadedDraft(_ draft: Draft, expectingText expected: String) throws {
        if let successor { try successor.restoreReloadedDraft(draft, expectingText: expected); return }
        guard !saving, !relocating, text == expected else { throw DocumentError.changedOnDisk }
        text = draft.text; baseline = draft.baseline
        dirty = Data(text.utf8) != baseline
        editGeneration += 1
        _ = persistDraft()
    }

    func saveCopy() {
        if let successor { successor.saveCopy(); return }
        let panel = NSSavePanel()
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " copy." + url.pathExtension
        panel.begin { [weak self] response in
            guard response == .OK, let self, let destination = panel.url else { return }
            let content = self.text
            Task {
                do {
                    try await Task.detached { try Data(content.utf8).write(to: destination, options: .withoutOverwriting) }.value
                    self.error = "Copy saved. Your original draft is still here."
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    func diskChanged() async {
        if let successor { await successor.diskChanged(); return }
        guard loaded, !saving else { return }
        let generation = editGeneration, expected = baseline, source = url
        do {
            let latest = try await Task.detached(priority: .utility) { try SafeTextFile.read(source) }.value
            guard !saving, baseline == expected, latest.data != baseline else { return }
            if dirty || editGeneration != generation {
                error = DocumentError.changedOnDisk.localizedDescription
                enqueueDraft()
            } else {
                baseline = latest.data; text = latest.text; error = nil
                enqueueDraft()
            }
        } catch { self.error = error.localizedDescription }
    }

    /// Called only after file identity confirms a rename. A new recovery path is durable
    /// before the old one is retired; late UI callbacks are forwarded to the new buffer.
    func relocated(to file: FileRef, vault: Vault) async throws -> TextBuffer {
        if let successor { return try await successor.relocated(to: file, vault: vault) }
        if vault.url(for: file) == url { return self }
        while saving || relocating { try await Task.sleep(for: .milliseconds(10)) }
        if let successor { return try await successor.relocated(to: file, vault: vault) }
        try Task.checkCancellation()
        relocating = true
        defer { relocating = false }
        if !loaded { await load() }
        let next = TextBuffer(file: file, vault: vault, draftDirectory: draftURL.deletingLastPathComponent())
        next.actionHistory = actionHistory
        if !loaded {
            await next.load()
            guard next.loaded else { throw RelocationError(message: next.error ?? "The renamed file could not be opened") }
        } else {
            // The destination may have recovery from a previously deleted file with the same name.
            // Preserve that content before our first atomic replacement or clean-snapshot removal.
            try await next.draftWriter.archiveExisting()
            while true {
                try Task.checkCancellation()
                let generation = editGeneration
                guard await flushDraft() else { throw RelocationError(message: error ?? "The old draft could not be backed up") }
                guard editGeneration == generation else { continue }
                next.text = text; next.baseline = baseline; next.dirty = dirty
                next.error = error; next.recovered = recovered; next.loaded = loaded
                next.focusRequested = focusRequested
                guard await next.flushDraft() else { throw RelocationError(message: next.error ?? "The renamed draft could not be backed up") }
                guard editGeneration == generation else { continue }
                break
            }
        }
        successor = next
        pendingDraftGeneration = 0 // completions for the retired path cannot change editor state
        if draftWritable {
            _ = draftWriter.enqueue(Draft(path: url.path, text: "", baseline: Data())) { _ in }
            let cleanup = await draftWriter.flushAsync()
            if let failure = cleanup.failure, next.error == nil {
                next.error = "The renamed draft is backed up; the old recovery copy could not be removed: " + failure
            }
        }
        return next
    }

    private struct RelocationError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// One writer per recovery path, shared across buffer lifetimes. At most one snapshot is
    /// being encoded and one newer snapshot is pending, so fast typing cannot queue megabytes per key.
    final class DraftWriter: @unchecked Sendable {
        struct Outcome: Sendable {
            var generation: UInt64
            var dirty: Bool
            var failure: String?
        }
        struct Recovery: Sendable { var draft: Draft?; var warning: String?; var writable = true }
        private struct Request {
            var generation: UInt64
            var draft: Draft
            var completion: @Sendable (Outcome) -> Void
        }
        private static let registryLock = NSLock()
        private static var registry: [String: DraftWriter] = [:]
        static func shared(for url: URL) -> DraftWriter {
            registryLock.withLock {
                if let writer = registry[url.path] { return writer }
                let writer = DraftWriter(url: url)
                registry[url.path] = writer
                return writer
            }
        }
        let queue = DispatchQueue(label: "com.flamingo.editor-draft", qos: .userInitiated)
        private let url: URL
        private let lock = NSLock()
        private var generation: UInt64 = 0
        private var pending: Request?
        private var draining = false
        private var outcome = Outcome(generation: 0, dirty: false, failure: nil)
        private init(url: URL) { self.url = url }

        func enqueue(_ draft: Draft, completion: @escaping @Sendable (Outcome) -> Void) -> UInt64 {
            lock.withLock {
                generation &+= 1
                pending = Request(generation: generation, draft: draft, completion: completion)
                if !draining { draining = true; queue.async { self.drain() } }
                return generation
            }
        }

        private func drain() {
            while let request = lock.withLock({ () -> Request? in
                guard let request = pending else { draining = false; return nil }
                pending = nil; return request
            }) {
                let dirty = Data(request.draft.text.utf8) != request.draft.baseline
                var failure: String?
                do {
                    let data = dirty ? try JSONEncoder().encode(request.draft) : nil
                    // If another key arrived during encoding, skip this obsolete write entirely.
                    guard lock.withLock({ generation == request.generation }) else { continue }
                    if let data {
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try data.write(to: url, options: .atomic)
                    } else if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                } catch { failure = error.localizedDescription }
                let result = Outcome(generation: request.generation, dirty: dirty, failure: failure)
                let current = lock.withLock { () -> Bool in
                    guard generation == request.generation else { return false }
                    outcome = result; return true
                }
                if current { request.completion(result) }
            }
        }

        func flush() -> Outcome { queue.sync { lock.withLock { outcome } } }
        func flushAsync() async -> Outcome {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: self.lock.withLock { self.outcome }) }
            }
        }
        func read(expectedPath: String) async -> Recovery {
            await withCheckedContinuation { continuation in
                queue.async {
                    guard FileManager.default.fileExists(atPath: self.url.path) else {
                        continuation.resume(returning: Recovery()); return
                    }
                    do {
                        let draft = try JSONDecoder().decode(Draft.self, from: Data(contentsOf: self.url))
                        guard draft.path == expectedPath else { throw CocoaError(.fileReadCorruptFile) }
                        continuation.resume(returning: Recovery(draft: draft))
                    } catch {
                        // Never overwrite an unreadable recovery file with a new edit.
                        let backup = self.url.deletingPathExtension().appendingPathExtension("unreadable-\(UUID()).json")
                        do {
                            try FileManager.default.moveItem(at: self.url, to: backup)
                            continuation.resume(returning: Recovery(warning: "An unreadable draft was preserved at " + backup.path))
                        } catch {
                            continuation.resume(returning: Recovery(warning: "Draft recovery is unavailable: " + error.localizedDescription, writable: false))
                        }
                    }
                }
            }
        }
        func archive(_ draft: Draft) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do {
                        let backup = self.url.deletingPathExtension().appendingPathExtension("recovery-\(UUID()).json")
                        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try JSONEncoder().encode(draft).write(to: backup, options: .atomic)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        func archiveExisting() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do {
                        if FileManager.default.fileExists(atPath: self.url.path) {
                            let data = try Data(contentsOf: self.url)
                            let backup = self.url.deletingPathExtension().appendingPathExtension("recovery-\(UUID()).json")
                            try data.write(to: backup, options: .atomic)
                        }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
    }
}
struct TextDocumentEditor: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var buffer: TextBuffer
    @ObservedObject var pane: DocumentPane
    var body: some View {
        VStack(spacing: 0) {
            // Saved is the normal state and says nothing. Unsaved is a dot at the top right;
            // only a failed save takes a row, with its ways out.
            if let error = buffer.error {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(error).font(Theme.Font.small).foregroundStyle(Theme.Color.text).textSelection(.enabled)
                    HStack(spacing: Theme.Space.m) {
                        Button("Retry Save") { Task { await buffer.save() } }.disabled(!buffer.dirty)
                        Button("Save a Copy…") { buffer.saveCopy() }
                        Button("Reload From Disk") { Task { await buffer.reloadDisk() } }
                    }
                    .buttonStyle(.plain).font(Theme.Font.small).foregroundStyle(Theme.Color.accent)
                }
                .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Color.bgRaised)
                Hairline()
            }
            if buffer.loaded {
                SourceTextView(text: buffer.text, editable: true, jump: pane.jumpRequest, initialAnchor: pane.anchor, file: buffer.file,
                               query: pane.sourceHighlight, focusRequested: buffer.focusRequested && state.activePaneID == pane.id,
                               onFocused: { buffer.focusRequested = false }, onChange: buffer.changed,
                               onLine: { pane.anchor = FileAnchor(kind: .line, value: String($0)) },
                               onActivate: { pane.activate() }, onAttach: { view in
                                   pane.requestFocus = { [weak view] in if let view { view.window?.makeFirstResponder(view) } }
                               })
            } else if buffer.error == nil { ProgressHairline(value: nil).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) }
        }
        .overlay(alignment: .topTrailing) {
            if buffer.dirty || buffer.saving {
                Circle()
                    .fill(Theme.Color.accent)
                    .frame(width: 6, height: 6)
                    .opacity(buffer.saving ? 0.4 : 1)
                    .padding(Theme.Space.m)
                    .help(buffer.recovered ? "Recovered draft · ⌘S to save" : buffer.draftBackedUp ? "Unsaved · draft backed up · ⌘S to save" : "Unsaved · ⌘S to save")
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.fast, value: buffer.dirty)
        .task { await buffer.load() }
    }
}

/// Native selectable text with an actual line jump, used by the editor and exact source reader.
struct SourceTextView: NSViewRepresentable {
    let text: String
    var editable = false
    var jump: JumpRequest?
    var initialAnchor: FileAnchor?
    let file: FileRef
    var query: String = ""
    var focusRequested = false
    var onFocused: (() -> Void)?
    var onChange: ((String) -> Void)?
    var onLine: ((Int) -> Void)?
    var onActivate: (() -> Void)?
    var onAttach: ((NSTextView) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = PaneTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isRichText = false; view.isEditable = editable; view.isSelectable = true
        view.allowsUndo = true; view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false; view.isAutomaticTextReplacementEnabled = false
        view.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        view.textColor = Theme.NS.text; view.backgroundColor = Theme.NS.bg
        view.insertionPointColor = Theme.NS.accent; view.textContainerInset = NSSize(width: 24, height: 24)
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        (view as? PaneTextView)?.onActivate = onActivate
        onAttach?(view)
        view.setAccessibilityLabel(editable ? "Document editor" : "Exact source text")
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        (view as? PaneTextView)?.onActivate = onActivate
        onAttach?(view)
        let c = context.coordinator; c.onChange = onChange; c.onLine = onLine; c.updating = true
        defer { c.updating = false }
        if view.string != text {
            // A second pane shares the buffer, but keeps its own selection and viewport.
            let selection = view.selectedRange(), origin = scroll.contentView.bounds.origin
            view.string = text
            let length = (text as NSString).length
            let start = min(selection.location, length)
            view.setSelectedRange(NSRange(location: start, length: min(selection.length, length - start)))
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if !focusRequested { c.focusTask?.cancel(); c.focusTask = nil }
        if focusRequested, c.focusTask == nil {
            c.focusTask = Task { @MainActor [weak view] in
                defer { c.focusTask = nil }
                for _ in 0..<6 {
                    try? await Task.sleep(for: .milliseconds(75))
                    guard let view, !Task.isCancelled else { return }
                    if let window = view.window, window.isKeyWindow, window.attachedSheet == nil {
                        window.makeFirstResponder(view); onFocused?(); return
                    }
                }
            }
        }
        let token = "\(jump?.id.uuidString ?? "")|\(query)|\(file.relativePath)"
        guard token != c.token else { return }
        let firstPresentation = c.token.isEmpty
        c.token = token
        let requestedAnchor = firstPresentation ? (initialAnchor ?? jump?.anchor) : jump?.anchor
        let line = requestedAnchor.flatMap { $0.kind == .line && (jump == nil || jump?.file == file) ? Int($0.value) : nil }
        if let target = Self.highlightRange(in: text, line: line, query: query) {
            view.setSelectedRange(target); view.scrollRangeToVisible(target); view.showFindIndicator(for: target)
        }
    }

    /// A query may refine the requested line, but must never redirect an explicit
    /// source location to the same phrase near the beginning of the document.
    static func highlightRange(in text: String, line: Int?, query: String) -> NSRange? {
        let ns = text as NSString
        var target: NSRange?
        if let line {
            var pos = 0
            for _ in 1..<max(1, line) {
                guard pos < ns.length else { break }
                pos = NSMaxRange(ns.lineRange(for: NSRange(location: pos, length: 0)))
            }
            target = ns.lineRange(for: NSRange(location: min(pos, ns.length), length: 0))
        }
        if !query.isEmpty {
            let r = ns.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                             range: target ?? NSRange(location: 0, length: ns.length))
            if r.location != NSNotFound { target = r }
        }
        return target
    }

    static func lineNumber(in text: String, utf16Offset: Int) -> Int {
        let ns = text as NSString
        let caret = min(max(0, utf16Offset), ns.length)
        var line = 1, position = 0
        while position < caret {
            var end = 0, contentsEnd = 0
            ns.getLineStart(nil, end: &end, contentsEnd: &contentsEnd,
                            for: NSRange(location: position, length: 0))
            guard end > position, end <= caret, end > contentsEnd else { break }
            line += 1; position = end
        }
        return line
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var token = ""; var updating = false
        var focusTask: Task<Void, Never>?
        var onChange: ((String) -> Void)?; var onLine: ((Int) -> Void)?
        func textDidChange(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            onChange?(view.string)
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            onLine?(SourceTextView.lineNumber(in: view.string, utf16Offset: view.selectedRange().location))
        }
    }
}

/// First-responder changes also cover keyboard traversal and native Find commands.
final class PaneTextView: NSTextView {
    var onActivate: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onActivate?() }
        return accepted
    }
}
