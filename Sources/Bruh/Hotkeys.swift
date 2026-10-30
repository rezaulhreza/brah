import Carbon.HIToolbox
import BruhCore
import Foundation

/// System-wide hotkeys through Carbon. They need no Accessibility permission and work in the
/// App Sandbox, so they stay when Bruh moves to the App Store. A hotkey reports both the press
/// and the release, which is what hold-to-talk needs.
enum Hotkeys {
    private struct Actions {
        var press: () -> Void
        var release: (() -> Void)?
    }

    private static var actions: [UInt32: Actions] = [:]
    private static var refs: [EventHotKeyRef?] = []
    private static var installed = false

    static func register(_ shortcut: Shortcut, onRelease: (() -> Void)? = nil, onPress: @escaping () -> Void) {
        register(shortcut.keyCode, modifiers: shortcut.modifiers, onRelease: onRelease, onPress: onPress)
    }

    static func register(_ keyCode: Int, modifiers: Int, onRelease: (() -> Void)? = nil, onPress: @escaping () -> Void) {
        installIfNeeded()
        let id = UInt32(actions.count + 1)
        actions[id] = Actions(press: onPress, release: onRelease)

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4252_5548), id: id) // "BRUH"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }

    /// Give every key back to the system: for new shortcuts, and while the key recorder listens.
    static func unregisterAll() {
        refs.compactMap { $0 }.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
    }

    private static func installIfNeeded() {
        guard !installed else { return }
        installed = true

        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async {
                guard let action = Hotkeys.actions[id] else { return }
                if pressed {
                    action.press()
                } else {
                    action.release?()
                }
            }
            return noErr
        }, specs.count, &specs, nil, nil)
    }
}
