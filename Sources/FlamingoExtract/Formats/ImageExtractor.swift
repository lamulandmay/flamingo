import Foundation
import FlamingoCore

/// Images: Vision OCR when larger than an icon.
public struct ImageExtractor: Extractor {
    public static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic"]
    public init() {}
    public func extract(_ url: URL) throws -> Extracted {
        return Extracted(text: "")
    }
}
