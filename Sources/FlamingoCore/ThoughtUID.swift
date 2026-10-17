import Foundation

/// The stable identity of a thought: `t` plus nine Crockford base32 characters (45 bits).
/// Unlike the derived `Comment.id`, it does not change when the text is edited, so threads,
/// the work ledger and the briefing refer to thoughts by uid.
public enum ThoughtUID {
    static let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")
    public static let length = 10

    public static func generate<G: RandomNumberGenerator>(using generator: inout G) -> String {
        var out = "t"
        for _ in 0..<(length - 1) { out.append(alphabet[Int(generator.next() % 32)]) }
        return out
    }

    public static func generate() -> String {
        var g = SystemRandomNumberGenerator()
        return generate(using: &g)
    }

    /// Whether `value` looks like a uid this build wrote. Other spellings are still accepted
    /// from disk (a person may hand-write one); this is for validating generated values.
    public static func isWellFormed(_ value: String) -> Bool {
        value.count == length && value.first == "t" && value.dropFirst().allSatisfy { alphabet.contains($0) }
    }
}
