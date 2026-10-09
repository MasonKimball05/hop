import AppKit
import ApplicationServices

/// Reads the text selected in the frontmost app, for Explain Selection. Both ways
/// need Accessibility permission, which Hop already asks for to paste.
@MainActor
enum Selection {
    /// Accessibility first, which leaves the clipboard alone. Apps that don't expose
    /// their selection that way (some browsers and Electron apps) get a ⌘C instead,
    /// and the clipboard is put back afterwards.
    static func read(clipboard: ClipboardMonitor) async -> String? {
        guard Paster.isAllowed else {
            Paster.requestPermission()
            return nil
        }
        if let text = viaAccessibility() { return text }
        return await viaCopy(clipboard)
    }

    private static func viaAccessibility() -> String? {
        let system = AXUIElementCreateSystemWide()
        // A hung app would otherwise block for the default 6 seconds.
        AXUIElementSetMessagingTimeout(system, 0.5)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static func viaCopy(_ clipboard: ClipboardMonitor) async -> String? {
        let pasteboard = NSPasteboard.general
        // Everything on the clipboard now, every type, to put back after.
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        clipboard.pause()
        defer { clipboard.resume() }

        let before = pasteboard.changeCount
        Paster.pressCommand(key: 8) // C
        for _ in 0..<12 where pasteboard.changeCount == before {
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard pasteboard.changeCount != before else { return nil } // nothing selected
        let text = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
