import AppKit
import HopCore

/// Watches the system clipboard for new text. macOS has no "clipboard changed"
/// notification, so this checks the pasteboard's change counter twice a second,
/// which is how every clipboard manager does it (the check is one integer read).
@MainActor
final class ClipboardMonitor {
    private let pasteboard = NSPasteboard.general
    private var lastChange: Int
    private var timer: Timer?
    private let onCopy: (String) -> Void

    init(onCopy: @escaping (String) -> Void) {
        self.onCopy = onCopy
        lastChange = pasteboard.changeCount // don't record what was copied before launch
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// Writes text to the clipboard without recording it again.
    func write(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChange = pasteboard.changeCount
    }

    private func poll() {
        let change = pasteboard.changeCount
        guard change != lastChange else { return }
        lastChange = change
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        // Password managers mark secrets so clipboard tools skip them.
        guard types.isDisjoint(with: ClipboardHistory.privateTypes),
              let text = pasteboard.string(forType: .string) else { return }
        onCopy(text)
    }
}
