import AppKit
import ApplicationServices
import FlamingoCore

/// Thin Accessibility reads for the frontmost window. Every call is bounded by a short
/// messaging timeout so a hung app can't hang capture. Never call these on our own pid
/// from the main thread: the request would wait on the thread that has to answer it.
enum AXFrontmost {
    struct Window {
        var documentURL: URL?
        var sourceURL: URL?
        var title: String?
        /// AppKit global coordinates, bottom-left origin.
        var frame: CGRect?
    }

    static func focusedWindow(pid: pid_t) -> Window? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let w = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute)
                ?? (copy(app, kAXWindowsAttribute) as? [AXUIElement])?.first else { return nil }
        AXUIElementSetMessagingTimeout(w, 0.5)
        var frame: CGRect?
        if let pos = point(w, kAXPositionAttribute), let size = size(w, kAXSizeAttribute) {
            frame = appKitFrame(axOrigin: pos, size: size, primaryHeight: CGDisplayBounds(CGMainDisplayID()).height)
        }
        let raw = copy(w, kAXDocumentAttribute) as? String
        return Window(documentURL: documentURL(from: raw), sourceURL: raw.flatMap(URL.init(string:)),
                      title: copy(w, kAXTitleAttribute) as? String,
                      frame: frame)
    }

    /// The text selected in the app's focused element, at most `limit` characters. Nil when
    /// nothing is selected, the element is a password field, or the app does not say.
    static func selectedText(pid: pid_t, limit: Int = ThoughtQuote.limit) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let focused = element(app, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.5)
        if (copy(focused, kAXSubroleAttribute) as? String) == (kAXSecureTextFieldSubrole as String) { return nil }
        guard let raw = copy(focused, kAXSelectedTextAttribute) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit))
    }

    /// AX reports top-left-origin rects relative to the menu-bar display; AppKit wants
    /// bottom-left origin.
    static func appKitFrame(axOrigin: CGPoint, size: CGSize, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: axOrigin.x, y: primaryHeight - axOrigin.y - size.height, width: size.width, height: size.height)
    }

    /// `AXDocument` is usually a `file://` URL string, occasionally a bare path.
    static func documentURL(from raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        guard let url = URL(string: raw), url.isFileURL else { return nil }
        return url
    }

    // MARK: Raw attribute access

    private static func copy(_ e: AXUIElement, _ attr: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? v : nil
    }

    private static func element(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = copy(e, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func point(_ e: AXUIElement, _ attr: String) -> CGPoint? {
        guard let v = copy(e, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    private static func size(_ e: AXUIElement, _ attr: String) -> CGSize? {
        guard let v = copy(e, attr), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }
}
