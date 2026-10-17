import Foundation

/// A JSON value, so metadata keys this build does not know survive a read and write
/// (a newer Flamingo may add keys; an older one must not drop them from a note it rewrites).
/// Internal: the public surface is `ThoughtMeta`.
enum MetaJSON: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([MetaJSON])
    case object([String: MetaJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([MetaJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: MetaJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }

    /// `{"a":1}` text as an object, nil for anything else (including malformed JSON).
    static func parseObject(_ text: String) -> [String: MetaJSON]? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(MetaJSON.self, from: data),
              case .object(let object) = value else { return nil }
        return object
    }

    /// Sorted-key JSON with `>` escaped, so `-->` can never occur inside an HTML comment.
    static func render(_ object: [String: MetaJSON]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(MetaJSON.object(object))).flatMap { String(data: $0, encoding: .utf8) }?
            .replacingOccurrences(of: ">", with: "\\u003e")
    }

    /// Round trips a Codable value through JSON into a key/value dictionary.
    static func object<T: Encodable>(from value: T) -> [String: MetaJSON]? {
        guard let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONDecoder().decode(MetaJSON.self, from: data),
              case .object(let o) = decoded else { return nil }
        return o
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: MetaJSON) -> T? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
