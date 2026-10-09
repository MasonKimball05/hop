import AppKit
import SwiftUI

/// The Ask Claude window. Non-activating like the launcher, so typing in it doesn't
/// pull you out of the app you're asking about, but unlike the launcher it stays up
/// when you click elsewhere: you can follow its steps with it floating alongside.
final class AskPanel: NSPanel {
    static let defaultSize = NSSize(width: 420, height: 560)

    init<Content: View>(rootView: Content) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                   styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "Ask Claude"
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        minSize = NSSize(width: 320, height: 300)
        contentView = NSHostingView(rootView: rootView)

        // Where I last left it; the top right of the screen the first time.
        if !setFrameUsingName("AskClaude"), let visible = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: visible.maxX - Self.defaultSize.width - 16, y: visible.maxY - Self.defaultSize.height - 16))
        }
        setFrameAutosaveName("AskClaude")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Escape hides it; the conversation stays for next time.
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    func show() {
        makeKeyAndOrderFront(nil)
    }
}
