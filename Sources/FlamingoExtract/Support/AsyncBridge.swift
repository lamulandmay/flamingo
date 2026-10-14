import Foundation

/// Waits synchronously for async work, for frameworks (AVFoundation, Quick Look) whose modern
/// API is async while `Extractor.extract` is sync. Blocks the calling thread, so call it from
/// GCD threads (as `Extract.extractInBackground` does), not from Swift concurrency's pool.
enum AsyncBridge {
    struct Timeout: Error {}

    static func wait<T>(timeout: TimeInterval = 30, _ body: @escaping @Sendable () async throws -> T) throws -> T {
        let box = Locked<Result<T, Error>?>(nil)
        let done = DispatchSemaphore(value: 0)
        let task = Task.detached(priority: .utility) {
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
}
