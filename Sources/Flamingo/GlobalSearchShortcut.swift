import AppKit
import Carbon.HIToolbox
import FlamingoCapture

/// Uses the existing native hotkey registrar without changing macOS shortcuts or
/// requesting Accessibility access. A conflicting shortcut remains with its owner.
@MainActor
final class GlobalSearchShortcut {
    private static let defaultsKey = "searchFromAnyApp"
    private let hotkey: GlobalHotkey
    var isEnabled: Bool { hotkey.isRegistered }

    init(handler: @escaping () -> Void) {
        hotkey = GlobalHotkey(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(controlKey | optionKey), handler: handler)
    }

    func install() {
        if UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true {
            _ = enable()
        }
    }

    /// False means macOS or another application owns Control-Option-F.
    @discardableResult
    func toggle() -> Bool {
        if isEnabled {
            hotkey.unregister()
            UserDefaults.standard.set(false, forKey: Self.defaultsKey)
            return true
        }
        let registered = enable()
        if registered { UserDefaults.standard.set(true, forKey: Self.defaultsKey) }
        return registered
    }

    func uninstall() { hotkey.unregister() }

    private func enable() -> Bool {
        guard !GlobalHotkey.conflictsWithSystemShortcut(keyCode: hotkey.keyCode, modifiers: hotkey.modifiers) else { return false }
        return hotkey.register()
    }
}
