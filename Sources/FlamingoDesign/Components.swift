import SwiftUI

/// Shared components. Plan 08 fills these in; keep the signatures.
public struct Hairline: View {
    public init() {}
    public var body: some View { Rectangle().fill(Theme.Color.hairline).frame(height: 1) }
}

/// A file-type glyph. Plan 08 owns the icon set.
public struct FileGlyph: View {
    public let ext: String
    public var size: CGFloat
    public init(ext: String, size: CGFloat = 14) { self.ext = ext; self.size = size }
    public var body: some View {
        Image(systemName: "doc").font(.system(size: size)).foregroundStyle(Theme.Color.textSecondary)
    }
}
