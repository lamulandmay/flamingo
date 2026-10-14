import Foundation
import FlamingoCore

/// One addressable unit inside a file: a slide, page, sheet, etc.
public struct Section: Codable, Sendable, Equatable {
    public var anchor: FileAnchor
    public var title: String?
    public var text: String
    public init(anchor: FileAnchor, title: String? = nil, text: String) { self.anchor = anchor; self.title = title; self.text = text }
}

public struct Extracted: Codable, Sendable, Equatable {
    public var text: String            // full text, for FTS
    public var sections: [Section]     // structure, for deep anchors
    public var title: String?
    public init(text: String, sections: [Section] = [], title: String? = nil) { self.text = text; self.sections = sections; self.title = title }
}

public protocol Extractor: Sendable {
    /// Lowercased extensions this extractor handles.
    static var extensions: Set<String> { get }
    func extract(_ url: URL) throws -> Extracted
}

/// Entry point. Picks a format extractor, falls back to Spotlight metadata. Plan 04 owns.
public enum Extract {
    public static var extractors: [any Extractor.Type] = [] // plan 04 registers here

    public static func extract(_ url: URL) throws -> Extracted {
        let ext = url.pathExtension.lowercased()
        if let e = extractors.first(where: { $0.extensions.contains(ext) }) {
            return try e.init().extract(url)
        }
        return try SpotlightExtractor().extract(url)
    }
}

extension Extractor { public init() { fatalError("Extractors must provide init()") } }

/// Fallback: `mdimport -d2` / `mdls` text content. Plan 04 owns.
public struct SpotlightExtractor: Extractor {
    public static let extensions: Set<String> = []
    public init() {}
    public func extract(_ url: URL) throws -> Extracted {
        // TODO(plan 04)
        return Extracted(text: "")
    }
}
