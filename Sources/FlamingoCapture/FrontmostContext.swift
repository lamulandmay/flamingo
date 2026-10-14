import AppKit
import FlamingoCore

/// What the user is looking at in another app right now. Plan 03 owns.
public struct FrontmostContext: Sendable {
    public var appBundleID: String
    public var documentURL: URL?
    public var anchor: FileAnchor?

    public static func current() -> FrontmostContext? {
        // TODO(plan 03): Accessibility API for document URL; AppleScript for Keynote/Preview/Numbers/Pages anchors.
        return nil
    }
}
