import Carbon
import ClippeekCore
import Foundation

/// A system-wide shortcut via Carbon's hot key API, which needs no Accessibility permission.
@MainActor
final class HotKey {
    static var action: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var current: KeyCombo?
    private var registered = true

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.action?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Returns false when another app already owns the combination.
    @discardableResult
    func register(_ combo: KeyCombo?) -> Bool {
        // Called on every model change, so a taken combination isn't retried until it changes.
        if combo == current { return registered }
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        current = combo
        registered = true
        guard let combo else { return true }
        let id = EventHotKeyID(signature: OSType(0x434C_504B), id: 1)
        registered = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr
        return registered
    }
}
