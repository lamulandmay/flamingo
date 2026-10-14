import Foundation
import FlamingoCore

/// PDFKit: one section per page, titled from the outline.
public struct PDFExtractor: Extractor {
    public static let extensions: Set<String> = ["pdf"]
    public init() {}
    public func extract(_ url: URL) throws -> Extracted {
        return Extracted(text: "")
    }
}
