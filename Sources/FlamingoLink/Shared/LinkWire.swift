// Shared by Capybara and Flamingo. Capybara's Sources/CapybaraLink is the original; Flamingo's
// Sources/FlamingoLink/Shared is a copy (scripts/sync-link.sh). Change it here, then sync.

import Foundation

/// What travels between the Macs: a JSON object with a `t` (its type), an `id` when it wants an
/// answer or must arrive exactly once, and `re` on an answer.
public typealias LinkBody = [String: Any]

/// The bytes on the wire. Every frame is a 4-byte big-endian length and that many bytes.
/// Before the handshake a frame's first byte says what it is; after it, every frame is
/// ciphertext, and its plaintext's first byte says whether the JSON is compressed.
public enum LinkWire {
    /// Service type for Bonjour. Both Info.plists list it under NSBonjourServices.
    public static let serviceType = "_capyflamingo._tcp"
    public static let version = 1
    /// A whole folder list fits easily; anything bigger is a mistake or an attack.
    public static let maxFrame = 64 << 20

    public enum Kind: UInt8 {
        /// Pairing, in the clear: only public keys, nonces and names.
        case pair = 1
        /// The handshake's two messages.
        case hello = 2, helloBack = 3
        /// "I don't know you" or "busy", in the clear, then the connection closes.
        case refuse = 4
    }

    public static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        return Data(bytes: &length, count: 4) + payload
    }

    public static func plain(_ kind: Kind, _ payload: Data) -> Data { frame(Data([kind.rawValue]) + payload) }

    /// Splits complete frames off the front of `buffer`. Throws on a frame over `maxFrame`.
    public static func takeFrames(_ buffer: inout Data) throws -> [Data] {
        var out: [Data] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = buffer[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length <= maxFrame else { throw LinkError.badFrame }
            guard buffer.count >= 4 + length else { break }
            out.append(Data(buffer[start + 4..<start + 4 + length]))
            buffer = Data(buffer[(start + 4 + length)...])
        }
        return out
    }

    // MARK: JSON

    public static func json(_ body: LinkBody) -> Data {
        (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data("{}".utf8)
    }

    public static func object(_ data: Data) -> LinkBody? {
        (try? JSONSerialization.jsonObject(with: data)) as? LinkBody
    }

    /// Plaintext for one encrypted frame: big messages (a folder list) go compressed.
    public static func pack(_ body: LinkBody) -> Data {
        let json = json(body)
        if json.count > 16 << 10, let small = try? (json as NSData).compressed(using: .lzfse) as Data, small.count < json.count {
            return Data([1]) + small
        }
        return Data([0]) + json
    }

    public static func unpack(_ data: Data) throws -> LinkBody {
        guard let flag = data.first else { throw LinkError.badFrame }
        let rest = data.dropFirst()
        let json: Data
        switch flag {
        case 0: json = Data(rest)
        case 1:
            guard let big = try? (Data(rest) as NSData).decompressed(using: .lzfse) as Data else { throw LinkError.badFrame }
            json = big
        default: throw LinkError.badFrame
        }
        guard let body = object(json) else { throw LinkError.badFrame }
        return body
    }

    /// Milliseconds since 1970, the clock both sides speak in.
    public static func now() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }

    public static func newID() -> String { UUID().uuidString.lowercased() }
}

/// Typed reads from a `LinkBody`, so call sites stay short.
public extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func double(_ key: String) -> Double? { (self[key] as? Double) ?? (self[key] as? Int).map(Double.init) ?? (self[key] as? NSNumber)?.doubleValue }
    func int(_ key: String) -> Int? { (self[key] as? Int) ?? (self[key] as? Double).map { Int($0) } }
    func bool(_ key: String) -> Bool? { self[key] as? Bool }
    func body(_ key: String) -> LinkBody? { self[key] as? LinkBody }
    func bodies(_ key: String) -> [LinkBody] { (self[key] as? [Any])?.compactMap { $0 as? LinkBody } ?? [] }
    func strings(_ key: String) -> [String] { (self[key] as? [Any])?.compactMap { $0 as? String } ?? [] }
    func data(_ key: String) -> Data? { string(key).flatMap { Data(base64Encoded: $0) } }
}
