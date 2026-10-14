import SwiftUI

/// Design tokens. Names are frozen; values are plan 08's to refine. See DESIGN.md.
public enum Theme {
    public enum Color {
        public static let accent = SwiftUI.Color(red: 0.95, green: 0.36, blue: 0.47) // flamingo
        public static let bg = SwiftUI.Color(nsColor: .windowBackgroundColor)
        public static let bgRaised = SwiftUI.Color(nsColor: .controlBackgroundColor)
        public static let text = SwiftUI.Color.primary
        public static let textSecondary = SwiftUI.Color.secondary
        public static let textTertiary = SwiftUI.Color(nsColor: .tertiaryLabelColor)
        public static let hairline = SwiftUI.Color(nsColor: .separatorColor)
        public static let selection = SwiftUI.Color.accentColor.opacity(0.18)
    }
    public enum Font {
        public static let body = SwiftUI.Font.system(size: 13)
        public static let small = SwiftUI.Font.system(size: 11)
        public static let title = SwiftUI.Font.system(size: 15, weight: .semibold)
        public static let mono = SwiftUI.Font.system(size: 12, design: .monospaced)
    }
    public enum Space {
        public static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24
    }
    public enum Radius { public static let s: CGFloat = 4, m: CGFloat = 8, l: CGFloat = 12 }
    public enum Motion { public static let fast = Animation.easeOut(duration: 0.15), normal = Animation.easeOut(duration: 0.22) }
}
