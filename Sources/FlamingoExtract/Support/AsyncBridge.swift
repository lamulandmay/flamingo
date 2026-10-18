import Foundation

/// Waits synchronously for async work, for frameworks (AVFoundation, Quick Look) whose modern
/// API is async while `Extractor.extract` is sync. Blocks the calling thread, so call it from
/// GCD threads (as `Extract.extractInBackground` does), not from Swift concurrency's pool.
enum AsyncBridge {
    struct Timeout: Error {}

    static func wait<T>(timeout: TimeInterval = 30, _ body: @escaping @Sendable () async throws -> T) throws -> T {
        let box = Locked<Result<T, Error>?>(nil)
        let done = DispatchSemaphore(value: 0)
        // At the waiting thread's QoS: a thread blocked on a semaphore lends its priority to
        // nobody, so a fixed utility task left a user-initiated extraction (a document being
        // opened) waiting on the efficiency cores.
        let task = Task.detached(priority: callerPriority) {
            let r: Result<T, Error>
            do { r = .success(try await body()) } catch { r = .failure(error) }
            box.withLock { $0 = r }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            throw Timeout()
        }
        return try box.withLock { $0! }.get()
    }

    /// The calling thread's QoS as a task priority (user-interactive caps at `.high`).
    static var callerPriority: TaskPriority {
        let qos = qos_class_self()
        guard qos != QOS_CLASS_UNSPECIFIED else { return .medium }
        return TaskPriority(rawValue: UInt8(min(qos.rawValue, UInt32(TaskPriority.high.rawValue))))
    }
}
