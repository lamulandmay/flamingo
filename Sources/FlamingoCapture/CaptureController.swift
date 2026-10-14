import AppKit
import FlamingoCore

/// Registers the capture hotkey and shows `CommentPanel` as a floating panel. Plan 03 owns.
@MainActor
public final class CaptureController {
    public static let shared = CaptureController()
    /// Called when a comment is submitted. The shell sets this.
    public var onComment: ((FileRef, Comment) -> Void)?
    /// The shell keeps this current so the panel knows what to attach to.
    public var currentTarget: (() -> (FileRef, FileAnchor?)?)?

    public func installInAppHotkey() { /* TODO(plan 03): ⌘⇧C inside the app */ }
    public func installGlobalHotkey() { /* TODO(plan 03): behind a setting; needs Accessibility */ }
    public func show() { /* TODO(plan 03) */ }
}
