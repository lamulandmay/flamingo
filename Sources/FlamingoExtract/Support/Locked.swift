import Foundation

/// A value behind a lock. For the few bits of shared mutable state extractors need.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
}
