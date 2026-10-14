import Foundation

/// Deterministic UUIDs derived from content. Comment ids are not stored in sidecars
/// (the format is plain Markdown that Obsidian can read), so the same line must map to
/// the same id every time it is parsed, in every process. Swift's `Hasher` is randomly
/// seeded per process, so this uses two FNV-1a passes with a Murmur3 finalizer instead.
enum StableID {
    static func uuid(from string: String) -> UUID {
        let bytes = Array(string.utf8)
        var a: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes { a ^= UInt64(b); a = a &* 0x0000_0100_0000_01b3 }
        var b: UInt64 = 0x84222325cbf29ce4 ^ 0x9E37_79B9_7F4A_7C15
        for byte in bytes.reversed() { b ^= UInt64(byte); b = b &* 0x0000_0100_0000_01b3 }
        a = fmix(a ^ UInt64(bytes.count))
        b = fmix(b ^ a)
        var raw = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { raw[i] = UInt8(truncatingIfNeeded: a >> (8 * UInt64(i))) }
        for i in 0..<8 { raw[8 + i] = UInt8(truncatingIfNeeded: b >> (8 * UInt64(i))) }
        raw[6] = (raw[6] & 0x0F) | 0x80   // version 8: custom
        raw[8] = (raw[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
                           raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]))
    }

    private static func fmix(_ x: UInt64) -> UInt64 {
        var k = x
        k ^= k >> 33; k = k &* 0xff51_afd7_ed55_8ccd
        k ^= k >> 33; k = k &* 0xc4ce_b9fe_1a85_ec53
        k ^= k >> 33
        return k
    }
}
