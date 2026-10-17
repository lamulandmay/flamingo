import AppKit
import Combine
import FlamingoCore

/// Orders native text groups with workspace actions without registering either twice.
/// Other windows (capture, palettes and sheets) keep their own native undo history.
@MainActor
final class UndoRouting {
    enum Direction: Equatable { case undo, redo }
    enum Source: Equatable { case native, workspace }

    private weak var window: NSWindow?
    private let history: ActionHistory
    private let now: () -> TimeInterval
    private let workspaceUndo: () -> Void
    private let workspaceRedo: () -> Void
    private var timelines: [ObjectIdentifier: NativeUndoTimeline] = [:]
    private var observers: [NSObjectProtocol] = []
    private var historyObservation: AnyCancellable?
    private var keyMonitor: Any?
    private var registrationRevision: UInt
    private var contextID: UUID

    init(window: NSWindow, history: ActionHistory,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         undo: @escaping () -> Void, redo: @escaping () -> Void) {
        self.window = window; self.history = history; self.now = now
        workspaceUndo = undo; workspaceRedo = redo
        registrationRevision = history.registrationRevision
        contextID = history.contextID
        observe(.NSUndoManagerDidCloseUndoGroup) { router, manager in
            guard !manager.isUndoing, !manager.isRedoing, manager.groupingLevel == 0,
                  let timeline = router.timeline(for: manager) else { return }
            if timeline.closedGroup(at: router.now()) { router.history.discardRedo() }
        }
        observe(.NSUndoManagerDidUndoChange) { router, manager in
            router.timeline(for: manager)?.undid(at: router.now())
        }
        observe(.NSUndoManagerDidRedoChange) { router, manager in
            router.timeline(for: manager)?.redid(at: router.now())
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, !self.history.isApplying, let view = note.object as? NSTextView,
                      view.window === self.window, let manager = view.undoManager,
                      !manager.isUndoing, !manager.isRedoing else { return }
                self.timeline(for: manager, create: true)?.textChanged(at: self.now())
                self.history.discardRedo()
            }
        })
        historyObservation = history.objectWillChange.sink { [weak self] _ in
            // ActionHistory publishes before changing its stacks. Inspect the new revision
            // on the next turn so an undo or redo is never mistaken for a new action.
            DispatchQueue.main.async { [weak self] in self?.synchronizeRegistration() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.isWorkspaceWindow, let direction = Self.direction(for: event) else { return false }
                self.perform(direction)
                return true
            }
            return handled ? nil : event
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    static func direction(for event: NSEvent) -> Direction? {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        guard event.charactersIgnoringModifiers?.lowercased() == "z" else { return nil }
        if modifiers == .command { return .undo }
        if modifiers == [.command, .shift] { return .redo }
        return nil
    }

    /// Unknown pre-existing native groups sort before observed workspace actions.
    static func source(native: TimeInterval?, workspace: TimeInterval?) -> Source? {
        switch (native, workspace) {
        case let (.some(a), .some(b)): return a > b ? .native : .workspace
        case (.some, .none): return .native
        case (.none, .some): return .workspace
        case (.none, .none): return nil
        }
    }

    var isWorkspaceWindow: Bool {
        guard let window, NSApp.keyWindow === window,
              window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        return true
    }

    func menu(_ direction: Direction) -> (title: String, enabled: Bool) {
        let choice = choice(direction)
        let prefix = direction == .undo ? "Undo" : "Redo"
        guard let choice else { return (prefix, false) }
        let name: String
        switch choice {
        case .native(let manager): name = direction == .undo ? manager.undoActionName : manager.redoActionName
        case .workspace: name = (direction == .undo ? history.undoActionName : history.redoActionName) ?? ""
        }
        return (name.isEmpty ? prefix : prefix + " " + name, true)
    }

    func perform(_ direction: Direction) {
        // Finalize the current typing group before choosing, without manufacturing an action.
        if isWorkspaceWindow { (window?.firstResponder as? NSTextView)?.breakUndoCoalescing() }
        guard let choice = choice(direction) else { NSSound.beep(); return }
        switch choice {
        case .native(let manager):
            if direction == .undo { manager.undo() } else { manager.redo() }
        case .workspace:
            if direction == .undo { workspaceUndo() } else { workspaceRedo() }
        }
    }

    private enum Choice { case native(UndoManager), workspace }

    private func choice(_ direction: Direction) -> Choice? {
        synchronizeRegistration()
        let activeWindow = NSApp.modalWindow ?? NSApp.keyWindow
        let activeManager = activeWindow?.firstResponder?.undoManager ?? activeWindow?.undoManager
        guard isWorkspaceWindow else {
            guard let activeManager, direction == .undo ? activeManager.canUndo : activeManager.canRedo else { return nil }
            return .native(activeManager)
        }
        if let activeManager { _ = timeline(for: activeManager, create: true) }
        if let manager = window?.undoManager { _ = timeline(for: manager, create: true) }
        timelines = timelines.filter { $0.value.manager != nil }
        let native = timelines.values.compactMap { timeline -> (UndoManager, TimeInterval)? in
            guard let manager = timeline.manager, let time = timeline.latest(direction) else { return nil }
            return (manager, time)
        }.max { $0.1 < $1.1 }
        let workspace = direction == .undo ? history.latestUndoTime : history.latestRedoTime
        switch Self.source(native: native?.1, workspace: workspace) {
        case .native: return native.map { .native($0.0) }
        case .workspace: return .workspace
        case .none: return nil
        }
    }

    private func synchronizeRegistration() {
        if contextID != history.contextID {
            contextID = history.contextID
            for timeline in timelines.values { timeline.manager?.removeAllActions() }
            window?.undoManager?.removeAllActions()
            timelines = [:]
        }
        guard registrationRevision != history.registrationRevision else { return }
        registrationRevision = history.registrationRevision
        for timeline in timelines.values { timeline.suppressRedo() }
        (window?.firstResponder as? NSTextView)?.breakUndoCoalescing()
    }

    private func observe(_ name: Notification.Name, handler: @escaping @MainActor (UndoRouting, UndoManager) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let manager = note.object as? UndoManager else { return }
                handler(self, manager)
            }
        })
    }

    private func timeline(for manager: UndoManager, create: Bool = false) -> NativeUndoTimeline? {
        let id = ObjectIdentifier(manager)
        if let existing = timelines[id], existing.manager === manager { return existing }
        let isMainManager = manager === window?.undoManager || manager === window?.firstResponder?.undoManager
        guard create || isMainManager else { return nil }
        let timeline = NativeUndoTimeline(manager: manager)
        timelines[id] = timeline
        return timeline
    }
}

/// Native UndoManager exposes counts on macOS 14.4+, which keeps this timeline aligned
/// when NSTextView coalesces typing or clears old groups. Earlier systems use notifications.
@MainActor
final class NativeUndoTimeline {
    weak var manager: UndoManager?
    private var undoTimes: [TimeInterval] = []
    private var redoTimes: [TimeInterval] = []
    private var pendingTextTime: TimeInterval?
    private var redoSuppressed = false
    private var validRedoCount = 0

    init(manager: UndoManager) { self.manager = manager }

    func textChanged(at time: TimeInterval) {
        let oldCount = undoTimes.count
        reconcileCounts()
        pendingTextTime = time
        if !undoTimes.isEmpty, undoTimes.count > oldCount || manager?.groupingLevel == 0 {
            undoTimes[undoTimes.count - 1] = time
        }
        redoTimes = []; redoSuppressed = false; validRedoCount = 0
    }

    @discardableResult
    func closedGroup(at time: TimeInterval) -> Bool {
        let oldCount = undoTimes.count
        if #available(macOS 14.4, *) { reconcileCounts() }
        else if manager?.canUndo == true { undoTimes.append(time) }
        let changed = undoTimes.count > oldCount || pendingTextTime != nil
        if changed, !undoTimes.isEmpty { undoTimes[undoTimes.count - 1] = pendingTextTime ?? time }
        pendingTextTime = nil
        if changed { redoTimes = []; redoSuppressed = false; validRedoCount = 0 }
        return changed
    }

    func undid(at time: TimeInterval) {
        if #available(macOS 14.4, *), let manager {
            Self.resize(&undoTimes, count: manager.undoCount + 1)
        }
        if !undoTimes.isEmpty { undoTimes.removeLast() }
        redoTimes.append(time)
        pendingTextTime = nil
        if redoSuppressed { validRedoCount += 1 }
        reconcileCounts()
    }

    func redid(at time: TimeInterval) {
        if #available(macOS 14.4, *), let manager {
            Self.resize(&redoTimes, count: manager.redoCount + 1)
        }
        if !redoTimes.isEmpty { redoTimes.removeLast() }
        if redoSuppressed { validRedoCount = max(0, validRedoCount - 1) }
        undoTimes.append(time)
        pendingTextTime = nil
        reconcileCounts()
    }

    func suppressRedo() { reconcileCounts(); redoSuppressed = true; validRedoCount = 0 }

    func latest(_ direction: UndoRouting.Direction) -> TimeInterval? {
        reconcileCounts()
        guard let manager else { return nil }
        if direction == .undo { return manager.canUndo ? (pendingTextTime ?? undoTimes.last ?? -.infinity) : nil }
        return (!redoSuppressed || validRedoCount > 0) && manager.canRedo ? (redoTimes.last ?? -.infinity) : nil
    }

    private func reconcileCounts() {
        guard let manager else { undoTimes = []; redoTimes = []; return }
        // While a group is open, UndoManager's counts describe that group's contents,
        // not the committed outer history. Never truncate the older timeline from it.
        guard manager.groupingLevel == 0 else { return }
        if #available(macOS 14.4, *) {
            Self.resize(&undoTimes, count: manager.undoCount)
            Self.resize(&redoTimes, count: manager.redoCount)
        } else {
            if !manager.canUndo { undoTimes = [] }
            if !manager.canRedo { redoTimes = [] }
        }
    }

    private static func resize(_ values: inout [TimeInterval], count: Int) {
        if values.count > count { values.removeLast(values.count - count) }
        else if values.count < count { values.append(contentsOf: repeatElement(-.infinity, count: count - values.count)) }
    }
}
