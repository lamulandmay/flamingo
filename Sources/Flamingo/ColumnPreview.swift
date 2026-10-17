import AppKit
import SwiftUI
import QuickLookThumbnailing
import FlamingoDesign

/// The column after a selected file, as in Finder: a large preview, the name, what it is
/// and how big, its dates, and how many thoughts it holds. Double-click the preview to open.
struct ColumnPreview: View {
    let url: URL
    let name: String
    let thoughts: Int
    let onOpen: () -> Void

    @State private var image: NSImage?
    @State private var isThumbnail = false
    @State private var info: Info?

    struct Info: Equatable {
        var kind: String?
        var size: String?
        var created: Date?
        var modified: Date?
        var opened: Date?
        var version: String?
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width - Theme.Space.xl * 2, max(96, geo.size.height * 0.42), 360)
            ScrollView {
                VStack(spacing: Theme.Space.m) {
                    picture
                        .frame(width: max(0, side), height: max(0, side))
                        .onTapGesture(count: 2, perform: onOpen)
                        .help("Open")
                    VStack(spacing: Theme.Space.xs) {
                        Text(name)
                            .font(Theme.Font.title)
                            .foregroundStyle(Theme.Color.text)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        if let line = summary {
                            Text(line)
                                .font(Theme.Font.small)
                                .foregroundStyle(Theme.Color.textSecondary)
                        }
                        if thoughts > 0 {
                            HStack(spacing: Theme.Space.xs) {
                                Image(systemName: "text.bubble")
                                Text(String(thoughts)).monospacedDigit()
                            }
                            .font(Theme.Font.small)
                            .foregroundStyle(Theme.Color.textTertiary)
                            .help(thoughts == 1 ? "1 thought" : "\(thoughts) thoughts")
                        }
                    }
                    if let info, !rows(info).isEmpty {
                        Hairline().padding(.vertical, Theme.Space.xs)
                        Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.xs) {
                            ForEach(rows(info), id: \.0) { row in
                                GridRow {
                                    Text(row.0)
                                        .foregroundStyle(Theme.Color.textTertiary)
                                        .gridColumnAlignment(.trailing)
                                    Text(row.1)
                                        .foregroundStyle(Theme.Color.textSecondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                        }
                        .font(Theme.Font.small)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.xxl)
                .padding(.bottom, Theme.Space.xl)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.Color.bg)
        .task(id: url) { await load() }
    }

    @ViewBuilder private var picture: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(Squircle(radius: isThumbnail ? Theme.Radius.s : 0))
                .shadow(color: .black.opacity(isThumbnail ? 0.25 : 0), radius: 3, y: 1)
                .transition(.opacity)
        } else {
            Color.clear
        }
    }

    private var summary: String? {
        let parts = [info?.kind, info?.size].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func rows(_ info: Info) -> [(String, String)] {
        func date(_ d: Date?) -> String? { d?.formatted(date: .abbreviated, time: .shortened) }
        return [("Created", date(info.created)), ("Modified", date(info.modified)),
                ("Last opened", date(info.opened)), ("Version", info.version)]
            .compactMap { label, value in value.map { (label, $0) } }
    }

    private func load() async {
        image = nil
        isThumbnail = false
        info = nil
        let url = url
        // The icon at once, so the column never sits empty; the real preview replaces it.
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 256, height: 256)
        image = icon
        async let details = Task.detached(priority: .userInitiated) { Self.details(of: url) }.value
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 360, height: 360), scale: scale,
                                                   representationTypes: .thumbnail)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request), !Task.isCancelled {
            withAnimation(Theme.Motion.fast) {
                image = rep.nsImage
                isThumbnail = true
            }
        }
        let loaded = await details
        if !Task.isCancelled { info = loaded }
    }

    nonisolated private static func details(of url: URL) -> Info {
        let keys: Set<URLResourceKey> = [.localizedTypeDescriptionKey, .fileSizeKey, .creationDateKey,
                                         .contentModificationDateKey, .isPackageKey, .isDirectoryKey]
        let v = try? url.resourceValues(forKeys: keys)
        var info = Info(kind: v?.localizedTypeDescription, created: v?.creationDate, modified: v?.contentModificationDate)
        var bytes = v?.fileSize.map(Int64.init)
        if v?.isDirectory == true { bytes = packageSize(url) }
        if let bytes { info.size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        info.opened = NSMetadataItem(url: url)?.value(forAttribute: "kMDItemLastUsedDate") as? Date
        if url.pathExtension == "app", let version = Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String {
            info.version = version
        }
        return info
    }

    /// A package's size, as Finder adds it up; nil past 20,000 items rather than stall.
    nonisolated private static func packageSize(_ url: URL) -> Int64? {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileSizeKey, .fileSizeKey]) else { return nil }
        var total: Int64 = 0, count = 0
        for case let file as URL in walker {
            count += 1
            if count > 20_000 { return nil }
            let v = try? file.resourceValues(forKeys: [.totalFileSizeKey, .fileSizeKey])
            total += Int64(v?.totalFileSize ?? v?.fileSize ?? 0)
        }
        return total
    }
}
