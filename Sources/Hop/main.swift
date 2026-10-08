import AppKit

// Hop lives in the menu bar: no Dock icon, no main window, just the panel.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
