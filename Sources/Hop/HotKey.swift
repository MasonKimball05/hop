import Carbon.HIToolbox

/// A system-wide keyboard shortcut (⌥ Space for the launcher, ⌥⇧ Space for Ask Claude).
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
    private let release: (@MainActor () -> Void)?
    private let id: UInt32

    /// nil when the shortcut is already taken by another app. Each shortcut needs its own
    /// `id`. `release`, when given, runs when the keys are let go (for hold-to-talk).
    init?(keyCode: Int, modifiers: Int, id: UInt32 = 1, action: @escaping @MainActor () -> Void,
          release: (@MainActor () -> Void)? = nil) {
        self.action = action
        self.release = release
        self.id = id
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            // Every handler sees every shortcut; pass on the ones that aren't this one.
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard pressed.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            if released && hotKey.release == nil { return noErr }
            // Carbon delivers hot key events on the main thread.
            MainActor.assumeIsolated { if released { hotKey.release?() } else { hotKey.action() } }
            return noErr
        }, 2, &specs, me, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x484F_5021), id: id) // "HOP!"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
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
