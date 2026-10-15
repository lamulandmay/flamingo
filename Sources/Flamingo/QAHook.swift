import AppKit

/// Headless QA, on only when `FLAMINGO_DEBUG` is set: keys sent as a distributed notification
/// are delivered to the app's frontmost window, even while another app is active (macOS
/// won't hand a test build focus while someone is working). Plan 01 owns.
///
///     postnote com.flamingo.qa "key 126"         ↑
///     postnote com.flamingo.qa "key 40 cmd"      ⌘K
///     postnote com.flamingo.qa "type clamp"
@MainActor
enum QAHook {
    static let name = Notification.Name("com.flamingo.qa")
    private static var observer: NSObjectProtocol?

    static func install() {
        guard Log.enabled, observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { run(command) }
        }
    }

    private static func run(_ command: String) {
        Log.debug("qa: \(command)")
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        if parts[0] == "type" {
            for ch in parts[1] { send(code: 0, chars: String(ch), flags: []) }
            return
        }
        let args = parts[1].split(separator: " ").map(String.init)
        guard parts[0] == "key", let code = UInt16(args[0]) else { return }
        var flags: NSEvent.ModifierFlags = []
        for m in args.dropFirst() {
            switch m {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: break
            }
        }
        let special: [UInt16: Int] = [126: NSUpArrowFunctionKey, 125: NSDownArrowFunctionKey,
                                      123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey]
        let chars: String
        if let f = special[code] { chars = String(UnicodeScalar(UInt16(f)).map(Character.init) ?? " ") }
        else { chars = [51: "\u{7f}", 117: "\u{f728}", 36: "\r", 53: "\u{1b}", 48: "\t"][code] ?? letter(code) }
        send(code: code, chars: chars, flags: flags)
    }

    private static func letter(_ code: UInt16) -> String {
        let map: [UInt16: String] = [0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h", 34: "i", 38: "j",
                                     40: "k", 37: "l", 46: "m", 45: "n", 31: "o", 35: "p", 12: "q", 15: "r", 1: "s",
                                     17: "t", 32: "u", 9: "v", 13: "w", 7: "x", 16: "y", 6: "z", 18: "1", 19: "2",
                                     20: "3", 21: "4", 33: "[", 30: "]"]
        return map[code] ?? ""
    }

    private static func send(code: UInt16, chars: String, flags: NSEvent.ModifierFlags) {
        guard let window = NSApp.keyWindow ?? NSApp.orderedWindows.first(where: { $0.isVisible && $0.canBecomeKey }),
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: code) else { return }
        if flags.contains(.command) || flags.contains(.control) {
            if window.performKeyEquivalent(with: event) { return }
            if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return }
        }
        Log.debug("qa: to \(type(of: window)) key=\(window.isKeyWindow) responder=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
        // An inactive app's windows ignore `sendEvent` key events; hand them to the responder.
        if window.isKeyWindow { window.sendEvent(event) } else { window.firstResponder?.keyDown(with: event) }
    }
}
