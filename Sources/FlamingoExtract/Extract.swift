import Foundation
import UniformTypeIdentifiers
import FlamingoCore

/// One addressable unit inside a file: a slide, page, sheet, etc.
public struct Section: Codable, Sendable, Equatable {
    public var anchor: FileAnchor
    public var title: String?
    public var text: String
    public init(anchor: FileAnchor, title: String? = nil, text: String) { self.anchor = anchor; self.title = title; self.text = text }
}

/// Search can distinguish a complete read from a bounded or unsuccessful one.
public struct ExtractionCoverage: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case complete, partial, failed, unsupported, metadataOnly }
    public var state: State
    public var reason: String?
    public var processedUnits: Int?
    public var totalUnits: Int?
    public init(_ state: State = .complete, reason: String? = nil, processedUnits: Int? = nil, totalUnits: Int? = nil) {
        self.state = state; self.reason = reason; self.processedUnits = processedUnits; self.totalUnits = totalUnits
    }
}

public struct Extracted: Codable, Sendable, Equatable {
    public var text: String            // full text, for FTS
    public var sections: [Section]     // structure, for deep anchors
    public var title: String?
    public var coverage = ExtractionCoverage()
    public init(text: String, sections: [Section] = [], title: String? = nil) { self.text = text; self.sections = sections; self.title = title }

    /// Full text is the sections' text joined by blank lines.
    public init(sections: [Section], title: String? = nil) {
        self.init(text: sections.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n"),
                  sections: sections, title: title)
    }

    private enum CodingKeys: String, CodingKey { case text, sections, title, coverage }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        sections = try c.decode([Section].self, forKey: .sections)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        coverage = try c.decodeIfPresent(ExtractionCoverage.self, forKey: .coverage) ?? ExtractionCoverage()
    }

    public static let empty = Extracted(text: "")
    public var isEmpty: Bool { text.isEmpty && sections.isEmpty && title == nil }
}

public protocol Extractor: Sendable {
    /// Lowercased extensions this extractor handles.
    static var extensions: Set<String> { get }
    /// A requirement so `Extract` can construct the concrete type through `any Extractor.Type`.
    init()
    func extract(_ url: URL) throws -> Extracted
}

// Kept from the frozen stub. Now that `init()` is a requirement, a conformer's own `init()`
// is what `Extract` calls; this default only catches conformers that forgot one.
extension Extractor { public init() { fatalError("Extractors must provide init()") } }

public enum ExtractError: Error, Equatable {
    /// The file is missing or can't be opened.
    case unreadable(String)
    /// The file opened but isn't what its extension claims.
    case malformed(String)
}

/// Entry point. Picks a format extractor, falls back to Spotlight metadata. Plan 04 owns.
///
/// `extract` is synchronous and may take a while for big files; call it off the main thread,
/// or use `extractInBackground`. It throws only when the file can't be read at all. Formats
/// nobody handles come back as empty text.
public enum Extract {
    public static var extractors: [any Extractor.Type] {
        get { registry.withLock { $0 } }
        set { registry.withLock { $0 = newValue } }
    }

    /// The built-in extractors, in priority order.
    public static let defaults: [any Extractor.Type] = [
        PPTXExtractor.self, DOCXExtractor.self, XLSXExtractor.self,
        PDFExtractor.self, IWorkExtractor.self, TextExtractor.self,
        ImageExtractor.self, MediaExtractor.self, ModelExtractor.self, GLTFExtractor.self,
    ]

    /// Appends every built-in extractor not already registered. Idempotent; extractors
    /// registered earlier keep priority. `extract` calls this on first use.
    public static func registerDefaults() {
        registry.withLock { list in
            for e in defaults where !list.contains(where: { $0 == e }) { list.append(e) }
        }
    }

    /// Bumped whenever any extractor's output changes, so the index knows to re-extract
    /// files whose mtime and size haven't moved. 0 was the stubs.
    public static let version = 2

    /// Text is cut here so one pathological file can't bloat the index.
    public static let maxTextLength = 2_000_000

    public static func extract(_ url: URL) throws -> Extracted {
        _ = registeredOnce
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isReadableKey, .contentTypeKey])
        guard FileManager.default.fileExists(atPath: url.path), values?.isReadable != false else {
            throw ExtractError.unreadable(url.path)
        }
        if values?.isDirectory == true, values?.isPackage != true, !isPackageExtension(url) { return .empty }

        let ext = url.pathExtension.lowercased()
        if let e = extractors.first(where: { $0.extensions.contains(ext) }) {
            do { return capped(try e.init().extract(url)) }
            // A native parser that fails (encrypted, legacy, truncated) still gets Spotlight's view.
            catch {
                var fallback = (try? SpotlightExtractor().extract(url)) ?? .empty
                fallback.coverage = ExtractionCoverage(fallback.isEmpty ? .failed : .partial,
                    reason: fallback.isEmpty ? "Could not extract this file: \(error)" : "Native parser failed; Spotlight fallback may omit content.")
                return capped(fallback)
            }
        }
        if values?.isDirectory != true, TextSniffer.looksLikeText(url) {
            do { return capped(try TextExtractor().extract(url)) }
            catch {
                var out = Extracted.empty
                out.coverage = ExtractionCoverage(.failed, reason: "Could not read detected text: \(error)")
                return out
            }
        }
        if let type = values?.contentType, !worthAskingSpotlight(type) {
            var out = Extracted.empty
            out.coverage = ExtractionCoverage(.unsupported, reason: "This format is indexed by filename only.")
            return out
        }
        var out = (try? SpotlightExtractor().extract(url)) ?? .empty
        if out.isEmpty { out.coverage = ExtractionCoverage(.unsupported, reason: "No text importer is available for this file.") }
        return capped(out)
    }

    /// Runs `extract` on a background queue so the calling task's thread is never blocked.
    /// A task cancelled before its turn comes skips the work (`CancellationError`), so moving
    /// through palette results or files quickly doesn't leave a queue of whole-file
    /// extractions running behind the one on screen.
    public static func extractInBackground(_ url: URL) async throws -> Extracted {
        let cancelled = Locked(false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                queue.async {
                    if cancelled.withLock({ $0 }) { cont.resume(throwing: CancellationError()); return }
                    cont.resume(with: Result { try extract(url) })
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    // MARK: -

    private static let registry = Locked<[any Extractor.Type]>([])
    private static let registeredOnce: Void = registerDefaults()
    private static let queue = DispatchQueue(label: "flamingo.extract", qos: .utility, attributes: .concurrent)

    private static func isPackageExtension(_ url: URL) -> Bool {
        IWorkExtractor.extensions.contains(url.pathExtension.lowercased())
    }

    /// Archives, disk images, executables, and other packages have no importer worth spawning `mdimport` for.
    private static func worthAskingSpotlight(_ type: UTType) -> Bool {
        let skip: [UTType] = [.archive, .diskImage, .executable, .application, .applicationBundle,
                              .bundle, .package, .framework, .database, .font]
        return !skip.contains { type.conforms(to: $0) }
    }

    static func capped(_ e: Extracted) -> Extracted {
        guard e.text.utf8.count > maxTextLength else { return e }
        var out = e
        out.text = String(decoding: e.text.utf8.prefix(maxTextLength), as: UTF8.self)
        out.coverage = ExtractionCoverage(.partial, reason: "Extracted text exceeded the text budget.",
                                         processedUnits: e.coverage.processedUnits, totalUnits: e.coverage.totalUnits)
        return out
    }
}
