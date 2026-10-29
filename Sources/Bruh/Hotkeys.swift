import Carbon.HIToolbox
import Foundation

/// System-wide hotkeys through Carbon. They need no Accessibility permission and work in the
/// App Sandbox, so they stay when Bruh moves to the App Store.
enum Hotkeys {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef?] = []
    private static var installed = false

    static let control = controlKey
    static let option = optionKey

    static func register(_ keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        installIfNeeded()
        let id = UInt32(actions.count + 1)
        actions[id] = action

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4252_5548), id: id) // "BRUH"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }

    private static func installIfNeeded() {
        guard !installed else { return }
        installed = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { Hotkeys.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
