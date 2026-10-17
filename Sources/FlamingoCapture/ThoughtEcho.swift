import SwiftUI
import AppKit
import FlamingoCore
import FlamingoDesign

/// An earlier thought that says something like the draft. All of it is the person's own data.
public struct EchoHit: Identifiable, Hashable, Sendable {
    public var uid: String?
    public var file: FileRef
    public var firstLine: String
    public var kind: ThoughtKind
    public var state: ThoughtState
    public var date: Date

    public init(uid: String? = nil, file: FileRef, firstLine: String, kind: ThoughtKind = .idea,
                state: ThoughtState = .open, date: Date) {
        self.uid = uid; self.file = file; self.firstLine = firstLine; self.kind = kind; self.state = state; self.date = date
    }

    public var id: String { uid ?? "\(file.relativePath)|\(date.timeIntervalSince1970)|\(firstLine)" }
}

/// Watches a draft and finds earlier thoughts like it. After `delay` of no typing, and only
/// once the draft has `minimumWords` words, it asks `similar`; the answer is cut to two hits.
/// A newer draft makes an older answer obsolete, so it is never shown. Time comes from `sleep`,
/// which a test replaces.
@MainActor
public final class ThoughtEchoModel: ObservableObject {
    @Published public private(set) var hits: [EchoHit] = []

    /// Set by the shell: the similar earlier thoughts for a draft, best first. The shell leaves
    /// out the thought being edited, and returns nothing when the index is not ready.
    public var similar: ((String) async -> [EchoHit])?

    nonisolated public static let defaultDelay: TimeInterval = 0.4
    nonisolated public static let defaultMinimumWords = 4
    nonisolated public static let maximumHits = 2

    let delay: TimeInterval
    let minimumWords: Int
    private let sleep: (TimeInterval) async throws -> Void
    private var task: Task<Void, Never>?
    private var asked = ""

    public init(similar: ((String) async -> [EchoHit])? = nil, delay: TimeInterval = ThoughtEchoModel.defaultDelay,
                minimumWords: Int = ThoughtEchoModel.defaultMinimumWords,
                sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.similar = similar; self.delay = delay; self.minimumWords = minimumWords; self.sleep = sleep
    }

    /// Words in what the person wrote: quote lines and `@ai` do not count. Chinese and Japanese
    /// count by the system's word segmentation.
    public static func wordCount(_ draft: String) -> Int {
        let prose = ThoughtRules.prose(of: draft)
        var n = 0
        prose.enumerateSubstrings(in: prose.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in n += 1 }
        return n
    }

    /// Call on every change to the draft.
    public func update(draft: String) {
        task?.cancel()
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.wordCount(text) >= minimumWords else {
            asked = ""
            if !hits.isEmpty { hits = [] }
            return
        }
        guard text != asked || hits.isEmpty else { return }
        task = Task { [weak self, delay, sleep] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self, let similar = self.similar else { return }
            self.asked = text
            let found = await similar(text)
            guard !Task.isCancelled else { return }
            let next = Array(found.prefix(Self.maximumHits))
            if next != self.hits { self.hits = next }
        }
    }

    /// Forget the draft: after it is saved or the panel closes.
    public func reset() {
        task?.cancel()
        asked = ""
        hits = []
    }

    /// Shows `hits` as if found, for previews and snapshots.
    func setHitsForPreview(_ hits: [EchoHit]) { self.hits = hits }

    /// Waits for the pending lookup, for tests.
    func settle() async { await task?.value }
}

/// Up to two earlier thoughts above the composer. Click jumps to the thought; ⌥-click turns
/// the draft into a reply to it. No words of its own: kind glyph, the thought's first line,
/// its file name and its date.
public struct ThoughtEcho: View {
    @ObservedObject var model: ThoughtEchoModel
    var onJump: (EchoHit) -> Void
    var onReplyTo: (EchoHit) -> Void

    public init(model: ThoughtEchoModel, onJump: @escaping (EchoHit) -> Void, onReplyTo: @escaping (EchoHit) -> Void = { _ in }) {
        self.model = model; self.onJump = onJump; self.onReplyTo = onReplyTo
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.hits) { hit in
                EchoRow(hit: hit) {
                    if NSEvent.modifierFlags.contains(.option) { onReplyTo(hit) } else { onJump(hit) }
                }
                .transition(.opacity)
            }
        }
        .animation(Theme.Motion.fast, value: model.hits.map(\.id))
    }
}

private struct EchoRow: View {
    let hit: EchoHit
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            KindGlyph(kind: hit.kind, state: hit.state).frame(width: Theme.Size.icon)
            Text(hit.firstLine)
                .font(Theme.Font.small)
                .foregroundStyle(Theme.Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Theme.Space.s)
            Text(hit.file.name)
                .font(Theme.Font.small)
                .foregroundStyle(Theme.Color.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 120, alignment: .trailing)
            Text(RailText.timestamp(hit.date))
                .font(Theme.Font.monoSmall)
                .foregroundStyle(Theme.Color.textTertiary)
                .fixedSize()
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: Theme.Size.row)
        .background(hovering ? Theme.Color.hover : .clear, in: Squircle(radius: Theme.Radius.s))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fast, value: hovering)
        .onTapGesture(perform: action)
        .pointingHandCursor()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
