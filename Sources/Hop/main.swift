import AppKit

// Ask Claude writes to a `claude` CLI that may have exited; without this, writing
// to its closed pipe would kill Hop instead of failing that one write.
signal(SIGPIPE, SIG_IGN)

// Hop lives in the menu bar: no Dock icon, no main window, just the panel.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
