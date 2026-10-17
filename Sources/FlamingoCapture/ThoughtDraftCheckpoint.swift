import Foundation

/// Captures and edits share one ordered recovery stream. The shell calls `flush()`
/// before closing a window, switching vaults, or terminating the process.
public enum ThoughtDraftCheckpoint {
    private struct Request {
        var generation: UInt64
        var key: String
        var required: Bool
        var operation: @Sendable () throws -> Void
        var completion: @Sendable (String?) -> Void
    }
    static let queue = DispatchQueue(label: "com.flamingo.thought-recovery", qos: .userInitiated)
    private static let lock = NSLock()
    private static var generation: UInt64 = 0
    private static var revisions: [String: UInt64] = [:]
    private static var pending: [String: Request] = [:]
    private static var failures: [String: String] = [:]
    private static var draining = false

    /// Empty means every required snapshot has reached disk. Failed writes remain
    /// visible until a newer snapshot succeeds; callers must keep the window open.
    public static func flush() -> [String] {
        queue.sync { lock.withLock { failures.values.sorted() } }
    }

    @discardableResult
    static func enqueue(key: String, required: Bool = true, ifCurrent: UInt64? = nil,
                        operation: @escaping @Sendable () throws -> Void,
                        completion: @escaping @Sendable (String?) -> Void = { _ in }) -> UInt64? {
        lock.withLock {
            if let ifCurrent, revisions[key] != ifCurrent { return nil }
            generation &+= 1
            revisions[key] = generation
            pending[key] = Request(generation: generation, key: key, required: required,
                                   operation: operation, completion: completion)
            if !draining { draining = true; queue.async { drain() } }
            return generation
        }
    }

    static func flush(key: String) -> String? {
        queue.sync { lock.withLock { failures[key] } }
    }

    static func flushAsync(key: String) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: lock.withLock { failures[key] }) }
        }
    }

    private static func drain() {
        while let request = lock.withLock({ () -> Request? in
            guard let request = pending.values.min(by: { $0.generation < $1.generation }) else {
                draining = false; return nil
            }
            pending[request.key] = nil
            return request
        }) {
            guard lock.withLock({ revisions[request.key] == request.generation }) else { continue }
            var failure: String?
            do { try request.operation() } catch { failure = error.localizedDescription }
            let current = lock.withLock { () -> Bool in
                guard revisions[request.key] == request.generation else { return false }
                failures[request.key] = request.required ? failure : nil
                return true
            }
            if current { request.completion(failure) }
        }
    }
}
