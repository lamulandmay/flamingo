import Foundation
import FlamingoCore

/// Keynote, Pages, Numbers: text from Spotlight, never from IWA.
public struct IWorkExtractor: Extractor {
    public static let extensions: Set<String> = ["key", "pages", "numbers"]
    public init() {}
    public func extract(_ url: URL) throws -> Extracted {
        return Extracted(text: "")
    }
}
