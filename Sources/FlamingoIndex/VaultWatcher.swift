import Foundation
import FlamingoCore

/// FSEvents-backed watcher. Coalesces bursts. Plan 05 owns.
public final class VaultWatcher: @unchecked Sendable {
    public let vault: Vault
    public var onChange: (([FileRef]) -> Void)?
    public init(vault: Vault) { self.vault = vault }
    public func start() { /* TODO(plan 05) */ }
    public func stop() { /* TODO(plan 05) */ }
}
