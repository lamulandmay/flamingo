import Foundation
import FlamingoCore

/// Keynote, Pages, Numbers: text from Spotlight, never from IWA. Each may be a package directory
/// or a single zip file. Keynote decks also get one empty `.slide` section per slide, counted
/// from member names: Keynote stores every slide as its own `Index/Slide-<id>.iwa` (masters are
/// `TemplateSlide-*.iwa`). The `Data/st-*` thumbnails are no use for this; stale ones linger.
public struct IWorkExtractor: Extractor {
    public static let extensions: Set<String> = ["key", "pages", "numbers"]
    public init() {}

    public func extract(_ url: URL) throws -> Extracted {
        var e = try SpotlightExtractor().extract(url)
        if url.pathExtension.lowercased() == "key" {
            e.sections = (0..<Self.slideCount(url)).map {
                Section(anchor: FileAnchor(kind: .slide, value: String($0 + 1)), text: "")
            }
        }
        return e
    }

    /// Slide IWA members in a single-file deck, a package's `Index/` folder, or an older
    /// package's `Index.zip`. Zero for anything else, including `.key` files that aren't decks.
    static func slideCount(_ url: URL) -> Int {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        let names: [String]
        if !isDirectory.boolValue {
            names = (try? ZipArchive(url))?.names ?? []
        } else if let index = try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("Index").path) {
            names = index.map { "Index/" + $0 }
        } else {
            names = (try? ZipArchive(url.appendingPathComponent("Index.zip")))?.names ?? []
        }
        return names.filter { $0.wholeMatch(of: #/Index/Slide(-[^/]*)?\.iwa/#) != nil }.count
    }
}
