import SwiftUI

/// The style guide: every token and component, light beside dark. A screenshot of this
/// view is the reference. The words on this page are specimen labels, not app copy.
public struct DesignPreview: View {
    public init() {}
    public var body: some View {
        HStack(spacing: 0) {
            DesignSheet().appearance(.light)
            VHairline()
            DesignSheet().appearance(.dark)
        }
        .fixedSize()
    }
}

extension View {
    /// Pins a subtree to light or dark, for previews and the style guide.
    /// Both SwiftUI's color scheme and AppKit's appearance follow, so `Theme.NS` colors resolve too.
    public func appearance(_ scheme: ColorScheme) -> some View {
        AppearanceScope(scheme: scheme, content: self)
    }
}

private struct AppearanceScope<Content: View>: NSViewRepresentable {
    let scheme: ColorScheme
    let content: Content

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let v = NSHostingView(rootView: wrapped)
        v.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        return v
    }
    func updateNSView(_ v: NSHostingView<AnyView>, context: Context) {
        v.rootView = wrapped
        v.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSHostingView<AnyView>, context: Context) -> CGSize? {
        nsView.fittingSize
    }
    private var wrapped: AnyView { AnyView(content.environment(\.colorScheme, scheme)) }
}

private struct DesignSheet: View {
    @State private var mode: FlamingoMode = .graph
    @State private var query = "pricing"
    @State private var empty = ""

    private let sampleExts = ["pptx", "key", "docx", "pages", "xlsx", "numbers", "csv", "pdf",
                              "png", "heic", "mov", "m4a", "usdz", "obj", "swift", "py", "json",
                              "md", "txt", "zip", "xyz"]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            HStack(spacing: Theme.Space.m) {
                FlamingoMark().fill(Theme.Color.accent).frame(width: 28, height: 28)
                Text("Flamingo").font(Theme.Font.title).foregroundStyle(Theme.Color.text)
            }

            section("Color") {
                HStack(spacing: Theme.Space.s) {
                    swatch("accent", Theme.Color.accent)
                    swatch("bg", Theme.Color.bg)
                    swatch("bgRaised", Theme.Color.bgRaised)
                    swatch("bgSunken", Theme.Color.bgSunken)
                    swatch("fill", Theme.Color.fill)
                    swatch("hover", Theme.Color.hover)
                    swatch("selection", Theme.Color.selection)
                }
                HStack(spacing: Theme.Space.l) {
                    Text("text").foregroundStyle(Theme.Color.text)
                    Text("textSecondary").foregroundStyle(Theme.Color.textSecondary)
                    Text("textTertiary").foregroundStyle(Theme.Color.textTertiary)
                    Text("accent").foregroundStyle(Theme.Color.accent)
                }
                .font(Theme.Font.body)
            }

            section("Families") {
                HStack(spacing: Theme.Space.m) {
                    ForEach(FileFamily.allCases, id: \.self) { f in
                        VStack(spacing: Theme.Space.xs) {
                            Circle().fill(f.color).frame(width: 14, height: 14)
                            Image(systemName: f.symbol).font(.system(size: 14)).foregroundStyle(f.color)
                            Text(f.rawValue).font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary)
                        }
                        .frame(width: 54)
                    }
                }
            }

            section("Type") {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Pricing contradicts the Q3 model").font(Theme.Font.title)
                    Text("Pricing contradicts the Q3 model").font(Theme.Font.body)
                    Text("Pricing contradicts the Q3 model").font(Theme.Font.bodyMedium)
                    Text("Oct 12 · 22:05").font(Theme.Font.small).foregroundStyle(Theme.Color.textSecondary)
                    Text("decks/q3.pptx").font(Theme.Font.mono).foregroundStyle(Theme.Color.textSecondary)
                    SectionMarker("Pinned")
                }
                .foregroundStyle(Theme.Color.text)
            }

            section("Glyphs") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(80), spacing: Theme.Space.s), count: 6),
                          alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(sampleExts, id: \.self) { e in
                        HStack(spacing: Theme.Space.xs) {
                            FileGlyph(ext: e)
                            Text(e).font(Theme.Font.monoSmall).foregroundStyle(Theme.Color.textSecondary)
                        }
                    }
                }
            }

            section("Rows") {
                VStack(spacing: 0) {
                    HStack(spacing: Theme.Space.s) { FolderGlyph(); Text("decks") }.flamingoRow(selected: false)
                    HStack(spacing: Theme.Space.s) { FileGlyph(ext: "pptx"); Text("q3.pptx") }.flamingoRow(selected: true)
                    HStack(spacing: Theme.Space.s) {
                        FileGlyph(ext: "xlsx"); Text("q3-model.xlsx"); Spacer(); Chip("sheet Q3")
                    }.flamingoRow(selected: false)
                    HStack(spacing: Theme.Space.s) { FileGlyph(ext: "md"); Text("standup.md") }.flamingoRow(selected: false)
                }
                .frame(width: 280)
            }

            section("Controls") {
                HStack(spacing: Theme.Space.l) {
                    SegmentedModes(selection: $mode)
                    SearchField(text: $query).frame(width: 180)
                    SearchField(text: $empty).frame(width: 120)
                    IconButton("sidebar.right", help: "Comments") {}
                    IconButton("arrow.clockwise", help: "Resume", isOn: true) {}
                }
                HStack(spacing: Theme.Space.s) {
                    Chip("slide 7")
                    Chip("cell Q3!B12")
                    Chip("time 1:23")
                    Chip(text: "q3-model.xlsx", mono: false)
                    Spacer().frame(width: Theme.Space.l)
                    KeyHint("⌘K")
                    KeyHint("⇧⌘C")
                    KeyHint("⌃⌥Space")
                }
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ProgressHairline(value: 0.42).frame(width: 320)
                    Hairline().frame(width: 320)
                }
                Toast("Thought deleted", action: "Undo") {}.frame(width: 280)
            }

            section("Panel") {
                PanelChrome(width: 420, shadow: false) {
                    VStack(spacing: 0) {
                        SearchField(text: $query)
                            .padding(Theme.Space.s)
                        Hairline()
                        VStack(spacing: 0) {
                            HStack(spacing: Theme.Space.s) {
                                FileGlyph(ext: "pptx"); Text("q3.pptx"); Spacer()
                                Text("decks").font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary)
                            }.flamingoRow(selected: true)
                            HStack(spacing: Theme.Space.s) {
                                FileGlyph(ext: "xlsx"); Text("q3-model.xlsx"); Spacer()
                                Text("finance").font(Theme.Font.small).foregroundStyle(Theme.Color.textTertiary)
                            }.flamingoRow(selected: false)
                            HStack(spacing: Theme.Space.s) {
                                Image(systemName: "point.3.connected.trianglepath.dotted")
                                    .font(.system(size: Theme.Size.icon))
                                    .foregroundStyle(Theme.Color.textSecondary)
                                    .frame(width: 19)
                                Text("Show Graph"); Spacer(); KeyHint("⌘2")
                            }.flamingoRow(selected: false)
                        }
                        .padding(Theme.Space.xs)
                    }
                }
            }

            section("Empty") {
                EmptyState("No vault open").frame(width: 320, height: 64)
                    .background(Theme.Color.bgSunken)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 600, alignment: .topLeading)
        .background(Theme.Color.bg)
    }

    private func section<C: View>(_ name: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionMarker(name)
            content()
        }
    }

    private func swatch(_ name: String, _ c: SwiftUI.Color) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Squircle(radius: Theme.Radius.s)
                .fill(c)
                .overlay(Squircle(radius: Theme.Radius.s)
                    .strokeBorder(Theme.Color.hairline, lineWidth: 1))
                .frame(width: 64, height: 32)
            Text(name).font(Theme.Font.monoSmall).foregroundStyle(Theme.Color.textTertiary)
        }
    }
}

#Preview("Style guide") { DesignPreview() }
