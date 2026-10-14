import Foundation
import AVFoundation
import FlamingoCore

/// Audio and video: AVFoundation metadata as text, one `.time` section per chapter.
/// `title` is the common-metadata title. Speech is not transcribed.
public struct MediaExtractor: Extractor {
    public static let extensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "wav", "aif", "aiff", "caf", "flac",
                                                 "mp4", "m4v", "mov", "3gp"]
    public init() {}

    public func extract(_ url: URL) throws -> Extracted {
        let info: Info?
        do { info = try AsyncBridge.wait { try await Self.load(url) } }
        catch { throw ExtractError.malformed(url.path) }
        guard let info else { throw ExtractError.malformed(url.path) }

        let sections = info.chapters.map { c in
            Section(anchor: FileAnchor(kind: .time, value: Self.timecode(c.start)), title: c.title, text: c.title ?? "")
        }
        let text = (info.lines + info.chapters.compactMap(\.title)).joined(separator: "\n")
        return Extracted(text: text, sections: sections, title: info.title)
    }

    /// `m:ss`, or `h:mm:ss` from one hour, seconds rounded down; the form `(time 1:23)` anchors use.
    static func timecode(_ seconds: Double) -> String {
        let t = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private struct Info: Sendable {
        var title: String?
        var lines: [String]
        var chapters: [(start: Double, title: String?)]
    }

    /// Common keys in text order, then the format-specific comment and lyrics items.
    private static let commonKeys: [AVMetadataKey] = [.commonKeyTitle, .commonKeyArtist, .commonKeyAuthor,
                                                      .commonKeyAlbumName, .commonKeyDescription]
    private static let extraIdentifiers: [AVMetadataIdentifier] = [
        .iTunesMetadataUserComment, .id3MetadataComments, .quickTimeMetadataComment, .quickTimeUserDataComment,
        .iTunesMetadataLyrics, .id3MetadataUnsynchronizedLyric,
    ]

    /// nil when the asset opens but has nothing AVFoundation can play or read.
    private static func load(_ url: URL) async throws -> Info? {
        let asset = AVURLAsset(url: url)
        let (duration, playable, readable, common, all, locales) = try await asset.load(
            .duration, .isPlayable, .isReadable, .commonMetadata, .metadata, .availableChapterLocales)
        guard playable || readable, duration.isNumeric else { return nil }

        var title: String?
        var lines: [String] = []
        for key in commonKeys {
            let values = try await strings(AVMetadataItem.metadataItems(from: common, withKey: key, keySpace: .common))
            if key == .commonKeyTitle { title = values.first }
            lines += values
        }
        for id in extraIdentifiers {
            lines += try await strings(AVMetadataItem.metadataItems(from: all, filteredByIdentifier: id))
        }

        var chapters: [(start: Double, title: String?)] = []
        if !locales.isEmpty {
            let groups = try await asset.loadChapterMetadataGroups(
                bestMatchingPreferredLanguages: Locale.preferredLanguages + locales.map(\.identifier))
            for g in groups {
                let names = try await strings(AVMetadataItem.metadataItems(from: g.items, filteredByIdentifier: .commonIdentifierTitle))
                chapters.append((g.timeRange.start.seconds, names.first))
            }
        }
        return Info(title: title, lines: lines.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }, chapters: chapters)
    }

    /// Trimmed, non-empty string values. iTunes stores normalisation, gapless and CDDB data as
    /// ID3 comments described `iTunNORM`, `iTunSMPB`, `iTunes_CDDB_IDs`…; those are dropped.
    private static func strings(_ items: [AVMetadataItem]) async throws -> [String] {
        var out: [String] = []
        for item in items {
            let (value, attributes) = try await item.load(.stringValue, .extraAttributes)
            if (attributes?[.info] as? String)?.hasPrefix("iTun") == true { continue }
            guard let s = value?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)), !s.isEmpty else { continue }
            out.append(s)
        }
        return out
    }
}
