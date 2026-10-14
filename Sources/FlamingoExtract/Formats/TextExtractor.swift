import Foundation
import FlamingoCore

/// Plain text, Markdown, code, HTML, RTF.
public struct TextExtractor: Extractor {
    public static let extensions: Set<String> = ["txt", "md", "markdown"]
    public init() {}
    public func extract(_ url: URL) throws -> Extracted {
        return Extracted(text: "")
    }
}
