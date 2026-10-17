import SwiftUI
import FlamingoCore
import FlamingoDesign

/// The ⌘⌥ ring: a round plate with up to eight recent files around a hub that names the
/// highlighted one. Slot 0 is at 12 o'clock and the rest follow clockwise in rank order. With
/// four files or fewer the four compass slots are drawn larger. No labels; the hub shows only
/// the file's own name, folder and times. It never takes hits, so clicks reach the app.
struct RadialRecentsView: View {
    @ObservedObject var radial: RadialMenuModel
    @ObservedObject var recents: RecentFilesModel

    static let plate: CGFloat = 320
    static let hub: CGFloat = 120
    static let orbit: CGFloat = 116

    var body: some View {
        ZStack {
            Color.clear
            ring
                .position(x: radial.center.x, y: radial.center.y)
                .opacity(radial.isOpen ? 1 : 0)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var ring: some View {
        let plate = Circle()
        let tile: CGFloat = radial.slotCount == 4 ? 72 : 56
        return ZStack {
            plate
                .fill(Color.clear)
                .background(VisualEffect(.sidebar, blending: nil, state: .active).clipShape(plate))
                .overlay(plate.strokeBorder(Theme.Color.hairline, lineWidth: Theme.Size.hairline))
                .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
            hub
            ForEach(Array(radial.entries.enumerated()), id: \.element.id) { index, entry in
                let angle = Double(index) * 360 / Double(radial.slotCount) * .pi / 180
                RadialTile(entry: entry, image: recents.thumbnails[entry.id], side: tile,
                           highlighted: radial.highlight == index)
                    .offset(x: Self.orbit * sin(angle), y: -Self.orbit * cos(angle))
            }
        }
        .frame(width: Self.plate, height: Self.plate)
    }

    private var hub: some View {
        let shape = Circle()
        return ZStack {
            shape.fill(Theme.Color.fill)
            if let index = radial.highlight, radial.entries.indices.contains(index) {
                RadialHubInfo(entry: radial.entries[index])
                    .padding(Theme.Space.m)
            }
        }
        .frame(width: Self.hub, height: Self.hub)
    }
}

private struct RadialTile: View {
    let entry: RadialMenuModel.Entry
    let image: NSImage?
    let side: CGFloat
    let highlighted: Bool

    var body: some View {
        let shape = Squircle(radius: Theme.Radius.m)
        let inner = side - 8
        ZStack(alignment: .topTrailing) {
            shape.fill(highlighted ? Theme.Color.selection : Theme.Color.fill)
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: inner, height: inner)
                        .clipShape(ConcentricSquircle(parentRadius: Theme.Radius.m, padding: 4))
                } else {
                    FileGlyph(ext: entry.item.file.ext, size: side > 60 ? 28 : 22)
                }
            }
            .frame(width: side, height: side)
            if entry.item.edited {
                Squircle(radius: 3)
                    .fill(Theme.Color.textSecondary)
                    .frame(width: 6, height: 6)
                    .padding(4)
            }
        }
        .frame(width: side, height: side)
        .focusRing(highlighted, radius: Theme.Radius.m)
    }
}

private struct RadialHubInfo: View {
    let entry: RadialMenuModel.Entry

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            Text(entry.item.file.name)
                .font(Theme.Font.bodyMedium)
                .foregroundStyle(Theme.Color.text)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
            if !entry.item.file.directory.isEmpty {
                Text(entry.item.file.directory)
                    .font(Theme.Font.monoSmall)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            HStack(spacing: Theme.Space.xs) {
                if entry.item.edited { Image(systemName: "pencil") }
                if let touched = entry.item.lastTouched {
                    Text(RadialHubInfo.formatter.localizedString(for: touched, relativeTo: Date()))
                }
                if entry.thoughts > 0 {
                    Image(systemName: "text.bubble")
                    Text("\(entry.thoughts)")
                }
            }
            .font(Theme.Font.small)
            .foregroundStyle(Theme.Color.textSecondary)
            .lineLimit(1)
        }
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
