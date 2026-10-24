// Shared by Capybara and Flamingo. Capybara's Sources/CapybaraLink is the original; Flamingo's
// Sources/FlamingoLink/Shared is a copy (scripts/sync-link.sh). Change it here, then sync.

import Foundation
import Network

/// One TCP connection, cut into frames. Knows nothing about what the frames mean.
public final class LinkConnection {
    /// For diagnosing: every state change and close, when set.
    nonisolated(unsafe) static var log: ((String) -> Void)?
    /// For checking what crosses the network: every byte sent (true) and received (false).
    nonisolated(unsafe) public static var tap: ((Data, Bool) -> Void)?
    let nw: NWConnection
    private var buffer = Data()
    private var closed = false
    var onReady: (() -> Void)?
    var onFrame: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    init(_ nw: NWConnection) { self.nw = nw }

    /// TCP for the link: no Nagle delay (a request is one small frame), keepalives so a Mac that
    /// went to sleep is noticed, and only real network interfaces. A VPN or proxy tunnel is
    /// left out on purpose: the other Mac is on the same network, so the traffic has no reason
    /// to go anywhere else.
    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 4
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = false
        params.prohibitedInterfaceTypes = [.other]
        params.preferNoProxies = true
        params.serviceClass = .responsiveData
        return params
    }

    func start(queue: DispatchQueue) {
        nw.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Self.log?("\(self.nw.endpoint) \(state) \(self.nw.currentPath.map { "\($0.localEndpoint.map { "\($0)" } ?? "?") → \($0.remoteEndpoint.map { "\($0)" } ?? "?") via \($0.availableInterfaces.map(\.name))" } ?? "")")
            switch state {
            case .ready: self.onReady?(); self.receive()
            case .failed(let error): self.close(error)
            case .waiting(let error):
                // No route right now (Wi-Fi off, the other Mac asleep): give up and let the
                // owner try again when Bonjour sees it, rather than waiting here.
                self.close(error)
            case .cancelled: self.close(nil)
            default: break
            }
        }
        nw.start(queue: queue)
    }

    private func receive() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                Self.tap?(data, false)
                self.buffer.append(data)
                do {
                    for frame in try LinkWire.takeFrames(&self.buffer) {
                        guard !self.closed else { return }
                        self.onFrame?(frame)
                    }
                } catch {
                    return self.close(error)
                }
            }
            if let error { return self.close(error) }
            if isComplete { return self.close(nil) }
            self.receive()
        }
    }

    func send(_ bytes: Data) {
        guard !closed else { return }
        Self.tap?(bytes, true)
        nw.send(content: bytes, completion: .contentProcessed { [weak self] error in
            if let error { self?.close(error) }
        })
    }

    /// Sends, then closes once it has gone.
    func sendThenClose(_ bytes: Data) {
        guard !closed else { return }
        Self.tap?(bytes, true)
        nw.send(content: bytes, completion: .contentProcessed { [weak self] _ in self?.close(nil) })
    }

    func close(_ error: Error?) {
        guard !closed else { return }
        closed = true
        nw.cancel()
        let done = onClose
        onReady = nil; onFrame = nil; onClose = nil
        done?(error)
    }

    var isClosed: Bool { closed }
}
