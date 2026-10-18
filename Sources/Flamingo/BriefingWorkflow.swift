import AppKit
import SwiftUI
import FlamingoCore
import FlamingoAgents
import FlamingoDesign
import FlamingoIndex
import FlamingoThoughts
import FlamingoTrail
import FlamingoCapture

// MARK: - Window plan (pure)

/// How the window grows to the screen for the day's first briefing and shrinks back. Pure, so
/// the rules are testable: native full screen is left alone, and a window the person moved or
/// resized while the briefing was up is not put back.
enum BriefingWindowPlan {
    /// How close two frames must be to count as the same (the animation ends on whole points).
    static let tolerance: CGFloat = 2

    /// The frame to zoom to, nil when there is nothing to do: native full screen, or a window
    /// that already fills the visible frame.
    static func zoomTarget(window: CGRect, visible: CGRect, isFullScreen: Bool) -> CGRect? {
        guard !isFullScreen, !visible.isEmpty, !same(window, visible) else { return nil }
        return visible
    }

    /// The frame to restore, nil when it should stay as it is: the window went native full
    /// screen, or it no longer has the frame the zoom gave it (it was moved or resized).
    static func restoreTarget(saved: CGRect, zoomed: CGRect, current: CGRect, isFullScreen: Bool) -> CGRect? {
        guard !isFullScreen, same(current, zoomed), !same(current, saved) else { return nil }
        return saved
    }

    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// `x,y,w,h` for `Defaults.briefingSavedFrame`.
    static func encode(_ frame: CGRect) -> String {
        [frame.minX, frame.minY, frame.width, frame.height].map { String(Int($0.rounded())) }.joined(separator: ",")
    }

    static func decode(_ text: String?) -> CGRect? {
        guard let n = text?.split(separator: ",").compactMap({ Double($0) }), n.count == 4 else { return nil }
        return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }
}

// MARK: - Trigger glue (pure)

enum BriefingTrigger {
    /// A file-open request or the global palette this close to an activation is why the app
    /// came forward.
    static let causeWindow: TimeInterval = 1.0

    static func source(openFileAt: Date?, paletteAt: Date?, now: Date) -> ActivationSource {
        if let t = openFileAt, now.timeIntervalSince(t) < causeWindow { return .openFileRequest }
        if let t = paletteAt, now.timeIntervalSince(t) < causeWindow { return .globalPalette }
        return .user
    }

    static func conditions(sheetOrPanelUp: Bool, nothingToShow: Bool, underTest: Bool, autoOpenEnabled: Bool,
                           contentReady: Bool, launchedByFileRequest: Bool, appIsActive: Bool) -> BriefingConditions {
        var c = BriefingConditions()
        c.sheetOrPanelUp = sheetOrPanelUp; c.nothingToShow = nothingToShow; c.underTest = underTest
        c.autoOpenEnabled = autoOpenEnabled; c.contentReady = contentReady
        c.launchedByFileRequest = launchedByFileRequest; c.appIsActive = appIsActive
        return c
    }

    /// Whether `event` would open the briefing if there were something to show. Decided before
    /// the snapshot is built, so a day already shown, a toggle that is off or a sheet in the way
    /// costs nothing.
    static func wouldShow(_ clock: BriefingClock, _ event: BriefingEvent, now: Date, conditions: BriefingConditions) -> Bool {
        var probe = clock
        var c = conditions
        c.nothingToShow = false
        if case .show = probe.evaluate(event, now: now, conditions: c) { return true }
        return false
    }

    static var isUnderTest: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}

// MARK: - Memo aging (pure)

enum BriefingMemoAging {
    /// A memo is on the briefing the day it is first shown and any later time that day; the next
    /// briefing day it counts as seen. `firstShown` maps memo path to `yyyy-MM-dd`.
    static func apply(paths: [String], day: String, firstShown: [String: String]) -> (fresh: Set<String>, stale: Set<String>, updated: [String: String]) {
        var updated = firstShown
        var fresh = Set<String>(), stale = Set<String>()
        for path in paths {
            if let first = firstShown[path], first < day { stale.insert(path) }
            else { fresh.insert(path); if updated[path] == nil { updated[path] = day } }
        }
        return (fresh, stale, updated)
    }
}

// MARK: - Keys (pure)

enum BriefingKeyAction: Equatable {
    case move(Int), open, done, snooze, reply, attach, dismiss, close, none
}

enum BriefingKeys {
    static func action(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> BriefingKeyAction {
        if !modifiers.intersection([.command, .control, .option]).isEmpty { return .none }
        switch keyCode {
        case 53: return .close
        case 36, 76: return .open
        case 51, 117: return .dismiss
        case 126, 123: return .move(-1)
        case 125, 124: return .move(1)
        default: break
        }
        switch characters?.lowercased() {
        case "j": return .move(1)
        case "k": return .move(-1)
        case "e": return .done
        case "s": return .snooze
        case "r": return .reply
        case "a": return .attach
        default: return .none
        }
    }
}

// MARK: - Items

/// One selectable thing on the page.
enum BriefingItem: Identifiable, Equatable {
    case memo(MemoCardData)
    case thought(RankedThought)
    case edited(EditedFileItem)
    case loose(ThoughtRecord)
    case suggestion(SimilarSuggestion)
    case draft(Int, String)
    case problems(IndexProblems)
    case resume(Int, TrailLocation)
    /// Plan 18: an agent works in a folder that isn't a project yet.
    case project(ProjectOffer)

    var id: String {
        switch self {
        case .memo(let m): "m:" + m.path
        case .thought(let t): "t:" + t.id
        case .edited(let e): "e:" + e.id
        case .loose(let r): "l:" + r.id
        case .suggestion(let s): "s:" + s.id
        case .draft(let i, _): "d:\(i)"
        case .problems: "p"
        case .resume(let i, _): "r:\(i)"
        case .project(let o): "j:" + o.root.path
        }
    }

    /// The thought a triage key acts on.
    var record: ThoughtRecord? {
        switch self {
        case .thought(let t): t.record
        case .loose(let r): r
        default: nil
        }
    }
}

/// A memo being written right now, while the night shift catches up.
struct BriefingPlaceholder: Identifiable, Equatable {
    var id: String
    var file: FileRef
    var line: String
}

// MARK: - Dates

enum BriefingFormat {
    static func weekday(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        format(date, "EEEE", calendar, locale)
    }
    /// `October 17`: month first, in the person's language.
    static func monthDay(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale; f.calendar = calendar; f.timeZone = calendar.timeZone
        f.dateFormat = "MMMM d"
        return f.string(from: date)
    }

    /// Text with `[[target#anchor|alias]]` shown as the name a person would say.
    static func plain(_ text: String) -> String {
        guard text.contains("[[") else { return text }
        var out = text
        let pattern = try? NSRegularExpression(pattern: #"\[\[([^\]]+)\]\]"#)
        for m in (pattern?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []).reversed() {
            guard let r = Range(m.range, in: out), let inner = Range(m.range(at: 1), in: text) else { continue }
            let parts = Wikilink.components(of: String(text[inner]))
            out.replaceSubrange(r, with: parts.alias ?? (parts.target as NSString).lastPathComponent)
        }
        return out
    }

    /// A short mono date: the clock for today, the weekday within the week, else `Oct 14`.
    static func short(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        if days == 0 { return format(date, "jm", calendar, locale) }
        if days > 0, days < 7 { return format(date, "EEE", calendar, locale) }
        return format(date, "MMMd", calendar, locale)
    }

    private static func format(_ date: Date, _ template: String, _ calendar: Calendar, _ locale: Locale) -> String {
        let f = DateFormatter()
        f.locale = locale; f.calendar = calendar; f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }
}

// MARK: - Model

typealias BriefingCatchUp = (@escaping @Sendable (NightShiftEvent) -> Void) async -> Void

/// The morning inbox: when it opens, what it holds, which row is selected, what triage does.
/// An overlay state of the root layout, not a mode.
@MainActor
final class BriefingModel: ObservableObject {
    weak var state: AppState?

    /// The clock. The thoughts work sets it to its QA clock when it merges.
    var now: () -> Date = { Date() }
    /// The night shift's catch-up at the first open of the day. A no-op until it is hooked up.
    var catchUp: BriefingCatchUp = { _ in }

    // Presentation
    @Published private(set) var isPresented = false { didSet { if isPresented != oldValue { state?.briefingShown = isPresented } } }
    /// Drives the fades: false while mounting and while leaving.
    @Published private(set) var visible = false
    @Published private(set) var snapshot: BriefingSnapshot?
    @Published private(set) var removed: Set<String> = []
    @Published private(set) var leaving: Set<String> = []
    @Published private(set) var flashing: [String: Int] = [:]
    @Published private(set) var placeholders: [BriefingPlaceholder] = []
    @Published var selection: String?
    @Published var openMemo: MemoCardData?
    @Published var replying: String?
    @Published var replyText = ""
    @Published var attaching: String?
    @Published var attachQuery = ""
    @Published private(set) var attachMatches: [FileRef] = []
    /// Bumped to take the keyboard back into the page.
    @Published private(set) var focusRequest = 0
    @Published private(set) var contentVersion = 0

    private(set) var zoomed = false
    private var savedFrame: CGRect?
    private var zoomedFrame: CGRect?
    private var savedMode: AppState.Mode?
    private var history: BriefingHistory?
    private var clock = BriefingClock(lastShownDay: Defaults.lastBriefingDay)
    private var openFileAt: Date?
    private var paletteAt: Date?
    private var launchedByFile = false
    private var building = false
    private var lastEmptyCheck: Date?
    private var installed = false
    private let created = Date()
    private var attachTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    // MARK: Triggers

    func install() {
        guard !installed else { return }
        installed = true
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activated() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.woke() }
        })
        launched()
    }

    func noteOpenFileRequest() {
        openFileAt = Date()
        if Date().timeIntervalSince(created) < 3 { launchedByFile = true }
    }
    func noteGlobalPalette() { paletteAt = Date() }
    func noteLaunchedByFile() { launchedByFile = true }

    private var sheetOrPanelUp: Bool {
        guard let state else { return true }
        return state.isNewFilePresented || state.isHealthPresented || CaptureController.shared.isShowing
            || PaletteController.shared.isVisible || state.hostWindow?.attachedSheet != nil || NSApp.modalWindow != nil
    }

    private func conditions(contentReady: Bool = true) -> BriefingConditions {
        BriefingTrigger.conditions(
            sheetOrPanelUp: sheetOrPanelUp, nothingToShow: false, underTest: BriefingTrigger.isUnderTest,
            autoOpenEnabled: Defaults.briefingAutoOpen, contentReady: contentReady,
            launchedByFileRequest: launchedByFile, appIsActive: NSApp.isActive)
    }

    /// After the vault is restored and its first comments could load.
    private func launched() {
        Task { [weak self] in
            // The vault opens synchronously, but the index lags it; give the first thoughts time to land.
            for _ in 0..<30 {
                guard let self else { return }
                if self.state?.session != nil { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 700_000_000)
            await self.consider(.launch)
            // A first index pass is still writing the thoughts: ask again when it ends.
            for _ in 0..<40 where !self.isPresented && self.clock.lastShownDay != self.clock.day(self.now()) {
                guard self.state?.indexing.status != nil else { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if self.state?.indexing.status == nil { await self.consider(.launch, force: true) }
            }
        }
    }

    private func activated() {
        let source = BriefingTrigger.source(openFileAt: openFileAt, paletteAt: paletteAt, now: Date())
        Task { [weak self] in
            // An open-file request and the activation arrive within a beat of each other.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            let source = source == .user
                ? BriefingTrigger.source(openFileAt: self.openFileAt, paletteAt: self.paletteAt, now: Date()) : source
            await self.consider(.activation(source))
        }
    }

    private func woke() {
        Task { [weak self] in await self?.consider(.wake) }
    }

    /// One trigger event: decides cheaply, builds the snapshot only if it could open, then opens.
    func consider(_ event: BriefingEvent, force: Bool = false) async {
        guard !isPresented, !building, state?.vault != nil else { return }
        if !force, let t = lastEmptyCheck, Date().timeIntervalSince(t) < 120, event != .launch { return }
        let stamp = now()
        let c = conditions()
        guard BriefingTrigger.wouldShow(clock, event, now: stamp, conditions: c) else {
            // Record why it was skipped (open-file requests leave the day pending).
            var recorded = clock
            _ = recorded.evaluate(event, now: stamp, conditions: c)
            clock = recorded
            return
        }
        building = true
        let built = await buildSnapshot(now: stamp)
        building = false
        guard let built, !isPresented else { return }
        var final = c
        final.nothingToShow = built.isEmpty
        final.sheetOrPanelUp = sheetOrPanelUp
        let decision = clock.evaluate(event, now: stamp, conditions: final)
        guard case .show = decision else {
            if case .skip(.nothingToShow) = decision { lastEmptyCheck = Date() }
            return
        }
        lastEmptyCheck = nil
        clock.didShow(at: stamp)
        Defaults.lastBriefingDay = clock.lastShownDay
        present(built, zoom: true, firstOfDay: true)
    }

    // MARK: Building

    func buildSnapshot(now stamp: Date) async -> BriefingSnapshot? {
        guard let s = state?.session else { return nil }
        let vault = s.vault, trail = s.trail
        let drafts = CaptureDraftStore.pending(in: vault)
        let history = BriefingHistory(vault: vault)
        self.history = history
        let snap = await Task.detached(priority: .userInitiated) { () -> BriefingSnapshot? in
            guard let index = try? IndexStore(vault: vault, readOnly: true) else { return nil }
            return try? BriefingBuilder(vault: vault, index: index, trail: trail).build(now: stamp, history: history, recoveredDrafts: drafts)
        }.value
        guard var built = snap else { return nil }
        // A memo is new the day it is first shown; the next day it counts as seen.
        let key = vault.root.path + "|"
        let stored = Defaults.briefingMemoDays
        let paths = built.memos.map(\.path)
        let aging = BriefingMemoAging.apply(paths: paths.map { key + $0 }, day: built.day,
                                            firstShown: stored)
        built.memos = built.memos.filter { aging.fresh.contains(key + $0.path) }
        for path in paths where aging.stale.contains(key + path) { history.markMemoSeen(path) }
        if aging.updated != stored { Defaults.briefingMemoDays = aging.updated }
        return built
    }

    // MARK: Presenting

    /// The ribbon, the palette and ⌘0: opens without zooming the window.
    func show(zoom: Bool = false) {
        guard !isPresented, state?.vault != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            let stamp = self.now()
            guard let built = await self.buildSnapshot(now: stamp) else { return }
            self.present(built, zoom: zoom, firstOfDay: false)
        }
    }

    func toggle() {
        if isPresented { close() } else { show() }
    }

    private func present(_ built: BriefingSnapshot, zoom: Bool, firstOfDay: Bool) {
        guard !isPresented, let state else { return }
        snapshot = built
        removed = []; leaving = []; flashing = [:]; placeholders = []
        openMemo = nil; replying = nil; attaching = nil
        selection = built.address.first.map { BriefingItem.thought($0).id } ?? navigation.first?.id
        savedMode = state.mode
        isPresented = true
        if zoom { zoomWindow() }
        history?.recordShown(built.address.compactMap(\.record.uid), day: built.day)
        try? history?.save(now: now())
        markRepliesSeen(for: built)
        Log.debug("qa: briefing \(built.summary) zoom=\(zoomed) elapsed=\(Int(built.elapsed * 1000))ms")
        DispatchQueue.main.async { [weak self] in
            withAnimation(Theme.Motion.normal) { self?.visible = true }
            self?.focusRequest += 1
        }
        if firstOfDay { runCatchUp() }
    }

    /// Fades out over 150 ms and puts the window back. `mode` is where ⌘2 / ⌘3 go afterwards.
    func close(thenMode mode: AppState.Mode? = nil) {
        guard isPresented else { return }
        withAnimation(Theme.Motion.fast) { visible = false }
        restoreWindow()
        try? history?.save(now: now())
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.fastSeconds) { [weak self] in
            guard let self else { return }
            self.isPresented = false
            self.openMemo = nil; self.replying = nil; self.attaching = nil
            self.state?.focusSidebar?()
            if let mode { self.state?.mode = mode }
        }
    }

    /// Resets today's marker (QA, and "show it again tomorrow morning").
    func resetDay() {
        clock = BriefingClock(lastShownDay: nil)
        Defaults.lastBriefingDay = nil
        Defaults.briefingMemoDays = [:]
    }

    // MARK: Window

    private func zoomWindow() {
        guard let w = state?.hostWindow, let screen = w.screen ?? NSScreen.main else { return }
        let isFull = w.styleMask.contains(.fullScreen)
        guard let target = BriefingWindowPlan.zoomTarget(window: w.frame, visible: screen.visibleFrame, isFullScreen: isFull) else { return }
        savedFrame = w.frame
        zoomedFrame = target
        zoomed = true
        Defaults.briefingSavedFrame = BriefingWindowPlan.encode(w.frame)
        MainWindow.animationDuration = Theme.Motion.normalSeconds
        w.setFrame(target, display: true, animate: true)
        MainWindow.animationDuration = nil
        Log.debug("qa: briefing zoom frame=\(BriefingWindowPlan.encode(target)) from=\(BriefingWindowPlan.encode(savedFrame ?? .zero))")
    }

    private func restoreWindow() {
        defer { zoomed = false; savedFrame = nil; zoomedFrame = nil; Defaults.briefingSavedFrame = nil }
        guard zoomed, let w = state?.hostWindow, let saved = savedFrame, let zoomedFrame else { return }
        let isFull = w.styleMask.contains(.fullScreen)
        guard let target = BriefingWindowPlan.restoreTarget(saved: saved, zoomed: zoomedFrame, current: w.frame, isFullScreen: isFull) else { return }
        MainWindow.animationDuration = Theme.Motion.normalSeconds
        w.setFrame(target, display: true, animate: true)
        MainWindow.animationDuration = nil
        Log.debug("qa: briefing restore frame=\(BriefingWindowPlan.encode(target))")
    }

    /// A previous run quit with the window zoomed: put it back before anything is shown.
    func recoverInterruptedZoom() {
        guard let saved = BriefingWindowPlan.decode(Defaults.briefingSavedFrame), let w = state?.hostWindow,
              !w.styleMask.contains(.fullScreen) else { Defaults.briefingSavedFrame = nil; return }
        Defaults.briefingSavedFrame = nil
        w.setFrame(saved, display: true)
    }

    // MARK: Content

    var memos: [MemoCardData] { (snapshot?.memos ?? []).filter { !removed.contains(BriefingItem.memo($0).id) } }
    var address: [RankedThought] { (snapshot?.address ?? []).filter { !removed.contains(BriefingItem.thought($0).id) } }
    var resume: [TrailLocation] { snapshot?.resume ?? [] }

    /// The right-hand column in order: edited files, loose captures, suggestions, drafts, problems.
    var attention: [BriefingItem] {
        guard let s = snapshot else { return [] }
        var out: [BriefingItem] = []
        out += s.editedFiles.map { .edited($0) }
        out += s.looseCaptures.map { .loose($0) }
        out += s.suggestions.map { .suggestion($0) }
        out += s.recoveredDrafts.enumerated().map { .draft($0.offset, $0.element) }
        if s.problems.total > 0 { out.append(.problems(s.problems)) }
        out += (state?.agentProjects.offers ?? []).map { .project($0) }
        return out.filter { !removed.contains($0.id) }
    }

    /// Everything the arrow keys walk, in reading order.
    var navigation: [BriefingItem] {
        var out: [BriefingItem] = memos.map { .memo($0) }
        out += address.map { .thought($0) }
        out += attention
        out += resume.enumerated().map { .resume($0.offset, $0.element) }
        return out
    }

    var isEmpty: Bool { navigation.isEmpty && placeholders.isEmpty }

    var selectedItem: BriefingItem? { navigation.first { $0.id == selection } }

    func thought(for memo: MemoCardData) -> ThoughtRecord? {
        memo.thought ?? snapshot?.address.first { $0.record.uid == memo.memo.thought }?.record
    }

    func select(_ id: String) {
        selection = id
        requestFocus()
    }

    /// Takes the keyboard back into the page (after a click, or when a field is done).
    func requestFocus() { focusRequest += 1 }

    func move(_ delta: Int) {
        let items = navigation
        guard !items.isEmpty else { return }
        let i = items.firstIndex { $0.id == selection }
        let next = i.map { min(max($0 + delta, 0), items.count - 1) } ?? (delta > 0 ? 0 : items.count - 1)
        selection = items[next].id
    }

    private func advance(from id: String) {
        let items = navigation.filter { !leaving.contains($0.id) || $0.id == id }
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let rest = items.filter { $0.id != id }
        selection = rest.isEmpty ? nil : rest[min(i, rest.count - 1)].id
    }

    // MARK: Keys

    func handle(_ action: BriefingKeyAction) {
        if openMemo != nil {
            if action == .close || action == .open { openMemo = nil }
            return
        }
        switch action {
        case .close:
            if replying != nil || attaching != nil { cancelInline() } else { close() }
        case .move(let d): move(d)
        case .open: openSelected()
        case .done: if let item = selectedItem { done(item) }
        case .snooze: if let item = selectedItem { snooze(item) }
        case .dismiss: if let item = selectedItem { dismiss(item) }
        case .reply: if let item = selectedItem { beginReply(item) }
        case .attach: if let item = selectedItem { beginAttach(item) }
        case .none: break
        }
    }

    func openSelected() {
        guard let item = selectedItem else { return }
        open(item)
    }

    func open(_ item: BriefingItem) {
        guard let state else { return }
        switch item {
        case .memo(let m):
            selection = item.id
            openMemo = m
            history?.markMemoSeen(m.path)
            try? history?.save(now: now())
        case .thought(let t):
            jump(to: t.record)
        case .loose(let r):
            if r.file.isVirtual { beginAttach(item) } else { jump(to: r) }
        case .edited(let e):
            close(); state.jump(to: e.file, anchor: nil); state.showInspector(.thoughts)
        case .suggestion(let s):
            close(); state.jump(to: s.other, anchor: nil)
        case .draft:
            close(); CaptureController.shared.recoverDraft()
        case .problems:
            close(); state.isHealthPresented = true
        case .resume(_, let location):
            close(); state.jump(to: location.file, anchor: location.anchor)
        case .project(let o):
            close(); state.agentProjects.present(o.root)
        }
    }

    /// Closes, goes to the thought's place and selects its row in the rail.
    func jump(to record: ThoughtRecord) {
        guard let state else { return }
        history?.recordAction(record.uid ?? "")
        close()
        state.jump(to: record.file, anchor: record.comment.anchor)
        state.showInspector(.thoughts)
        state.selectThought(uid: record.uid, fallback: record.comment.id)
    }

    func openLink(_ raw: String, from file: FileRef? = nil) {
        guard let state else { return }
        close()
        state.openLink(raw, from: file)
    }

    // MARK: Triage

    func done(_ item: BriefingItem) {
        switch item {
        case .thought, .loose:
            guard let record = item.record else { return }
            let level = ThoughtStrength(record.comment).rawValue
            flashing[item.id] = level
            Chime.tick(level: level)
            change(item, record: record, name: "Mark Thought Done") { $0 = $0.settingState(.done) }
        case .suggestion(let s):
            remove(item)
            state?.connect(s.source, s.other)
            markPairSeen(s)
        case .memo, .edited, .draft, .problems, .resume, .project:
            break
        }
    }

    func snooze(_ item: BriefingItem) {
        guard let record = item.record else { return }
        let until = RailSnooze.tomorrow.date(from: now())
        change(item, record: record, name: "Snooze Thought") { $0 = $0.settingState(.snoozed, snoozeUntil: until) }
    }

    func dismiss(_ item: BriefingItem) {
        switch item {
        case .thought, .loose:
            guard let record = item.record else { return }
            change(item, record: record, name: "Dismiss Thought") { $0 = $0.settingState(.dismissed) }
        case .suggestion(let s):
            remove(item)
            state?.dismissSuggestion(s.source, s.other)
            markPairSeen(s)
        case .edited, .draft, .problems, .project:
            remove(item)
        case .memo, .resume:
            break
        }
    }

    private func markPairSeen(_ s: SimilarSuggestion) {
        history?.markPairSeen(s.source.relativePath, s.other.relativePath)
        try? history?.save(now: now())
    }

    /// Fades the row for 150 ms, closes the gap, and saves the new state; ⌘Z brings the row back.
    private func change(_ item: BriefingItem, record: ThoughtRecord, name: String, _ edit: @escaping (inout Comment) -> Void) {
        guard let state else { return }
        let id = item.id
        let flash = flashing[id] != nil
        history?.recordAction(record.uid ?? "")
        Task { [weak self] in
            // The glyph holds its tint for a beat, then the row goes.
            if flash { try? await Task.sleep(nanoseconds: UInt64(Theme.Motion.fastSeconds * 1_000_000_000)) }
            guard let self else { return }
            self.remove(item)
            do {
                try await state.briefingChange(record, name: name, edit,
                                               onUndo: { [weak self] in self?.restore(item) },
                                               onRedo: { [weak self] in self?.remove(item) })
                try? self.history?.save(now: self.now())
            } catch {
                self.restore(item)
                state.showToast(ToastMessage(text: error.localizedDescription))
            }
        }
    }

    func remove(_ item: BriefingItem) {
        let id = item.id
        advance(from: id)
        withAnimation(Theme.Motion.fast) { leaving.insert(id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.fastSeconds) { [weak self] in
            guard let self, self.leaving.contains(id) else { return }
            withAnimation(Theme.Motion.fast) { self.removed.insert(id); self.leaving.remove(id) }
            self.flashing[id] = nil
        }
    }

    func restore(_ item: BriefingItem) {
        let id = item.id
        withAnimation(Theme.Motion.fast) { leaving.remove(id); removed.remove(id); flashing[id] = nil }
        if isPresented { selection = id }
    }

    // MARK: Reply and attach

    func beginReply(_ item: BriefingItem) {
        guard case .thought = item else { return }
        attaching = nil
        replyText = ""
        selection = item.id
        withAnimation(Theme.Motion.fast) { replying = item.id }
    }

    func submitReply() {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = replying, let item = navigation.first(where: { $0.id == id }), let record = item.record, !text.isEmpty,
              let state else { return }
        withAnimation(Theme.Motion.fast) { replying = nil }
        replyText = ""
        focusRequest += 1
        history?.recordAction(record.uid ?? "")
        remove(item)
        Task { [weak self] in
            do {
                try await state.briefingReply(to: record, text: text, onUndo: { [weak self] in self?.restore(item) }, onRedo: { [weak self] in self?.remove(item) })
            } catch {
                self?.restore(item)
                state.showToast(ToastMessage(text: error.localizedDescription))
            }
        }
    }

    func beginAttach(_ item: BriefingItem) {
        guard case .loose = item else { return }
        replying = nil
        attachQuery = ""
        attachMatches = []
        selection = item.id
        withAnimation(Theme.Motion.fast) { attaching = item.id }
        searchTargets()
    }

    func searchTargets() {
        attachTask?.cancel()
        guard let state else { return }
        let query = attachQuery.trimmingCharacters(in: .whitespaces)
        let files = state.files
        attachTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let found: [FileRef] = await Task.detached(priority: .userInitiated) {
                guard !query.isEmpty else { return [] }
                var scored: [(Int, FileRef)] = []
                for f in files where !f.isVirtual {
                    if let s = Fuzzy.score(query, f.name) { scored.append((s, f)) }
                }
                return scored.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1.relativePath < $1.1.relativePath }.prefix(5).map(\.1)
            }.value
            guard !Task.isCancelled else { return }
            self?.attachMatches = found
        }
    }

    func attach(to target: FileRef) {
        guard let id = attaching, let item = navigation.first(where: { $0.id == id }), let record = item.record, let state else { return }
        withAnimation(Theme.Motion.fast) { attaching = nil }
        focusRequest += 1
        history?.recordAction(record.uid ?? "")
        remove(item)
        Task { [weak self] in
            do { try await state.attachInboxThought(record.comment, from: record.file, to: target) }
            catch {
                self?.restore(item)
                state.showToast(ToastMessage(text: error.localizedDescription))
            }
        }
    }

    func cancelInline() {
        withAnimation(Theme.Motion.fast) { replying = nil; attaching = nil }
        replyText = ""
        focusRequest += 1
    }

    // MARK: Night shift

    private func runCatchUp() {
        let hook = catchUp
        Task { [weak self] in
            await hook { event in
                Task { @MainActor in self?.catchUpEvent(event) }
            }
        }
    }

    func catchUpEvent(_ event: NightShiftEvent) {
        switch event {
        case .started(let job, _, let file):
            let ref = FileRef(relativePath: file)
            let line = snapshot?.address.first { $0.record.file == ref }?.record.comment.firstLine ?? ref.name
            withAnimation(Theme.Motion.normal) {
                if !placeholders.contains(where: { $0.id == job }) { placeholders.append(BriefingPlaceholder(id: job, file: ref, line: line)) }
            }
        case .finished(let job, _, _):
            Task { [weak self] in
                guard let self, let stamp = Optional(self.now()), let fresh = await self.buildSnapshot(now: stamp) else { return }
                withAnimation(Theme.Motion.normal) {
                    self.snapshot?.memos = fresh.memos
                    self.placeholders.removeAll { $0.id == job }
                    self.contentVersion += 1
                }
            }
        case .failed(let job, _):
            withAnimation(Theme.Motion.normal) { placeholders.removeAll { $0.id == job } }
        case .status, .replied:
            break
        }
    }

    // MARK: Replies

    /// The model replies to the thoughts on the page count as seen once they have been shown.
    private func markRepliesSeen(for built: BriefingSnapshot) {
        guard let s = state?.session, let history else { return }
        let parents = Set(built.address.compactMap(\.record.uid))
        guard !parents.isEmpty else { return }
        let vault = s.vault
        let stamp = now()
        Task.detached(priority: .utility) {
            guard let index = try? IndexStore(vault: vault, readOnly: true) else { return }
            var q = ThoughtQuery(states: nil, order: .newest, limit: 600)
            q.origin = .ai
            q.createdAfter = stamp.addingTimeInterval(-14 * 86_400)
            for r in (try? index.thoughts(q)) ?? [] where r.parent.map(parents.contains) == true {
                if let uid = r.uid { history.markReplySeen(uid) }
            }
            try? history.save(now: stamp)
        }
    }
}
