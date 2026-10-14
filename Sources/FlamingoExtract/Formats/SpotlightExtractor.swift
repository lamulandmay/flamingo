import Foundation
import FlamingoCore

/// Fallback: `mdimport -d2` / `mdls` text content. Plan 04 owns.
public struct SpotlightExtractor: Extractor {
    public static let extensions: Set<String> = []
    public init() {}
    public func extract(_ url: URL) throws -> Extracted {
        return Extracted(text: "")
    }
}
