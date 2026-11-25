import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts through Carbon's hot keys, which need no Accessibility permission.
@MainActor
final class Hotkeys {
    private var refs: [ShortcutAction: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private let action: (ShortcutAction) -> Void
    private static var current: Hotkeys?
    private static let actions = ShortcutAction.allCases

    init(action: @escaping (ShortcutAction) -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let index = Int(id.id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard Hotkeys.actions.indices.contains(index) else { return }
                    Hotkeys.current?.action(Hotkeys.actions[index])
                }
            }
            return noErr
        }, 1, &spec, nil, &handler)
        Hotkeys.current = self
    }

    /// Replaces every registered shortcut. Returns the actions whose shortcut another app already holds.
    func register(_ shortcuts: [ShortcutAction: Shortcut]) -> Set<ShortcutAction> {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs = [:]
        var taken: Set<ShortcutAction> = []
        for (action, shortcut) in shortcuts {
            let flags = shortcut.flags
            var modifiers: UInt32 = 0
            if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
            if flags.contains(.option) { modifiers |= UInt32(optionKey) }
            if flags.contains(.control) { modifiers |= UInt32(controlKey) }
            if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            let id = EventHotKeyID(signature: OSType(0x4241_4E47), id: UInt32(Self.actions.firstIndex(of: action)!))  // "BANG"
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(UInt32(shortcut.keyCode), modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs[action] = ref
            } else {
                taken.insert(action)
            }
        }
        return taken
    }
}
