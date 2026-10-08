import AppKit
import SwiftUI

/// The floating search window. It's a non-activating panel, like Spotlight's:
/// it takes keyboard focus without making Hop the active app, so the app you
/// were using stays frontmost and a pasted clipboard item lands there.
final class LauncherPanel: NSPanel {
    static let size = NSSize(width: 720, height: 460)

    /// Called when the panel loses focus (a click elsewhere) so it can hide.
    var onResignKey: (() -> Void)?

    init<Content: View>(rootView: Content) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow

        let host = NSHostingView(rootView: rootView)
        host.frame = NSRect(origin: .zero, size: Self.size)
        contentView = host
    }

    // A borderless panel refuses keyboard focus unless told otherwise.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// Centered horizontally on the screen with the mouse, a little above middle.
    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let origin = NSPoint(x: visible.midX - Self.size.width / 2,
                                 y: visible.maxY - Self.size.height - visible.height * 0.18)
            setFrameOrigin(origin)
        }
        makeKeyAndOrderFront(nil)
    }
}
