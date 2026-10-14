import AppKit
import QuickLookThumbnailing

/// Quick Look thumbnails for the chain. FlamingoTrail can't depend on FlamingoExtract, so this
/// is a small cache of its own. Files without a real thumbnail return nil and get a glyph.
@MainActor
final class TrailThumbnails {
    static let shared = TrailThumbnails()

    private let cache = NSCache<NSString, NSImage>()
    private var missing = Set<String>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    private init() { cache.countLimit = 400 }

    // `missing` only grows by one entry per failed (file, version); trim it if it gets large.
    private func noteMissing(_ k: String) {
        if missing.count > 2000 { missing.removeAll() }
        missing.insert(k)
    }

    func cached(_ url: URL, side: CGFloat) -> NSImage? {
        cache.object(forKey: key(url, side) as NSString)
    }

    func image(for url: URL, side: CGFloat, scale: CGFloat) async -> NSImage? {
        let k = key(url, side)
        if let img = cache.object(forKey: k as NSString) { return img }
        if missing.contains(k) { return nil }
        if let t = inFlight[k] { return await t.value }

        let task = Task<NSImage?, Never> {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                       scale: scale, representationTypes: .thumbnail)
            guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
                return nil
            }
            return rep.nsImage
        }
        inFlight[k] = task
        let img = await task.value
        inFlight[k] = nil
        if let img { cache.setObject(img, forKey: k as NSString) } else { noteMissing(k) }
        return img
    }

    /// Includes the modification date, so an edited file gets a fresh thumbnail and a file
    /// that failed once (still being written, say) is tried again once it changes.
    private func key(_ url: URL, _ side: CGFloat) -> String {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(Int(side))|\(modified?.timeIntervalSinceReferenceDate ?? 0)|\(url.path)"
    }
}
