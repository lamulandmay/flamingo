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
///     postnote com.flamingo.qa "open decks/q3.pptx"     jump to a file, as a click would
///     postnote com.flamingo.qa "flags cmd opt"          hold ⌘⌥ (the recent-files ring); "flags none" releases
///     postnote com.flamingo.qa "radial 90 80"           pointer 80 pt clockwise from 12 o'clock, 90°; "radial center"
///     postnote com.flamingo.qa "radial origin 400 300"  where the next ring opens (window coordinates, y down)
///     postnote com.flamingo.qa "tile thirds"            a layout: single halves thirds mainPlusStack grid
///     postnote com.flamingo.qa "pane 2"                 focus the pane in slot 2 (1-based); "pane close 2" closes it
///     postnote com.flamingo.qa "window 1000 600"       content size in points; "window full" fills the screen
///     postnote com.flamingo.qa "launch 2 #0"            the launcher in slot 2 opens its pick 0; "launch 2 q3" types q3 into it
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
                    // Submenus built when opened (Go → Recent Files) are filled first.
                    if let sub = item.submenu { sub.delegate?.menuNeedsUpdate?(sub) }
                    if let hit = find(item.submenu) { return hit }
                }
                return nil
            }
            guard let item = find(NSApp.mainMenu), let action = item.action else { return Log.debug("qa: no menu item \(parts[1])") }
            NSApp.sendAction(action, to: item.target, from: item)
            return
        }
        // `open decks/q3.pptx`: what clicking the file would do.
        if parts[0] == "open" {
            guard let state = (NSApp.delegate as? AppDelegate)?.state else { return }
            state.jump(to: FileRef(relativePath: parts[1]), anchor: nil)
            return
        }
        // `workspace undo|redo`: the workspace's own undo, whatever has keyboard focus.
        if parts[0] == "workspace" {
            guard let state = (NSApp.delegate as? AppDelegate)?.state else { return }
            if parts[1] == "undo" { state.undoAction() } else if parts[1] == "redo" { state.redoAction() }
            return
        }
        if parts[0] == "window" {
            guard let window = (NSApp.delegate as? AppDelegate)?.window else { return }
            let n = parts[1].split(separator: " ").compactMap { Double($0) }
            if parts[1] == "full", let screen = window.screen { window.setFrame(screen.visibleFrame, display: true) }
            else if n.count == 2 { window.setContentSize(NSSize(width: n[0], height: n[1])) }
            return
        }
        // `tile thirds`, `pane 2`, `pane close 2`, `launch 2 #0`, `launch 2 q3`.
        if parts[0] == "tile" || parts[0] == "pane" || parts[0] == "launch" {
            guard let state = (NSApp.delegate as? AppDelegate)?.state else { return }
            runTiling(parts[0], parts[1], state)
            return
        }
        // `flags cmd opt` presses ⌘⌥ for the recent-files ring, `flags none` lets go. Synthesized
        // events never reach a local monitor, so these call the controller directly.
        if parts[0] == "flags" {
            var flags: NSEvent.ModifierFlags = []
            for m in parts[1].split(separator: " ") {
                switch m {
                case "cmd": flags.insert(.command)
                case "shift": flags.insert(.shift)
                case "opt": flags.insert(.option)
                case "ctrl": flags.insert(.control)
                default: break
                }
            }
            RadialRecentsController.shared?.qaIngest(flags: flags)
            return
        }
        // `radial 90 [80]`: pointer 90° clockwise of 12 o'clock, 80 pt from where the ring opened.
        // `radial center`. `radial origin 400 300`: where the next ring opens.
        if parts[0] == "radial" {
            let args = parts[1].split(separator: " ").map(String.init)
            if args.first == "center" { RadialRecentsController.shared?.qaPointer(degrees: nil) }
            else if args.first == "origin", args.count == 3, let x = Double(args[1]), let y = Double(args[2]) {
                RadialRecentsController.shared?.qaOrigin(x: x, y: y)
            } else if let degrees = args.first.flatMap(Double.init) {
                RadialRecentsController.shared?.qaPointer(degrees: degrees, distance: args.count > 1 ? Double(args[1]) ?? 80 : 80)
            }
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

    private static func runTiling(_ verb: String, _ rest: String, _ state: AppState) {
        let args = rest.split(separator: " ", maxSplits: 1).map(String.init)
        func id(slot text: String?) -> DocumentPaneID? {
            guard let text, let n = Int(text), state.tiling.arrangement.visible.indices.contains(n - 1) else {
                Log.debug("qa: no pane in slot \(text ?? "?")"); return nil
            }
            return state.tiling.arrangement.visible[n - 1]
        }
        switch verb {
        case "tile":
            guard let layout = TileLayout(rawValue: rest) else { return Log.debug("qa: no layout \(rest)") }
            state.setLayout(layout)
        case "pane":
            if args.first == "close" { if let pane = id(slot: args.dropFirst().first) { state.closePane(pane) } }
            else if let pane = id(slot: args.first) { state.activatePane(pane); state.pane(pane).focusWhenReady() }
        default:
            guard let pane = id(slot: args.first), args.count == 2 else { return }
            state.launcher.qaLaunch(pane, args[1], state)
        }
    }

    private static func letter(_ code: UInt16) -> String {
        let map: [UInt16: String] = [0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h", 34: "i", 38: "j",
                                     40: "k", 37: "l", 46: "m", 45: "n", 31: "o", 35: "p", 12: "q", 15: "r", 1: "s",
                                     17: "t", 32: "u", 9: "v", 13: "w", 7: "x", 16: "y", 6: "z", 18: "1", 19: "2",
                                     20: "3", 21: "4", 23: "5", 33: "[", 30: "]", 42: "\\"]
        return map[code] ?? ""
    }

    private static func send(code: UInt16, chars: String, flags: NSEvent.ModifierFlags) {
        // The recent-files ring sees keys first, as its monitor would; Esc is consumed.
        if RadialRecentsController.shared?.qaIngest(keyCode: code) == true { return }
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
