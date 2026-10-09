import AppKit
import ApplicationServices

/// Pastes into the frontmost app by sending ⌘V, which needs Accessibility
/// permission. Without it, the text is still on the clipboard to paste by hand.
enum Paster {
    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Privacy & Security ▸ Accessibility.
    static func requestPermission() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func pressCommandV() {
        pressCommand(key: 9)
    }

    /// ⌘ plus a key, by virtual key code (9 is V, 8 is C), sent to the frontmost app.
    static func pressCommand(key: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
