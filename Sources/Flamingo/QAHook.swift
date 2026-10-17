import AppKit
import FlamingoCore

/// Headless QA, on only when `FLAMINGO_DEBUG` is set: keys sent as a distributed notification
/// are delivered to the app's frontmost window, even while another app is active (macOS
/// won't hand a test build focus while someone is working). Plan 01 owns.
///
///     postnote com.flamingo.qa "key 126"         ↑
///     postnote com.flamingo.qa "key 40 cmd"      ⌘K
///     postnote com.flamingo.qa "type clamp"
///     postnote com.flamingo.qa "menu Leave a Thought"
///     postnote com.flamingo.qa "focus ThoughtNSTextView"
///     postnote com.flamingo.qa "thought see [[q3-model.xlsx]]"
@MainActor
enum QAHook {
    /// `FLAMINGO_QA_CHANNEL` picks another name, so concurrent test builds don't hear each other.
    static let name = Notification.Name(ProcessInfo.processInfo.environment["FLAMINGO_QA_CHANNEL"] ?? "com.flamingo.qa")
    private static var observer: NSObjectProtocol?

    static func install() {
        guard Log.enabled, observer == nil else { return }
        startLagMonitor()
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
        // `thought Pricing contradicts [[q3-model.xlsx]]`: saves on the open file and celebrates,
        // as the capture panel does, without needing the panel to hold key focus.
        if parts[0] == "thought" {
            guard let state = (NSApp.delegate as? AppDelegate)?.state, let file = state.selected else { return }
            let comment = Comment(anchor: state.anchor, text: parts[1])
            Task { @MainActor in
                do { try await state.saveComment(comment, to: file); state.celebrate(comment, on: file) }
                catch { Log.debug("qa: thought not saved: \(error)") }
            }
            return
        }
        // `menu Leave a Thought`: a background app's key equivalents don't fire, so run the item.
        if parts[0] == "menu" {
            func find(_ menu: NSMenu?) -> NSMenuItem? {
                for item in menu?.items ?? [] {
                    if item.title == parts[1], item.action != nil { return item }
                    if let hit = find(item.submenu) { return hit }
                }
                return nil
            }
            guard let item = find(NSApp.mainMenu), let action = item.action else { return Log.debug("qa: no menu item \(parts[1])") }
            NSApp.sendAction(action, to: item.target, from: item)
            return
        }
        // `focus ThoughtNSTextView`: the keyboard into the first view of that class, for
        // fields that don't take focus on their own and can't be clicked headlessly.
        if parts[0] == "focus" {
            func find(_ view: NSView) -> NSView? {
                if String(describing: type(of: view)) == parts[1] { return view }
                for sub in view.subviews { if let hit = find(sub) { return hit } }
                return nil
            }
            let windows = NSApp.orderedWindows.filter(\.isVisible)
            guard let (window, view) = windows.lazy.compactMap({ w in w.contentView.flatMap(find).map { (w, $0) } }).first
            else { return Log.debug("qa: no view \(parts[1])") }
            window.makeFirstResponder(view)
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
                                     20: "3", 21: "4", 33: "[", 30: "]", 42: "\\"]
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

    /// Every 10 s, logs the longest the main thread took to run a 50 ms timer, minus 50 ms:
    /// what a user would feel as a stutter.
    private static func startLagMonitor() {
        var expected = Date().addingTimeInterval(0.05)
        var worst = 0.0, windowStart = Date()
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            let now = Date()
            worst = max(worst, now.timeIntervalSince(expected))
            expected = now.addingTimeInterval(0.05)
            if now.timeIntervalSince(windowStart) >= 10 {
                Log.debug("main: worst lag \(Int(worst * 1000)) ms over 10 s")
                worst = 0; windowStart = now
            }
        }
    }
}
