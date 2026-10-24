// Shared by Capybara and Flamingo. Capybara's Sources/CapybaraLink is the original; Flamingo's
// Sources/FlamingoLink/Shared is a copy (scripts/sync-link.sh). Change it here, then sync.

import Foundation
import Network

/// The link between Capybara and Flamingo on the same network.
///
/// Flamingo is the responder: it announces itself with Bonjour and listens. Capybara is the
/// initiator: it looks for Flamingos and connects. A Mac it hasn't paired with can only pair
/// (public keys, nonces and names, then six digits you compare on both screens). A paired Mac
/// connects with the Noise KK handshake and everything after it is encrypted.
///
/// Connecting is told as a story the icons act out: `connecting` while the flamingo flies over,
/// `landing` with the moment it touches down, agreed by both Macs, and `connected` from that
/// moment on. Everything here runs on the main queue.
public final class LinkNode {
    public enum Role: Sendable { case initiator, responder }

    public enum Phase: String, Sendable { case absent, connecting, landing, connected }

    /// What the interface shows about one paired Mac.
    public struct Status: Equatable, Sendable {
        public var peer: LinkPairedPeer
        public var phase: Phase
        /// Seen on the network right now (initiator), or connected (responder).
        public var nearby: Bool
        /// When `connecting` began: the approach is timed from it.
        public var since: Date?
        /// When the flamingo's feet touch the capybara's back: `connected` from then on.
        public var touchdown: Date?
        /// Round trip in milliseconds, from the handshake and pings.
        public var rtt: Double?
        public var problem: String?
    }

    /// An unpaired Flamingo seen on the network (initiator only).
    public struct Nearby: Equatable, Sendable {
        public var id: String
        public var name: String
    }

    /// A pairing under way. Both sides show `code`; each person confirms it on their screen.
    public struct Pairing: Equatable, Sendable {
        public var peerName: String
        public var peerApp: String
        public var code: String?
        public var confirmed = false
        public var otherConfirmed = false
        public var done = false
        public var failed: String?
    }

    public let role: Role
    public let app: String
    public var name: String
    public let storage: LinkStorage
    public let identity: LinkIdentity
    public private(set) var nearby: [Nearby] = []
    public private(set) var pairing: Pairing?
    public private(set) var statuses: [String: Status] = [:]

    /// Something shown changed: statuses, nearby Macs, pairing.
    public var onChange: (() -> Void)?
    /// A request from the other Mac; call the reply once (with `["error": "…"]` to refuse).
    public var onRequest: ((_ peer: String, _ type: String, _ body: LinkBody, _ reply: @escaping (LinkBody) -> Void) -> Void)?
    /// A message that wants no answer. Durable ones arrive exactly once even across restarts.
    public var onMessage: ((_ peer: String, _ type: String, _ body: LinkBody) -> Void)?
    /// A paired Mac authenticated (before the landing): a good moment to sync.
    public var onSession: ((_ peer: String) -> Void)?

    /// Seconds without hearing anything before a connection counts as gone.
    var silenceLimit: TimeInterval = 7
    var pingEvery: TimeInterval = 2

    private let queue = DispatchQueue.main
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var endpoints: [String: NWEndpoint] = [:]
    private var nearbyEndpoints: [String: NWEndpoint] = [:]
    private var sessions: [String: Session] = [:]
    private var attempts: [String: Attempt] = [:]
    private var pairingLink: PairingLink?
    private var undecided: [ObjectIdentifier: LinkConnection] = [:]
    private var timer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var started = false

    public init(role: Role, app: String, name: String, storage: LinkStorage) {
        self.role = role
        self.app = app
        self.name = name
        self.storage = storage
        identity = storage.identity()
        for p in storage.peers { statuses[p.id] = Status(peer: p, phase: .absent, nearby: false) }
    }

    public var id: String { identity.id }

    // MARK: Start and stop

    public func start() {
        guard !started else { return }
        started = true
        switch role {
        case .responder: listen()
        case .initiator: browse()
        }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // A network change (Wi-Fi back, a new address) is the moment to try again at once.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self, path.status == .satisfied else { return }
            for attempt in self.attempts.values where attempt.connection == nil { attempt.next = .distantPast }
            self.tick()
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    public func stop() {
        started = false
        timer?.invalidate(); timer = nil
        pathMonitor?.cancel(); pathMonitor = nil
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        for s in sessions.values { s.connection.close(nil) }
        sessions = [:]
        for a in attempts.values { a.connection?.close(nil) }
        attempts = [:]
        pairingLink?.connection.close(nil)
        pairingLink = nil
    }

    // MARK: Responder: announce and listen

    private func listen() {
        do {
            let l = try NWListener(using: LinkConnection.parameters())
            var txt = NWTXTRecord()
            txt["id"] = identity.id
            txt["app"] = app
            txt["v"] = String(LinkWire.version)
            l.service = NWListener.Service(name: name, type: LinkWire.serviceType, domain: nil, txtRecord: txt)
            l.newConnectionHandler = { [weak self] nw in self?.accept(nw) }
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                LinkConnection.log?("listener \(state) port \(self.listener?.port.map { "\($0)" } ?? "?")")
                if case .failed = state {
                    // Port or Bonjour trouble: start over shortly.
                    self.listener?.cancel(); self.listener = nil
                    self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in if self?.started == true { self?.listen() } }
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in if self?.started == true { self?.listen() } }
        }
    }

    private func accept(_ nw: NWConnection) {
        LinkConnection.log?("accepted \(nw.endpoint)")
        let c = LinkConnection(nw)
        let key = ObjectIdentifier(c)
        // Held here until its first frame says what it is; then pairing or a session holds it.
        undecided[key] = c
        var decided = false
        c.onFrame = { [weak self, weak c] frame in
            guard let self, let c, !decided else { return }
            decided = true
            self.undecided[key] = nil
            guard let kind = frame.first.flatMap(LinkWire.Kind.init(rawValue:)) else { return c.close(LinkError.badFrame) }
            switch kind {
            case .pair: self.pairingStarted(c, first: Data(frame.dropFirst()))
            case .hello: self.helloReceived(c, Data(frame.dropFirst()))
            default: c.close(LinkError.badFrame)
            }
        }
        c.onClose = { [weak self] _ in self?.undecided[key] = nil }
        c.start(queue: queue)
        // A connection that says nothing is dropped.
        queue.asyncAfter(deadline: .now() + 10) { [weak c] in if !decided { c?.close(LinkError.timeout) } }
    }

    private func helloReceived(_ c: LinkConnection, _ data: Data) {
        let received = LinkWire.now()
        // Header: version, then the initiator's id and ours, 16 ASCII characters each.
        guard data.count > 33, data[data.startIndex] == UInt8(LinkWire.version),
              let theirID = String(data: data.dropFirst().prefix(16), encoding: .ascii),
              let ourID = String(data: data.dropFirst(17).prefix(16), encoding: .ascii) else { return c.close(LinkError.badFrame) }
        guard ourID == identity.id, let peer = storage.peers.first(where: { $0.id == theirID }) else {
            return c.sendThenClose(LinkWire.plain(.refuse, LinkWire.json(["why": "unpaired"])))
        }
        do {
            var hs = try LinkHandshake(role: .responder, local: identity, remoteStatic: peer.publicKey, prologue: Self.prologue(theirID, ourID))
            let payload = try LinkWire.unpack(try hs.readFirst(Data(data.dropFirst(33))))
            let back = try hs.writeSecond(LinkWire.pack(["app": app, "name": name, "v": LinkWire.version, "t1": received, "t2": LinkWire.now()]))
            c.send(LinkWire.plain(.helloBack, back))
            let (send, receive) = hs.split()
            let old = sessions[peer.id]
            let s = Session(peer: peer, connection: c, send: send, receive: receive)
            sessions[peer.id] = s
            old?.connection.close(nil)
            wire(s)
            // The name it goes by now, if it changed since pairing.
            if let theirName = payload.string("name"), theirName != peer.name { rename(peer.id, theirName) }
            update(peer.id) { $0.phase = .connecting; $0.since = Date(); $0.touchdown = nil; $0.nearby = true; $0.problem = nil }
            sessionOpened(s)
        } catch {
            c.close(LinkError.handshake)
        }
    }

    // MARK: Initiator: look and connect

    private func browse() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: LinkWire.serviceType, domain: nil), using: LinkConnection.parameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.found(results) }
        b.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state {
                self.browser?.cancel(); self.browser = nil
                self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in if self?.started == true { self?.browse() } }
            }
        }
        b.start(queue: queue)
        browser = b
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        var paired: [String: NWEndpoint] = [:]
        var others: [String: (String, NWEndpoint)] = [:]
        for r in results {
            guard case .bonjour(let txt) = r.metadata, let id = txt["id"], txt["app"] != app, id != identity.id else { continue }
            var serviceName = id
            if case .service(let n, _, _, _) = r.endpoint { serviceName = n }
            if storage.peers.contains(where: { $0.id == id }) { paired[id] = r.endpoint } else { others[id] = (serviceName, r.endpoint) }
        }
        endpoints = paired
        nearbyEndpoints = others.mapValues { $0.1 }
        nearby = others.map { Nearby(id: $0.key, name: $0.value.0) }.sorted { $0.name < $1.name }
        for p in storage.peers {
            let here = paired[p.id] != nil
            if statuses[p.id]?.nearby != here { update(p.id) { $0.nearby = here } }
            if here, sessions[p.id] == nil, attempts[p.id] == nil { attempts[p.id] = Attempt() }
            if !here, sessions[p.id] == nil { attempts[p.id]?.connection?.close(nil); attempts[p.id] = nil }
        }
        onChange?()
        tick()
    }

    /// One paired Flamingo we're trying to reach.
    final class Attempt {
        var connection: LinkConnection?
        var failures = 0
        var next = Date.distantPast
    }

    private func connect(_ peer: LinkPairedPeer, to endpoint: NWEndpoint, attempt: Attempt) {
        let c = LinkConnection(NWConnection(to: endpoint, using: LinkConnection.parameters()))
        attempt.connection = c
        // The first try shows the flight; quiet retries after a failure don't, so a Mac that
        // can't be reached doesn't make the icon fly back and forth.
        if attempt.failures == 0 { update(peer.id) { $0.phase = .connecting; $0.since = Date(); $0.touchdown = nil } }
        var hs: LinkHandshake?
        var sentAt = 0.0
        c.onReady = { [weak self] in
            guard let self else { return }
            do {
                var h = try LinkHandshake(role: .initiator, local: self.identity, remoteStatic: peer.publicKey,
                                          prologue: Self.prologue(self.identity.id, peer.id))
                sentAt = LinkWire.now()
                let first = try h.writeFirst(LinkWire.pack(["app": self.app, "name": self.name, "v": LinkWire.version, "t0": sentAt]))
                hs = h
                var header = Data([UInt8(LinkWire.version)])
                header += Data(self.identity.id.utf8) + Data(peer.id.utf8)
                c.send(LinkWire.plain(.hello, header + first))
            } catch { c.close(LinkError.handshake) }
        }
        c.onFrame = { [weak self] frame in
            guard let self, let kind = frame.first.flatMap(LinkWire.Kind.init(rawValue:)) else { return }
            let body = Data(frame.dropFirst())
            switch kind {
            case .helloBack:
                guard var h = hs else { return c.close(LinkError.handshake) }
                do {
                    let arrived = LinkWire.now()
                    let payload = try LinkWire.unpack(try h.readSecond(body))
                    let (send, receive) = h.split()
                    c.onFrame = nil; c.onClose = nil
                    attempt.connection = nil
                    self.attempts[peer.id] = nil
                    let s = Session(peer: peer, connection: c, send: send, receive: receive)
                    // NTP's estimate: how far their clock is ahead of ours, and the round trip.
                    if let t1 = payload.double("t1"), let t2 = payload.double("t2") {
                        s.offset = ((t1 - sentAt) + (t2 - arrived)) / 2
                        s.rtt = max(0, (arrived - sentAt) - (t2 - t1))
                    }
                    self.sessions[peer.id] = s
                    self.wire(s)
                    if let theirName = payload.string("name"), theirName != peer.name { self.rename(peer.id, theirName) }
                    // A quiet retry starts its flight now; a shown one keeps the one under way.
                    let shown = self.statuses[peer.id]?.phase == .connecting
                    let since = shown ? (self.statuses[peer.id]?.since ?? Date()) : Date()
                    self.update(peer.id) { $0.phase = .connecting; $0.since = since; $0.problem = nil; $0.rtt = s.rtt }
                    self.scheduleLanding(s)
                    self.sessionOpened(s)
                } catch { c.close(LinkError.handshake) }
            case .refuse:
                let why = LinkWire.object(body)?.string("why")
                c.close(why == "unpaired" ? LinkError.unpaired : LinkError.refused(why ?? "Refused"))
            default: c.close(LinkError.badFrame)
            }
        }
        c.onClose = { [weak self] error in
            guard let self else { return }
            attempt.connection = nil
            attempt.failures += 1
            attempt.next = Date().addingTimeInterval(min(8, 0.5 * pow(2, Double(min(attempt.failures, 5)))))
            let problem: String? = (error as? LinkError).map(\.message)
            self.update(peer.id) { $0.phase = .absent; $0.since = nil; $0.touchdown = nil; $0.problem = problem }
            if (error as? LinkError) == .unpaired { attempt.next = Date().addingTimeInterval(60) }
        }
        c.start(queue: queue)
    }

    /// Initiator: picks the moment of touchdown and tells the other Mac in its own clock.
    /// Neither side's flight is cut short: the landing starts once the approach has played and
    /// the flamingo has hovered a moment, and late enough for the message to arrive.
    private func scheduleLanding(_ s: Session) {
        let since = statuses[s.peer.id]?.since ?? Date()
        let lead = LinkMark.touchdown * LinkMark.landingDuration
        let earliestStart = max(since.addingTimeInterval(LinkMark.approachDuration + LinkMark.hoverPeriod * 0.5 + 0.1),
                                Date().addingTimeInterval(0.15 + (s.rtt ?? 0) / 1000))
        let touchdown = earliestStart.addingTimeInterval(lead)
        update(s.peer.id) { $0.phase = .landing; $0.touchdown = touchdown }
        s.post(["t": "land", "at": (touchdown.timeIntervalSince1970 * 1000).rounded() + s.offset])
    }

    // MARK: Sessions

    /// One authenticated, encrypted connection to a paired Mac.
    final class Session {
        let peer: LinkPairedPeer
        let connection: LinkConnection
        var send: LinkCipher
        var receive: LinkCipher
        var heard = Date()
        var pinged = Date()
        /// Their clock minus ours, in milliseconds (initiator only).
        var offset: Double = 0
        var rtt: Double?
        var waiting: [String: (timer: Timer, done: (Result<LinkBody, LinkError>) -> Void)] = [:]

        init(peer: LinkPairedPeer, connection: LinkConnection, send: LinkCipher, receive: LinkCipher) {
            self.peer = peer; self.connection = connection; self.send = send; self.receive = receive
        }

        func post(_ body: LinkBody) {
            guard let sealed = try? send.seal(LinkWire.pack(body)) else { return connection.close(LinkError.badFrame) }
            connection.send(LinkWire.frame(sealed))
        }
    }

    private func wire(_ s: Session) {
        s.connection.onFrame = { [weak self, weak s] frame in
            guard let self, let s else { return }
            do {
                let body = try LinkWire.unpack(try s.receive.open(frame))
                s.heard = Date()
                self.handle(body, from: s)
            } catch {
                s.connection.close(LinkError.badFrame)
            }
        }
        s.connection.onClose = { [weak self, weak s] _ in
            guard let self, let s else { return }
            for w in s.waiting.values { w.timer.invalidate(); w.done(.failure(.closed)) }
            s.waiting = [:]
            guard self.sessions[s.peer.id] === s else { return }
            self.sessions[s.peer.id] = nil
            self.update(s.peer.id) { $0.phase = .absent; $0.since = nil; $0.touchdown = nil; $0.rtt = nil; $0.nearby = self.role == .initiator && self.endpoints[s.peer.id] != nil }
            if self.role == .initiator, self.endpoints[s.peer.id] != nil {
                let a = Attempt()
                a.next = Date().addingTimeInterval(0.3)
                self.attempts[s.peer.id] = a
            }
        }
    }

    private func sessionOpened(_ s: Session) {
        onSession?(s.peer.id)
        for item in storage.outbox where item.peer == s.peer.id {
            if let body = LinkWire.object(item.json) { s.post(body) }
        }
    }

    private func handle(_ body: LinkBody, from s: Session) {
        guard let type = body.string("t") else { return }
        let peer = s.peer.id
        switch type {
        case "ping":
            s.post(["t": "pong", "t0": body["t0"] ?? 0, "t1": LinkWire.now()])
        case "pong":
            if let t0 = body.double("t0") {
                let rtt = LinkWire.now() - t0
                s.rtt = s.rtt.map { $0 * 0.7 + rtt * 0.3 } ?? rtt
                if let old = statuses[peer]?.rtt, abs(old - (s.rtt ?? 0)) < 2 { break }
                update(peer, quietly: true) { $0.rtt = s.rtt }
            }
        case "land":
            // Responder: their moment, in our clock.
            guard role == .responder, let at = body.double("at") else { break }
            let touchdown = Date(timeIntervalSince1970: at / 1000)
            update(peer) { $0.phase = .landing; $0.touchdown = touchdown }
        case "reply":
            guard let re = body.string("re"), let w = s.waiting.removeValue(forKey: re) else { break }
            w.timer.invalidate()
            if let error = body.string("error") { w.done(.failure(.refused(error))) } else { w.done(.success(body)) }
        case "ack":
            guard let re = body.string("re") else { break }
            storage.setOutbox(storage.outbox.filter { $0.id != re })
        case "unpair":
            forget(peer)
        default:
            if body.bool("durable") == true, let id = body.string("id") {
                if !storage.seen(id) {
                    onMessage?(peer, type, body)
                    storage.markSeen(id)
                }
                s.post(["t": "ack", "re": id])
            } else if let id = body.string("id") {
                var answered = false
                let reply: (LinkBody) -> Void = { [weak s] answer in
                    guard !answered else { return }
                    answered = true
                    var out = answer
                    out["t"] = "reply"; out["re"] = id
                    s?.post(out)
                }
                if let onRequest { onRequest(peer, type, body, reply) } else { reply(["error": "Not understood"]) }
            } else {
                onMessage?(peer, type, body)
            }
        }
    }

    // MARK: Sending

    /// Asks the other Mac and calls back with its answer, on the main queue.
    public func request(_ type: String, _ body: LinkBody = [:], to peer: String, timeout: TimeInterval = 6,
                        _ done: @escaping (Result<LinkBody, LinkError>) -> Void) {
        guard let s = sessions[peer] else { return done(.failure(.notConnected)) }
        let id = LinkWire.newID()
        var out = body
        out["t"] = type; out["id"] = id
        let timer = Timer(timeInterval: timeout, repeats: false) { [weak s] _ in
            guard let w = s?.waiting.removeValue(forKey: id) else { return }
            w.done(.failure(.timeout))
        }
        RunLoop.main.add(timer, forMode: .common)
        s.waiting[id] = (timer, done)
        s.post(out)
    }

    /// Sends now if connected; dropped otherwise.
    public func send(_ type: String, _ body: LinkBody = [:], to peer: String) {
        var out = body
        out["t"] = type
        sessions[peer]?.post(out)
    }

    /// Sends now if connected and keeps it until the other Mac confirms, across restarts.
    /// Returns its id.
    @discardableResult
    public func post(_ type: String, _ body: LinkBody, to peer: String, id: String = LinkWire.newID()) -> String {
        var out = body
        out["t"] = type; out["id"] = id; out["durable"] = true
        storage.setOutbox(storage.outbox + [LinkOutgoing(id: id, peer: peer, json: LinkWire.json(out))])
        sessions[peer]?.post(out)
        return id
    }

    /// Messages waiting for `peer`, oldest first.
    public func waiting(for peer: String) -> [LinkBody] {
        storage.outbox.filter { $0.peer == peer }.compactMap { LinkWire.object($0.json) }
    }

    public func isConnected(_ peer: String) -> Bool { sessions[peer] != nil }

    // MARK: Time

    private func tick() {
        let now = Date()
        for (id, s) in sessions {
            if now.timeIntervalSince(s.heard) > silenceLimit { s.connection.close(LinkError.timeout); continue }
            if now.timeIntervalSince(s.pinged) >= pingEvery {
                s.pinged = now
                s.post(["t": "ping", "t0": LinkWire.now()])
            }
            if statuses[id]?.phase == .landing, let t = statuses[id]?.touchdown, t <= now {
                update(id) { $0.phase = .connected }
            }
            // A responder whose initiator never named a moment (an older version) lands anyway.
            if role == .responder, statuses[id]?.phase == .connecting, let since = statuses[id]?.since, now.timeIntervalSince(since) > 4 {
                update(id) { $0.phase = .connected; $0.touchdown = now }
            }
        }
        guard role == .initiator else { return }
        for (id, attempt) in attempts where attempt.connection == nil && attempt.next <= now && sessions[id] == nil {
            guard let peer = storage.peers.first(where: { $0.id == id }), let endpoint = endpoints[id] else { continue }
            connect(peer, to: endpoint, attempt: attempt)
        }
    }

    /// The landing's last moment, to the frame: `tick` runs every half second, which is too
    /// coarse for "connected exactly when it lands".
    private func armTouchdown(_ id: String, _ at: Date) {
        let delay = max(0, at.timeIntervalSinceNow)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.statuses[id]?.phase == .landing, let t = self.statuses[id]?.touchdown, t <= Date().addingTimeInterval(0.004) else { return }
            self.update(id) { $0.phase = .connected }
        }
    }

    // MARK: Status

    private func update(_ id: String, quietly: Bool = false, _ change: (inout Status) -> Void) {
        guard var s = statuses[id] ?? storage.peers.first(where: { $0.id == id }).map({ Status(peer: $0, phase: .absent, nearby: false) }) else { return }
        let before = s
        change(&s)
        statuses[id] = s
        if s.phase == .landing, let t = s.touchdown, before.touchdown != t { armTouchdown(id, t) }
        if s != before, !quietly { onChange?() }
    }

    private func rename(_ id: String, _ newName: String) {
        storage.setPeers(storage.peers.map { var p = $0; if p.id == id { p.name = newName }; return p })
        update(id) { $0.peer.name = newName }
    }

    /// The paired Mac that matters most right now: connected over landing over connecting.
    public var primary: Status? {
        let order: [Phase] = [.connected, .landing, .connecting, .absent]
        return statuses.values.min { a, b in
            (order.firstIndex(of: a.phase)!, a.peer.paired) < (order.firstIndex(of: b.phase)!, b.peer.paired)
        }
    }

    // MARK: Unpairing

    /// Forgets `peer` here and tells it to forget this Mac if it can hear us.
    public func unpair(_ peer: String) {
        send("unpair", [:], to: peer)
        let s = sessions[peer]
        queue.asyncAfter(deadline: .now() + 0.2) { s?.connection.close(nil) }
        forget(peer)
    }

    private func forget(_ peer: String) {
        storage.setPeers(storage.peers.filter { $0.id != peer })
        storage.setOutbox(storage.outbox.filter { $0.peer != peer })
        statuses[peer] = nil
        attempts[peer]?.connection?.close(nil)
        attempts[peer] = nil
        if let s = sessions.removeValue(forKey: peer) { queue.asyncAfter(deadline: .now() + 0.2) { s.connection.close(nil) } }
        if role == .initiator, let e = endpoints.removeValue(forKey: peer) { nearbyEndpoints[peer] = e }
        onChange?()
    }

    // MARK: Pairing

    final class PairingLink {
        let connection: LinkConnection
        var theirKey: Data?
        var theirID: String?
        var theirApp = ""
        var ourNonce = LinkPairing.nonce()
        var theirNonce: Data?
        var commitment: Data?
        var timeout: DispatchWorkItem?
        init(_ c: LinkConnection) { connection = c }
    }

    /// Initiator: starts pairing with a Flamingo from `nearby`.
    public func pair(with id: String) {
        guard role == .initiator, let endpoint = nearbyEndpoints[id] else { return }
        cancelPairing(tell: true)
        let c = LinkConnection(NWConnection(to: endpoint, using: LinkConnection.parameters()))
        let link = PairingLink(c)
        pairingLink = link
        pairing = Pairing(peerName: nearby.first { $0.id == id }?.name ?? "", peerApp: "")
        c.onReady = { [weak self] in
            guard let self else { return }
            c.send(LinkWire.plain(.pair, LinkWire.json(["step": "start", "app": self.app, "name": self.name, "id": self.identity.id,
                                                       "key": self.identity.publicKey.base64EncodedString(), "v": LinkWire.version])))
        }
        c.onFrame = { [weak self] frame in self?.pairFrame(frame, link) }
        c.onClose = { [weak self] _ in self?.pairingClosed(link) }
        c.start(queue: queue)
        armPairingTimeout(link)
        onChange?()
    }

    /// Responder: an unpaired Mac asked to pair.
    private func pairingStarted(_ c: LinkConnection, first: Data) {
        guard let o = LinkWire.object(first), o.string("step") == "start", let key = o.data("key"), key.count == 32,
              let theirID = o.string("id"), theirID == LinkIdentity.fingerprint(key), key != identity.publicKey,
              let theirApp = o.string("app"), theirApp != app else { return c.close(LinkError.badFrame) }
        // One pairing at a time; a second Mac waits its turn.
        if let current = pairingLink, !current.connection.isClosed, pairing?.done != true {
            return c.sendThenClose(LinkWire.plain(.pair, LinkWire.json(["step": "cancel", "why": "busy"])))
        }
        let link = PairingLink(c)
        link.theirKey = key; link.theirID = theirID; link.theirApp = theirApp
        link.commitment = LinkPairing.commitment(responderKey: identity.publicKey, initiatorKey: key, responderNonce: link.ourNonce)
        pairingLink = link
        pairing = Pairing(peerName: o.string("name") ?? "Capybara", peerApp: theirApp)
        c.onFrame = { [weak self] frame in self?.pairFrame(frame, link) }
        c.onClose = { [weak self] _ in self?.pairingClosed(link) }
        c.send(LinkWire.plain(.pair, LinkWire.json(["step": "commit", "app": app, "name": name, "id": identity.id,
                                                   "key": identity.publicKey.base64EncodedString(), "commit": link.commitment!.base64EncodedString()])))
        armPairingTimeout(link)
        onChange?()
    }

    private func pairFrame(_ frame: Data, _ link: PairingLink) {
        guard pairingLink === link, frame.first == LinkWire.Kind.pair.rawValue, let o = LinkWire.object(Data(frame.dropFirst())),
              let step = o.string("step") else { return link.connection.close(LinkError.badFrame) }
        func send(_ body: LinkBody) { link.connection.send(LinkWire.plain(.pair, LinkWire.json(body))) }
        switch (role, step) {
        case (.initiator, "commit"):
            guard let key = o.data("key"), key.count == 32, o.string("id") == LinkIdentity.fingerprint(key), key != identity.publicKey,
                  let commit = o.data("commit"), let theirApp = o.string("app"), theirApp != app else { return failPairing("That Mac didn't answer properly") }
            link.theirKey = key; link.theirID = o.string("id"); link.commitment = commit; link.theirApp = theirApp
            pairing?.peerName = o.string("name") ?? pairing?.peerName ?? ""
            pairing?.peerApp = theirApp
            send(["step": "nonce", "nonce": link.ourNonce.base64EncodedString()])
        case (.responder, "nonce"):
            guard let n = o.data("nonce"), n.count == 16, let key = link.theirKey else { return failPairing("That Mac didn't answer properly") }
            link.theirNonce = n
            send(["step": "reveal", "nonce": link.ourNonce.base64EncodedString()])
            pairing?.code = LinkPairing.code(initiatorKey: key, responderKey: identity.publicKey, initiatorNonce: n, responderNonce: link.ourNonce)
            onChange?()
        case (.initiator, "reveal"):
            guard let n = o.data("nonce"), n.count == 16, let key = link.theirKey, let commit = link.commitment,
                  LinkPairing.commitment(responderKey: key, initiatorKey: identity.publicKey, responderNonce: n) == commit
            else { return failPairing("Something on the network interfered. Try again.") }
            link.theirNonce = n
            pairing?.code = LinkPairing.code(initiatorKey: identity.publicKey, responderKey: key, initiatorNonce: link.ourNonce, responderNonce: n)
            onChange?()
        case (_, "confirm"):
            guard pairing?.code != nil else { return failPairing("That Mac didn't answer properly") }
            pairing?.otherConfirmed = true
            finishPairingIfBoth(link)
            onChange?()
        case (_, "cancel"):
            failPairing(o.string("why") == "busy" ? "That Mac is pairing with another one. Try again in a minute." : "Cancelled on the other Mac")
        default:
            failPairing("That Mac didn't answer properly")
        }
    }

    /// The person checked the digits match and clicked Pair.
    public func confirmPairing() {
        guard let link = pairingLink, pairing?.code != nil, pairing?.confirmed == false else { return }
        pairing?.confirmed = true
        link.connection.send(LinkWire.plain(.pair, LinkWire.json(["step": "confirm"])))
        finishPairingIfBoth(link)
        onChange?()
    }

    private func finishPairingIfBoth(_ link: PairingLink) {
        guard pairing?.confirmed == true, pairing?.otherConfirmed == true, let key = link.theirKey, let theirID = link.theirID else { return }
        link.timeout?.cancel()
        let peer = LinkPairedPeer(id: theirID, publicKey: key, name: pairing?.peerName ?? "", app: link.theirApp)
        storage.setPeers(storage.peers.filter { $0.id != theirID } + [peer])
        statuses[theirID] = Status(peer: peer, phase: .absent, nearby: role == .initiator)
        pairing?.done = true
        // Leave the connection a moment so our confirm reaches them, then go secure.
        queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            link.connection.close(nil)
            guard let self, self.role == .initiator else { return }
            if let e = self.nearbyEndpoints.removeValue(forKey: theirID) { self.endpoints[theirID] = e }
            self.nearby.removeAll { $0.id == theirID }
            self.attempts[theirID] = Attempt()
            self.tick()
            self.onChange?()
        }
        onChange?()
    }

    private func failPairing(_ why: String) {
        guard let link = pairingLink else { return }
        link.timeout?.cancel()
        pairing?.failed = why
        link.connection.close(nil)
        onChange?()
    }

    private func pairingClosed(_ link: PairingLink) {
        guard pairingLink === link, pairing?.done != true, pairing?.failed == nil else { return }
        pairing?.failed = "The other Mac went away"
        onChange?()
    }

    private func armPairingTimeout(_ link: PairingLink) {
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.pairingLink === link, self.pairing?.done != true else { return }
            self.failPairing("Nobody confirmed in time")
        }
        link.timeout = item
        queue.asyncAfter(deadline: .now() + 120, execute: item)
    }

    /// Stops a pairing (Cancel), or clears a finished or failed one from view.
    public func cancelPairing(tell: Bool = true) {
        if let link = pairingLink {
            link.timeout?.cancel()
            if tell, pairing?.done != true, !link.connection.isClosed {
                link.connection.sendThenClose(LinkWire.plain(.pair, LinkWire.json(["step": "cancel"])))
            } else if pairing?.done != true {
                link.connection.close(nil)
            }
        }
        pairingLink = nil
        pairing = nil
        onChange?()
    }

    static func prologue(_ initiator: String, _ responder: String) -> Data {
        Data("capyflamingo/\(LinkWire.version)|\(initiator)|\(responder)".utf8)
    }
}
