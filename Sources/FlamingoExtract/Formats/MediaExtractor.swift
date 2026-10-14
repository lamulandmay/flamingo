import Foundation
import FlamingoCore

/// Audio and video: AVFoundation metadata, chapters as time sections.
public struct MediaExtractor: Extractor {
    public static let extensions: Set<String> = ["mp3", "m4a", "mp4", "mov"]
    public init() {}
    public func extract(_ url: URL) throws -> Extracted {
        return Extracted(text: "")
    }
}
