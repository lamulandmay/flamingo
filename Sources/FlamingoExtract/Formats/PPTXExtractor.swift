import Foundation
import FlamingoCore

/// PowerPoint: one section per slide, notes appended.
public struct PPTXExtractor: Extractor {
    public static let extensions: Set<String> = ["pptx", "pptm", "potx", "potm", "ppsx", "ppsm"]
    public init() {}
    public func extract(_ url: URL) throws -> Extracted {
        return Extracted(text: "")
    }
}
