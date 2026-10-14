import Foundation
import AppKit
import CryptoKit
import ImageIO
@preconcurrency import QuickLookThumbnailing
import UniformTypeIdentifiers
import FlamingoCore

/// Quick Look thumbnails, cached as PNGs in `<vault>/.flamingo/thumbs/`. Plan 04 owns.
///
/// One PNG per file version, named by the hex SHA-256 of the vault-relative path, a newline, and
/// the mtime in seconds since 1970 as Swift prints a `Double` (`stat`'s `tv_sec + tv_nsec / 1e9`,
/// the stamp the index stores). The name has no size: a request needing more pixels than the PNG
/// holds regenerates it larger and overwrites it. Files outside any vault are cached in memory
/// only. Concurrent requests for the same file and size share one generation. Only real
/// thumbnails come back, never the file's icon: nil means the file is missing or Quick Look has
/// nothing to show, so draw a glyph.
public enum Thumbnails {
    /// A thumbnail for `url`, cached in its vault: the nearest ancestor folder holding a
    /// `.flamingo` directory. The image's `size` is `size` aspect-fit to the content.
    public static func thumbnail(for url: URL, size: CGSize, scale: CGFloat = 2) async -> NSImage? {
        await image(for: url, vault: enclosingVault(of: url), size: size, scale: scale)
    }

    /// A thumbnail for `url`, cached in `vault`'s `.flamingo/thumbs/` (created on demand).
    public static func thumbnail(for url: URL, in vault: Vault, size: CGSize, scale: CGFloat = 2) async -> NSImage? {
        await image(for: url, vault: vault, size: size, scale: scale)
    }

    /// The cached PNG for `url` in its vault, if there is one for the file's current mtime.
    public static func cachedURL(for url: URL) -> URL? {
        enclosingVault(of: url).flatMap { cachedURL(for: url, in: $0) }
    }

    public static func cachedURL(for url: URL, in vault: Vault) -> URL? {
        guard let mtime = modificationTime(of: url), let png = pngURL(for: url, in: vault, mtime: mtime),
              FileManager.default.fileExists(atPath: png.path) else { return nil }
        return png
    }

    /// Deletes cached PNGs that no longer match a file's current path and mtime (files edited,
    /// renamed, or removed since), keeping the rest. `files` defaults to a fresh scan. Call it
    /// after a reindex. Returns how many were deleted.
    @discardableResult
    public static func pruneCache(in vault: Vault, files: [FileRef]? = nil) -> Int {
        let dir = vault.stateDir.appendingPathComponent("thumbs", isDirectory: true)
        guard let cached = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        let keep = Set((files ?? VaultScanner.files(in: vault)).compactMap { ref -> String? in
            let url = vault.url(for: ref)
            return modificationTime(of: url).flatMap { pngURL(for: url, in: vault, mtime: $0) }?.lastPathComponent
        })
        var removed = 0
        for name in cached where name.hasSuffix(".png") && !keep.contains(name) {
            if (try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: -

    /// A size in pixels.
    struct Box: Hashable, CustomStringConvertible {
        var width: Int, height: Int
        init(width: Int, height: Int) { self.width = width; self.height = height }
        /// Parses `description`.
        init?(_ s: String) {
            let p = s.split(separator: "x").compactMap { Int($0) }
            guard p.count == 2 else { return nil }
            self.init(width: p[0], height: p[1])
        }
        var description: String { "\(width)x\(height)" }
        var size: CGSize { CGSize(width: width, height: height) }
        func covers(_ b: Box) -> Bool { width >= b.width && height >= b.height }
        func union(_ b: Box) -> Box { Box(width: max(width, b.width), height: max(height, b.height)) }
    }

    /// A cached thumbnail and the box it was generated for. The box can exceed the pixels
    /// because Quick Look doesn't upscale small sources; recording it stops every larger
    /// request from regenerating them.
    private struct Cached {
        let pixels: Box, box: Box
        let decode: (_ longestSide: Int) -> CGImage?

        /// The image for a request of `need` pixels, or nil if this one is too small for it.
        func image(for need: Box) -> CGImage? {
            let fitted = fit(pixels.size, in: need.size)
            let side = max(fitted.width, fitted.height)
            guard box.covers(need) || side <= CGFloat(max(pixels.width, pixels.height)) + 1 else { return nil }
            return decode(Int(side.rounded(.up)))
        }
    }

    /// Where one version of a file's thumbnail lives: a PNG in a vault, or memory outside one.
    private enum Slot: CustomStringConvertible {
        case disk(URL)
        case memory(String)
        var description: String {
            switch self {
            case .disk(let png): return png.path
            case .memory(let key): return "memory:" + key
            }
        }
    }

    /// A thumbnail of a file outside any vault.
    private final class Entry {
        let image: CGImage, box: Box
        init(image: CGImage, box: Box) { self.image = image; self.box = box }
    }

    // NSCache is thread-safe.
    nonisolated(unsafe) private static let memory: NSCache<NSString, Entry> = {
        let c = NSCache<NSString, Entry>()
        c.countLimit = 200
        return c
    }()
    private static let inFlight = Locked<[String: Task<CGImage?, Never>]>([:])
    private static let vaults = Locked<[String: Vault]>([:])

    private static func image(for url: URL, vault: Vault?, size: CGSize, scale: CGFloat) async -> NSImage? {
        guard size.width > 0, size.height > 0, scale > 0, let mtime = modificationTime(of: url) else { return nil }
        let need = Box(width: Int((size.width * scale).rounded(.up)), height: Int((size.height * scale).rounded(.up)))
        let slot = vault.flatMap { pngURL(for: url, in: $0, mtime: mtime) }.map(Slot.disk)
            ?? .memory(url.standardizedFileURL.path + "\n\(mtime)")
        guard let image = await coalesced("\(slot)|\(need)", { await load(url, slot: slot, need: need, scale: scale) })
        else { return nil }
        return NSImage(cgImage: image, size: fit(CGSize(width: image.width, height: image.height), in: size))
    }

    /// Runs `work` once for all concurrent callers asking for the same `key`.
    private static func coalesced(_ key: String, _ work: @escaping @Sendable () async -> CGImage?) async -> CGImage? {
        let task = inFlight.withLock { tasks in
            if let t = tasks[key] { return t }
            // Inserted under the lock the task takes to remove itself, so removal can't come first.
            let t = Task.detached {
                let image = await work()
                inFlight.withLock { $0[key] = nil }
                return image
            }
            tasks[key] = t
            return t
        }
        return await task.value
    }

    private static func load(_ url: URL, slot: Slot, need: Box, scale: CGFloat) async -> CGImage? {
        let cached = read(slot)
        if let image = cached?.image(for: need) { return image }
        let target = cached.map { $0.box.union(need) } ?? need
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: CGFloat(target.width) / scale, height: CGFloat(target.height) / scale),
            scale: scale, representationTypes: .thumbnail)
        guard let image = await generate(request) else { return nil }
        store(image, box: target, in: slot)
        return image
    }

    /// Quick Look's thumbnail, or nil if it fails or hasn't answered within `timeout`, in which case
    /// the request is cancelled. Not a task group: that would wait for a generator that never returns.
    static func generate(_ request: QLThumbnailGenerator.Request, timeout: TimeInterval = 10) async -> CGImage? {
        let pending = Locked<CheckedContinuation<CGImage?, Never>?>(nil)
        @Sendable func finish(_ image: CGImage?) {
            pending.withLock { c in defer { c = nil }; return c }?.resume(returning: image)
        }
        return await withCheckedContinuation { cont in
            pending.withLock { $0 = cont }
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in finish(rep?.cgImage) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                finish(nil)
                QLThumbnailGenerator.shared.cancel(request)
            }
        }
    }

    private static func read(_ slot: Slot) -> Cached? {
        switch slot {
        case .memory(let key):
            guard let e = memory.object(forKey: key as NSString) else { return nil }
            return Cached(pixels: Box(width: e.image.width, height: e.image.height), box: e.box) { _ in e.image }
        case .disk(let png):
            guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
            else { return nil }
            let pixels = Box(width: w, height: h)
            let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any]
            let box = (png?[kCGImagePropertyPNGDescription] as? String).flatMap(Box.init) ?? pixels
            // Decoded at the size asked for, so a row of small thumbnails doesn't hold big bitmaps.
            return Cached(pixels: pixels, box: box) { side in
                CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: side,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
            }
        }
    }

    /// Saves `image`, generated for `box`, unless a concurrent request already saved a bigger one.
    /// PNGs record their box in the Description text chunk.
    private static func store(_ image: CGImage, box: Box, in slot: Slot) {
        if let existing = read(slot), existing.box.covers(box) { return }
        switch slot {
        case .memory(let key):
            memory.setObject(Entry(image: image, box: box), forKey: key as NSString)
        case .disk(let png):
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return }
            let props = [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: box.description]]
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return }
            try? FileManager.default.createDirectory(at: png.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? (data as Data).write(to: png, options: .atomic)
        }
    }

    private static func pngURL(for url: URL, in vault: Vault, mtime: TimeInterval) -> URL? {
        guard let rel = vault.relativePath(of: url), !rel.isEmpty else { return nil }
        let hex = SHA256.hash(data: Data("\(rel)\n\(mtime)".utf8)).map { String(format: "%02x", $0) }.joined()
        return vault.stateDir.appendingPathComponent("thumbs", isDirectory: true).appendingPathComponent(hex + ".png")
    }

    /// Same formula as the index's stamp, following symlinks; nil if the file doesn't exist.
    private static func modificationTime(of url: URL) -> TimeInterval? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
    }

    /// The vault rooted at the nearest ancestor of `url` holding a `.flamingo` directory. Hits are
    /// memoized per parent folder; misses aren't, since a folder becomes a vault when first opened.
    static func enclosingVault(of url: URL) -> Vault? {
        let parent = (url.standardizedFileURL.path as NSString).deletingLastPathComponent
        if let v = vaults.withLock({ $0[parent] }) { return v }
        var dir = parent
        while !dir.isEmpty {
            var isDir: ObjCBool = false
            let state = (dir as NSString).appendingPathComponent(".flamingo")
            if FileManager.default.fileExists(atPath: state, isDirectory: &isDir), isDir.boolValue {
                let v = Vault(root: URL(fileURLWithPath: dir, isDirectory: true))
                vaults.withLock { $0[parent] = v }
                return v
            }
            if dir == "/" { break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// `content`'s aspect ratio, scaled to fit inside `box`.
    static func fit(_ content: CGSize, in box: CGSize) -> CGSize {
        guard content.width > 0, content.height > 0 else { return box }
        let s = min(box.width / content.width, box.height / content.height)
        return CGSize(width: content.width * s, height: content.height * s)
    }
}
