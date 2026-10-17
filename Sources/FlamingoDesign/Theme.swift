import SwiftUI
import AppKit

/// Design tokens. Names are frozen; values are plan 08's to refine. See DESIGN.md.
///
/// Every color is dynamic: it resolves per appearance (light, dark, and the two
/// Increase Contrast variants). AppKit code uses the same values through `Theme.NS`.
public enum Theme {
    public enum Color {
        /// Flamingo coral. Selection, focus ring, links, the one primary action. Nothing else.
        /// Dark `#FF7A88` (6.8:1 on `bg`), light `#D23B57` (4.7:1 on `bg`).
        public static let accent = SwiftUI.Color(nsColor: Theme.NS.accent)
        /// Content surface. Opaque. Dark `#1C1C1E`, light white.
        public static let bg = SwiftUI.Color(nsColor: Theme.NS.bg)
        /// One step up from `bg`: inline editors, toasts, popovers drawn in-window.
        public static let bgRaised = SwiftUI.Color(nsColor: Theme.NS.bgRaised)
        public static let text = SwiftUI.Color(nsColor: Theme.NS.text)
        public static let textSecondary = SwiftUI.Color(nsColor: Theme.NS.textSecondary)
        /// Timestamps, the one-line empty state, the target line under the comment field.
        public static let textTertiary = SwiftUI.Color(nsColor: Theme.NS.textTertiary)
        /// 1pt separators. White 8% in dark, black 8% in light.
        public static let hairline = SwiftUI.Color(nsColor: Theme.NS.hairline)
        /// Selected row background. Accent at low opacity; text on it stays `text`.
        public static let selection = SwiftUI.Color(nsColor: Theme.NS.selection)

        /// One step down from `bg`: canvases (graph), the area behind a preview. Dark `#161618`.
        public static let bgSunken = SwiftUI.Color(nsColor: Theme.NS.bgSunken)
        /// Translucent fill for fields and chips. Works on `bg` and on sidebar material alike.
        public static let fill = SwiftUI.Color(nsColor: Theme.NS.fill)
        /// Row hover. Lighter than `fill`, never colored.
        public static let hover = SwiftUI.Color(nsColor: Theme.NS.hover)
        /// Text and glyphs drawn on a solid `accent` fill.
        public static let onAccent = SwiftUI.Color(nsColor: Theme.NS.onAccent)
        /// The tint a saved thought lands with, by strength (0 spark, 1 solid, 2 woven): blush,
        /// coral, flamingo. One hue, more of it, the way a flamingo gets pinker from what it eats.
        public static func thought(_ level: Int) -> SwiftUI.Color { SwiftUI.Color(nsColor: Theme.NS.thought(level)) }

        /// Muted family hue for a file extension: graph nodes and glyph tints.
        /// Unknown extensions get `textSecondary`.
        public static func family(ext: String) -> SwiftUI.Color {
            FileFamily(ext: ext)?.color ?? textSecondary
        }
    }

    public enum Font {
        /// 13pt regular. Everything by default.
        public static let body = SwiftUI.Font.system(size: 13)
        /// 11pt regular. Secondary lines, timestamps, graph labels.
        public static let small = SwiftUI.Font.system(size: 11)
        /// 15pt semibold. The rare title.
        public static let title = SwiftUI.Font.system(size: 15, weight: .semibold)
        /// 12pt SF Mono. Paths and anchors.
        public static let mono = SwiftUI.Font.system(size: 12, design: .monospaced)

        /// 13pt medium. Emphasis inside body text, the selected mode.
        public static let bodyMedium = SwiftUI.Font.system(size: 13, weight: .medium)
        /// 11pt SF Mono. Anchors in chips, the target line under the comment field.
        public static let monoSmall = SwiftUI.Font.system(size: 11, design: .monospaced)
        /// 11pt medium for the rare section marker. Pair with `capsTracking`, or use
        /// `.capsStyle()` / `SectionMarker`, which apply both and uppercase.
        public static let caps = SwiftUI.Font.system(size: 11, weight: .medium)
        public static let capsTracking: CGFloat = 0.6
    }

    /// 4pt grid.
    public enum Space {
        public static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24
        public static let xxl: CGFloat = 32
    }

    public enum Radius { public static let s: CGFloat = 4, m: CGFloat = 8, l: CGFloat = 12 }

    /// 150–220ms ease-out. Nothing springs.
    public enum Motion {
        public static let fast = Animation.easeOut(duration: 0.15), normal = Animation.easeOut(duration: 0.22)
        /// Same durations for `NSAnimationContext` and Core Animation.
        public static let fastSeconds: TimeInterval = 0.15, normalSeconds: TimeInterval = 0.22
    }

    /// Fixed dimensions from DESIGN.md's layout.
    public enum Size {
        /// Row height for lists, the sidebar tree, palette results. Finder density.
        public static let row: CGFloat = 26
        public static let sidebar: CGFloat = 240
        public static let rail: CGFloat = 280
        /// Command palette, search, comment panel.
        public static let panel: CGFloat = 560
        /// SF Symbols in rows and toolbars.
        public static let icon: CGFloat = 14
        public static let iconSmall: CGFloat = 13
        public static let hairline: CGFloat = 1
    }

    /// Opacities for hover and dimming. Hover changes opacity, not size.
    public enum Opacity {
        /// Icon buttons at rest; 1 on hover.
        public static let rest: Double = 0.75
        /// Everything that isn't the focus of a hover (graph neighbors, faded questions).
        public static let dimmed: Double = 0.3
        public static let disabled: Double = 0.35
    }

    /// AppKit mirrors of the tokens, for `NSView`, `NSPanel`, `NSTextView` and `CALayer` code.
    /// `Theme.Color` wraps these, so both always agree.
    public enum NS {
        public static let accent = NSColor.flamingo("accent",
            light: NSColor(hex: 0xD23B57), dark: NSColor(hex: 0xFF7A88),
            lightHC: NSColor(hex: 0xB0233F), darkHC: NSColor(hex: 0xFF9DA8))
        public static let bg = NSColor.flamingo("bg",
            light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x1C1C1E),
            darkHC: NSColor(hex: 0x111113))
        public static let bgRaised = NSColor.flamingo("bgRaised",
            light: NSColor(hex: 0xF5F5F7), dark: NSColor(hex: 0x232326),
            lightHC: NSColor(hex: 0xECECEF), darkHC: NSColor(hex: 0x2A2A2E))
        public static let bgSunken = NSColor.flamingo("bgSunken",
            light: NSColor(hex: 0xF2F2F4), dark: NSColor(hex: 0x161618),
            darkHC: NSColor(hex: 0x0C0C0D))
        public static let text = NSColor.flamingo("text",
            light: NSColor(white: 0, alpha: 0.86), dark: NSColor(white: 1, alpha: 0.88),
            lightHC: NSColor(white: 0, alpha: 1), darkHC: NSColor(white: 1, alpha: 1))
        public static let textSecondary = NSColor.flamingo("textSecondary",
            light: NSColor(white: 0, alpha: 0.55), dark: NSColor(white: 1, alpha: 0.56),
            lightHC: NSColor(white: 0, alpha: 0.72), darkHC: NSColor(white: 1, alpha: 0.74))
        public static let textTertiary = NSColor.flamingo("textTertiary",
            light: NSColor(white: 0, alpha: 0.36), dark: NSColor(white: 1, alpha: 0.36),
            lightHC: NSColor(white: 0, alpha: 0.55), darkHC: NSColor(white: 1, alpha: 0.55))
        public static let hairline = NSColor.flamingo("hairline",
            light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08),
            lightHC: NSColor(white: 0, alpha: 0.3), darkHC: NSColor(white: 1, alpha: 0.3))
        public static let selection = NSColor.flamingo("selection",
            light: NSColor(hex: 0xD23B57, alpha: 0.16), dark: NSColor(hex: 0xFF7A88, alpha: 0.26),
            lightHC: NSColor(hex: 0xB0233F, alpha: 0.26), darkHC: NSColor(hex: 0xFF9DA8, alpha: 0.32))
        public static let fill = NSColor.flamingo("fill",
            light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.07),
            lightHC: NSColor(white: 0, alpha: 0.1), darkHC: NSColor(white: 1, alpha: 0.14))
        public static let hover = NSColor.flamingo("hover",
            light: NSColor(white: 0, alpha: 0.035), dark: NSColor(white: 1, alpha: 0.045))
        public static let onAccent = NSColor.flamingo("onAccent",
            light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x1C1C1E))
        public static let thoughtSpark = NSColor.flamingo("thoughtSpark",
            light: NSColor(hex: 0xDE8697), dark: NSColor(hex: 0xF3B9C1),
            lightHC: NSColor(hex: 0xC56F80), darkHC: NSColor(hex: 0xFFD0D6))
        public static let thoughtWoven = NSColor.flamingo("thoughtWoven",
            light: NSColor(hex: 0xB3173F), dark: NSColor(hex: 0xFF4A6B),
            lightHC: NSColor(hex: 0x940E30), darkHC: NSColor(hex: 0xFF6E88))
        /// `Theme.Color.thought(_:)` for AppKit. Solid is the accent itself.
        public static func thought(_ level: Int) -> NSColor {
            level <= 0 ? thoughtSpark : level == 1 ? accent : thoughtWoven
        }

        /// Family tint for AppKit glyphs; accent when selected, `textSecondary` for unknown extensions.
        public static func family(ext: String, selected: Bool = false) -> NSColor {
            selected ? accent : (FileFamily(ext: ext)?.nsColor ?? textSecondary)
        }

        public static let body = NSFont.systemFont(ofSize: 13)
        public static let bodyMedium = NSFont.systemFont(ofSize: 13, weight: .medium)
        public static let small = NSFont.systemFont(ofSize: 11)
        public static let title = NSFont.systemFont(ofSize: 15, weight: .semibold)
        public static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        public static let monoSmall = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    }
}

// MARK: - File families

/// The nine families every file belongs to (or none). Drives glyphs and graph node tints.
public enum FileFamily: String, CaseIterable, Sendable {
    case deck, document, sheet, pdf, image, media, model, code, note

    /// `nil` for extensions Flamingo has no family for (archives, binaries, unknown).
    public init?(ext: String) {
        guard let f = FileFamily.table[ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))] else { return nil }
        self = f
    }

    /// Muted family hue. Low saturation so the accent stays the only loud color.
    public var color: SwiftUI.Color { SwiftUI.Color(nsColor: nsColor) }
    public var nsColor: NSColor { FileFamily.colors[self]! }

    /// SF Symbol for the family. `FileGlyph` refines a few (audio vs. video).
    public var symbol: String {
        switch self {
        case .deck: "rectangle.on.rectangle.angled"
        case .document: "doc.text"
        case .sheet: "tablecells"
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .media: "film"
        case .model: "cube"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .note: "text.alignleft"
        }
    }

    /// Every extension Flamingo recognizes, lowercased, without the dot.
    public static let table: [String: FileFamily] = {
        var t: [String: FileFamily] = [:]
        func put(_ f: FileFamily, _ exts: String) { for e in exts.split(separator: " ") { t[String(e)] = f } }
        put(.deck, "pptx ppt pptm pps ppsx potx key odp")
        put(.document, "docx doc docm dotx pages rtf rtfd odt epub wpd indd")
        put(.sheet, "xlsx xls xlsm xltx numbers csv tsv ods")
        put(.pdf, "pdf")
        put(.image, "png jpg jpeg heic heif gif tif tiff bmp webp avif svg ico icns psd ai eps sketch fig raw dng cr2 cr3 nef arw")
        put(.media, "mp4 mov m4v avi mkv webm mpg mpeg mp3 m4a wav aif aiff flac aac ogg oga opus caf mid midi prproj band logicx sesx")
        put(.model, "usdz usd usda usdc reality realitycomposerpro scn obj stl fbx glb gltf dae ply 3mf blend abc shapr step stp iges igs")
        put(.code, "swift py js mjs cjs ts tsx jsx json jsonl yaml yml toml plist xml html htm css scss sass less c h cc cpp hpp m mm rs go rb java kt kts scala cs php lua r jl sh zsh bash fish sql ipynb ino gradle cmake makefile dockerfile vue svelte")
        put(.note, "md markdown mdown mkd txt text org rst tex log adoc xmind")
        return t
    }()

    /// Audio extensions inside `.media`, drawn with a waveform instead of film.
    public static let audio: Set<String> = ["mp3", "m4a", "wav", "aif", "aiff", "flac", "aac", "ogg", "oga", "opus", "caf", "mid", "midi", "band", "logicx", "sesx"]

    // Hue in degrees, saturation. Brightness is set per appearance so every family
    // reads at the same weight: 0.80 in dark, 0.64 in light. No yellow: at light-mode
    // brightness it turns olive. Model is orchid, kept clear of the accent's hue.
    private static let hues: [FileFamily: (h: CGFloat, s: CGFloat)] = [
        .deck: (24, 0.48), .document: (210, 0.42), .sheet: (142, 0.38), .pdf: (4, 0.40),
        .image: (266, 0.32), .media: (176, 0.40), .model: (302, 0.30), .code: (234, 0.30),
        .note: (36, 0.14),
    ]

    private static let colors: [FileFamily: NSColor] = {
        var c: [FileFamily: NSColor] = [:]
        for (f, hs) in hues {
            let h = hs.h / 360
            c[f] = NSColor.flamingo("family.\(f.rawValue)",
                light: NSColor(hue: h, saturation: min(1, hs.s * 1.35), brightness: 0.64, alpha: 1),
                dark: NSColor(hue: h, saturation: hs.s, brightness: 0.80, alpha: 1),
                lightHC: NSColor(hue: h, saturation: min(1, hs.s * 1.4), brightness: 0.45, alpha: 1),
                darkHC: NSColor(hue: h, saturation: hs.s * 0.85, brightness: 0.92, alpha: 1))
        }
        return c
    }()
}

// MARK: - Dynamic color plumbing

extension NSColor {
    /// sRGB from `0xRRGGBB`.
    public convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    /// A color that resolves per appearance. High-contrast variants fall back to the plain ones.
    static func flamingo(_ name: String, light: NSColor, dark: NSColor,
                         lightHC: NSColor? = nil, darkHC: NSColor? = nil) -> NSColor {
        NSColor(name: "flamingo.\(name)") { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua,
                                               .accessibilityHighContrastAqua,
                                               .accessibilityHighContrastDarkAqua]) {
            case .darkAqua?: dark
            case .accessibilityHighContrastDarkAqua?: darkHC ?? dark
            case .accessibilityHighContrastAqua?: lightHC ?? light
            default: light
            }
        }
    }
}
