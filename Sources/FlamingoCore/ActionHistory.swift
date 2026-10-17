import Combine
import Foundation

/// One ordered history for reversible app actions. Short-lived actions retain their
/// original deadline through undo and redo, while ordinary actions do not expire.
@MainActor
public final class ActionHistory: ObservableObject {
    public typealias Operation = @MainActor () throws -> Void

    @Published private var revision: UInt = 0
    public private(set) var isApplying = false
    /// Changes only for fresh actions, allowing native editors to invalidate their
    /// own redo branch without confusing an undo/redo transition with a new edit.
    public private(set) var registrationRevision: UInt = 0
    /// Async actions capture this before starting and compare it before registering,
    /// so a result from a previous vault cannot enter the current vault's history.
    public private(set) var contextID = UUID()

    private struct Action {
        let id: UUID
        let name: String
        let expiresAt: TimeInterval?
        var timestamp: TimeInterval
        let undo: Operation
        let redo: Operation

        func isAvailable(at time: TimeInterval) -> Bool {
            expiresAt.map { time < $0 } ?? true
        }
    }

    private let now: () -> TimeInterval
    private var undoStack: [Action] = []
    private var redoStack: [Action] = []

    public init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    public var canUndo: Bool { pruneExpired(); return !undoStack.isEmpty }
    public var canRedo: Bool { pruneExpired(); return !redoStack.isEmpty }
    public var undoActionName: String? { pruneExpired(); return undoStack.last?.name }
    public var redoActionName: String? { pruneExpired(); return redoStack.last?.name }
    /// Monotonic timestamps allow the app to order this history with native text edits.
    public var latestUndoTime: TimeInterval? { pruneExpired(); return undoStack.last?.timestamp }
    public var latestRedoTime: TimeInterval? { pruneExpired(); return redoStack.last?.timestamp }

    /// Register after the operation succeeds. Calls made by an undo/redo operation
    /// are ignored so normal action handlers can be safely reused when applying history.
    @discardableResult
    public func register(name: String, expiresAfter: TimeInterval? = nil,
                         undo: @escaping Operation, redo: @escaping Operation) -> UUID {
        let id = UUID()
        guard !isApplying else { return id }
        let time = now()
        revision &+= 1
        registrationRevision &+= 1
        pruneExpired(at: time)
        redoStack.removeAll()
        let action = Action(id: id, name: name, expiresAt: expiresAfter.map { time + $0 },
                            timestamp: time, undo: undo, redo: redo)
        if action.isAvailable(at: time) { undoStack.append(action) }
        return id
    }

    @discardableResult
    public func undo() throws -> Bool { try applyUndo(id: nil) }

    /// A targeted Undo button must not jump over more recent eligible actions.
    @discardableResult
    public func undo(id: UUID) throws -> Bool { try applyUndo(id: id) }

    @discardableResult
    public func redo() throws -> Bool {
        guard !isApplying else { return false }
        pruneExpired()
        guard var action = redoStack.last else { return false }
        revision &+= 1
        isApplying = true
        defer { isApplying = false }
        // Keep the entry in its original stack until the operation succeeds. A
        // thrown error therefore remains retryable and cannot consume the action.
        try action.redo()
        guard redoStack.contains(where: { $0.id == action.id }) else { return true }
        redoStack.removeAll { $0.id == action.id }
        let time = now()
        action.timestamp = time
        if action.isAvailable(at: time) { undoStack.append(action) }
        pruneExpired(at: time)
        return true
    }

    public func clear() {
        revision &+= 1
        contextID = UUID()
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// A fresh native text edit also invalidates redo in the shared app timeline.
    public func discardRedo() {
        guard !isApplying, !redoStack.isEmpty else { return }
        revision &+= 1
        redoStack.removeAll()
    }

    private func applyUndo(id: UUID?) throws -> Bool {
        guard !isApplying else { return false }
        pruneExpired()
        guard var action = undoStack.last, id == nil || action.id == id else { return false }
        revision &+= 1
        isApplying = true
        defer { isApplying = false }
        try action.undo()
        guard undoStack.contains(where: { $0.id == action.id }) else { return true }
        undoStack.removeAll { $0.id == action.id }
        let time = now()
        action.timestamp = time
        if action.isAvailable(at: time) { redoStack.append(action) }
        pruneExpired(at: time)
        return true
    }

    private func pruneExpired(at time: TimeInterval? = nil) {
        let time = time ?? now()
        // These reads can occur while SwiftUI evaluates a view, so expiry pruning
        // intentionally does not publish a change from within the getter.
        undoStack.removeAll { !$0.isAvailable(at: time) }
        redoStack.removeAll { !$0.isAvailable(at: time) }
    }
}
