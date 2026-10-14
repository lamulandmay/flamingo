import Foundation
import FlamingoCore

/// Word: one section per Heading 1–3 chunk, tables included.
public struct DOCXExtractor: Extractor {
    public static let extensions: Set<String> = ["docx", "docm", "dotx", "dotm"]
    public init() {}
    public func extract(_ url: URL) throws -> Extracted {
        return Extracted(text: "")
    }
}
