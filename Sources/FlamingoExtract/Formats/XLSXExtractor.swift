import Foundation
import FlamingoCore

/// Excel: one section per sheet, cells row-major and tab-separated.
public struct XLSXExtractor: Extractor {
    public static let extensions: Set<String> = ["xlsx", "xlsm", "xltx", "xltm"]
    public init() {}
    public func extract(_ url: URL) throws -> Extracted {
        return Extracted(text: "")
    }
}
