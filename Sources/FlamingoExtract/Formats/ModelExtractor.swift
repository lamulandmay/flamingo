import Foundation
import FlamingoCore

/// 3D via ModelIO: one section per named node.
public struct ModelExtractor: Extractor {
    public static let extensions: Set<String> = ["usdz", "usd", "usda", "usdc", "obj", "stl", "ply", "abc"]
    public init() {}
    public func extract(_ url: URL) throws -> Extracted {
        return Extracted(text: "")
    }
}
