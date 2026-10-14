import Foundation
import FlamingoCore

/// glTF, which ModelIO can't read: nodes, meshes, materials from the JSON chunk.
public struct GLTFExtractor: Extractor {
    public static let extensions: Set<String> = ["glb", "gltf"]
    public init() {}
    public func extract(_ url: URL) throws -> Extracted {
        return Extracted(text: "")
    }
}
