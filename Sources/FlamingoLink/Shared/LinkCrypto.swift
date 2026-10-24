// Shared by Capybara and Flamingo. Capybara's Sources/CapybaraLink is the original; Flamingo's
// Sources/FlamingoLink/Shared is a copy (scripts/sync-link.sh). Change it here, then sync.

import Foundation
import CryptoKit

/// This Mac's key for the link: an X25519 key made once and kept in the Keychain. Its public
/// half is what the other Mac remembers after pairing; nothing else identifies a device.
public struct LinkIdentity: Sendable {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey = .init()) { self.privateKey = privateKey }

    public init?(raw: Data) {
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else { return nil }
        privateKey = key
    }

    public var raw: Data { privateKey.rawRepresentation }
    public var publicKey: Data { privateKey.publicKey.rawRepresentation }
    /// Sixteen hex characters of the public key's hash: what Bonjour shows and peers are filed by.
    public var id: String { Self.fingerprint(publicKey) }

    public static func fingerprint(_ publicKey: Data) -> String {
        SHA256.hash(data: publicKey).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// One direction of an encrypted connection: ChaCha20-Poly1305 with a counter for the nonce,
/// so a frame that is replayed, dropped or reordered fails to open and the connection ends.
public struct LinkCipher: Sendable {
    let key: SymmetricKey
    var counter: UInt64 = 0

    init(key: SymmetricKey) { self.key = key }

    static func nonce(_ n: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        withUnsafeBytes(of: n.littleEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    /// Ciphertext followed by the 16-byte tag.
    public mutating func seal(_ plaintext: Data, ad: Data = Data()) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: Self.nonce(counter), authenticating: ad)
        counter += 1
        return Data(box.ciphertext + box.tag)
    }

    public mutating func open(_ data: Data, ad: Data = Data()) throws -> Data {
        guard data.count >= 16 else { throw LinkError.badFrame }
        let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(counter), ciphertext: data.dropLast(16), tag: data.suffix(16))
        let plain = try ChaChaPoly.open(box, using: key, authenticating: ad)
        counter += 1
        return plain
    }
}

/// The Noise KK handshake (Noise_KK_25519_ChaChaPoly_SHA256): both sides already know each
/// other's public key from pairing. Two messages give mutual authentication and fresh keys
/// for every connection (forward secrecy), so a key stolen later can't open old traffic.
///
///     -> e, es, ss   (initiator: Capybara)
///     <- e, ee, se   (responder: Flamingo)
public struct LinkHandshake {
    static let protocolName = "Noise_KK_25519_ChaChaPoly_SHA256"

    public enum Role { case initiator, responder }

    let role: Role
    let local: LinkIdentity
    let remoteStatic: Curve25519.KeyAgreement.PublicKey
    var ephemeral = Curve25519.KeyAgreement.PrivateKey()
    var remoteEphemeral: Curve25519.KeyAgreement.PublicKey?
    var ck: Data
    var h: Data
    var k: SymmetricKey?
    var n: UInt64 = 0

    /// `prologue` binds what was said in the clear (versions and ids) into the keys.
    public init(role: Role, local: LinkIdentity, remoteStatic: Data, prologue: Data) throws {
        self.role = role
        self.local = local
        self.remoteStatic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteStatic)
        h = Data(Self.protocolName.utf8) + Data(repeating: 0, count: 32 - Self.protocolName.utf8.count)
        ck = h
        mixHash(prologue)
        // Pre-messages: the initiator's static key, then the responder's.
        switch role {
        case .initiator: mixHash(local.publicKey); mixHash(remoteStatic)
        case .responder: mixHash(remoteStatic); mixHash(local.publicKey)
        }
    }

    mutating func mixHash(_ data: Data) { h = Data(SHA256.hash(data: h + data)) }

    static func hkdf(_ chainingKey: Data, _ input: Data) -> (Data, Data) {
        let temp = Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: chainingKey)))
        let out1 = Data(HMAC<SHA256>.authenticationCode(for: Data([1]), using: SymmetricKey(data: temp)))
        let out2 = Data(HMAC<SHA256>.authenticationCode(for: out1 + Data([2]), using: SymmetricKey(data: temp)))
        return (out1, out2)
    }

    mutating func mixKey(_ dh: SharedSecret) {
        let input = dh.withUnsafeBytes { Data($0) }
        let (newCK, temp) = Self.hkdf(ck, input)
        ck = newCK
        k = SymmetricKey(data: temp)
        n = 0
    }

    mutating func encryptAndHash(_ plain: Data) throws -> Data {
        guard let k else { throw LinkError.handshake }
        let box = try ChaChaPoly.seal(plain, using: k, nonce: LinkCipher.nonce(n), authenticating: h)
        n += 1
        let out = Data(box.ciphertext + box.tag)
        mixHash(out)
        return out
    }

    mutating func decryptAndHash(_ data: Data) throws -> Data {
        guard let k, data.count >= 16 else { throw LinkError.handshake }
        let box = try ChaChaPoly.SealedBox(nonce: LinkCipher.nonce(n), ciphertext: data.dropLast(16), tag: data.suffix(16))
        let plain = try ChaChaPoly.open(box, using: k, authenticating: h)
        n += 1
        mixHash(data)
        return plain
    }

    func dh(_ a: Curve25519.KeyAgreement.PrivateKey, _ b: Curve25519.KeyAgreement.PublicKey) throws -> SharedSecret {
        try a.sharedSecretFromKeyAgreement(with: b)
    }

    /// Initiator: `e, es, ss` and an encrypted payload.
    public mutating func writeFirst(_ payload: Data) throws -> Data {
        let e = ephemeral.publicKey.rawRepresentation
        mixHash(e)
        mixKey(try dh(ephemeral, remoteStatic))
        mixKey(try dh(local.privateKey, remoteStatic))
        return e + (try encryptAndHash(payload))
    }

    /// Responder: reads the initiator's message, or throws if it wasn't made with the paired key.
    public mutating func readFirst(_ message: Data) throws -> Data {
        guard message.count >= 32 + 16 else { throw LinkError.handshake }
        let re = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: message.prefix(32))
        remoteEphemeral = re
        mixHash(re.rawRepresentation)
        mixKey(try dh(local.privateKey, re))
        mixKey(try dh(local.privateKey, remoteStatic))
        return try decryptAndHash(message.dropFirst(32))
    }

    /// Responder: `e, ee, se` and an encrypted payload.
    public mutating func writeSecond(_ payload: Data) throws -> Data {
        guard let re = remoteEphemeral else { throw LinkError.handshake }
        let e = ephemeral.publicKey.rawRepresentation
        mixHash(e)
        mixKey(try dh(ephemeral, re))
        mixKey(try dh(ephemeral, remoteStatic))
        return e + (try encryptAndHash(payload))
    }

    /// Initiator: reads the responder's answer, or throws if it wasn't the paired Mac.
    public mutating func readSecond(_ message: Data) throws -> Data {
        guard message.count >= 32 + 16 else { throw LinkError.handshake }
        let re = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: message.prefix(32))
        remoteEphemeral = re
        mixHash(re.rawRepresentation)
        mixKey(try dh(ephemeral, re))
        mixKey(try dh(local.privateKey, re))
        return try decryptAndHash(message.dropFirst(32))
    }

    /// After both messages: the sending and receiving ciphers.
    public func split() -> (send: LinkCipher, receive: LinkCipher) {
        let (a, b) = Self.hkdf(ck, Data())
        let i2r = LinkCipher(key: SymmetricKey(data: a)), r2i = LinkCipher(key: SymmetricKey(data: b))
        return role == .initiator ? (i2r, r2i) : (r2i, i2r)
    }

    /// The handshake hash: the same on both sides only if nothing was changed on the way.
    public var transcript: Data { h }
}

/// Pairing's six digits. Both Macs show them and you check they match: a device in between
/// would have to make both sides show the same number, and the commitment stops it from
/// trying keys until they do (the same scheme as Bluetooth's numeric comparison).
public enum LinkPairing {
    public static func nonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// What the responder commits to before it sees the initiator's nonce.
    public static func commitment(responderKey: Data, initiatorKey: Data, responderNonce: Data) -> Data {
        Data(SHA256.hash(data: Data("capyflamingo/pair/commit".utf8) + responderKey + initiatorKey + responderNonce))
    }

    /// `"482 913"`.
    public static func code(initiatorKey: Data, responderKey: Data, initiatorNonce: Data, responderNonce: Data) -> String {
        let digest = SHA256.hash(data: Data("capyflamingo/pair/code".utf8) + initiatorKey + responderKey + initiatorNonce + responderNonce)
        let value = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        let digits = String(format: "%06u", value)
        return digits.prefix(3) + " " + digits.suffix(3)
    }
}

public enum LinkError: Error, Equatable, Sendable {
    case badFrame, handshake, unpaired, timeout, closed, notConnected, refused(String)

    public var message: String {
        switch self {
        case .badFrame: return "The other Mac sent something unreadable"
        case .handshake: return "The other Mac couldn't prove it's the one you paired"
        case .unpaired: return "The other Mac doesn't know this one any more. Pair again."
        case .timeout: return "The other Mac didn't answer"
        case .closed, .notConnected: return "Not connected"
        case .refused(let why): return why
        }
    }
}
