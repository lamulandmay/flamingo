import AppKit
import Carbon.HIToolbox

/// A system-wide hotkey via Carbon `RegisterEventHotKey`. Works without the Accessibility
/// permission. Several can be registered at once; each routes by its `EventHotKeyID`.
@MainActor
public final class GlobalHotkey {
    /// ⌃⌥Space, the contract's "leave a thought from any app".
    public static let captureKeyCode = UInt32(kVK_Space)
    public static let captureModifiers = UInt32(controlKey | optionKey)

    public static func capture(_ handler: @escaping () -> Void) -> GlobalHotkey {
        GlobalHotkey(keyCode: captureKeyCode, modifiers: captureModifiers, handler: handler)
    }

    public let keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
    public let modifiers: UInt32
    private let handler: () -> Void
    private let id: UInt32
    private var ref: EventHotKeyRef?

    public var isRegistered: Bool { ref != nil }

    public init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.handler = handler
        Self.nextID += 1
        self.id = Self.nextID
    }

    /// False when the combination is already taken by another app (`eventHotKeyExistsErr`)
    /// or Carbon refuses it. A shortcut the system itself owns (see
    /// `conflictsWithSystemShortcut`) may register fine and still never fire.
    @discardableResult
    public func register() -> Bool {
        if ref != nil { return true }
        guard Self.installHandler() else { return false }
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let newRef else { return false }
        ref = newRef
        Self.registry[id] = self
        return true
    }

    public func unregister() {
        guard let r = ref else { return }
        UnregisterEventHotKey(r)
        ref = nil
        Self.registry[id] = nil
    }

    /// True when an enabled macOS keyboard shortcut (System Settings › Keyboard › Shortcuts)
    /// already uses this combination, e.g. ⌃⌥Space for "Select next source in Input menu".
    public static func conflictsWithSystemShortcut(keyCode: UInt32, modifiers: UInt32) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let list = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }
        let relevant = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        return list.contains { d in
            (d[kHISymbolicHotKeyEnabled as String] as? Bool) == true
                && (d[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value == keyCode
                && ((d[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value ?? 0) & relevant == modifiers & relevant
        }
    }

    // MARK: Carbon plumbing

    private static let signature: OSType = 0x464C_4D47 // 'FLMG'
    private static var nextID: UInt32 = 0
    private static var registry: [UInt32: GlobalHotkey] = [:]
    private static var handlerRef: EventHandlerRef?

    private static func installHandler() -> Bool {
        if handlerRef != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard err == noErr, hk.signature == GlobalHotkey.signature else { return OSStatus(eventNotHandledErr) }
            let id = hk.id
            if Thread.isMainThread {
                MainActor.assumeIsolated { GlobalHotkey.fire(id) }
            } else {
                Task { @MainActor in GlobalHotkey.fire(id) }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        return status == noErr
    }

    private static func fire(_ id: UInt32) {
        registry[id]?.handler()
    }
}
