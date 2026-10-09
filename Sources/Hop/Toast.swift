import AppKit
import SwiftUI

/// A short message near the bottom of the screen that fades by itself, for things
/// done without opening a window ("Copied 4 lines").
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ text: String, symbol: String = "checkmark.circle.fill") {
        hideTask?.cancel()
        panel?.orderOut(nil)

        let view = Label(text, systemImage: symbol)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .fixedSize()
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let toast = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        toast.contentView = host
        toast.isOpaque = false
        toast.backgroundColor = .clear
        toast.level = .statusBar
        toast.ignoresMouseEvents = true
        toast.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let mouse = NSEvent.mouseLocation
        if let visible = (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)?.visibleFrame {
            toast.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 80))
        }
        toast.orderFrontRegardless()
        panel = toast

        hideTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { $0.duration = 0.3; toast.animator().alphaValue = 0 }
            toast.orderOut(nil)
        }
    }
}
