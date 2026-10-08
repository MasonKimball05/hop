import Carbon.HIToolbox

/// A system-wide keyboard shortcut (⌥ Space by default).
///
/// Uses Carbon's RegisterEventHotKey, which is still how macOS apps register
/// global shortcuts: it needs no Accessibility permission, and the key press is
/// consumed so the frontmost app never sees it.
// Only used on the main thread (Carbon delivers its events there), so sharing it
// with the main-actor callback is safe.
final class HotKey: @unchecked Sendable {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: @MainActor () -> Void

    /// nil when the shortcut is already taken by another app.
    init?(keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers hot key events on the main thread.
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &spec, me, &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x484F_5021), id: 1) // "HOP!"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            handlerRef = nil // deinit still runs for a failed init
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
