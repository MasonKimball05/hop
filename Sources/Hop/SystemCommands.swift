import AppKit

/// Mac controls, found by name in the main search: "lock", "dark mode",
/// "bluetooth settings".
struct SystemCommand {
    enum Kind {
        case lockScreen, sleep, sleepDisplays, toggleDarkMode
        /// These go through loginwindow, which shows macOS's own "Are you sure?"
        /// dialog, so a stray Return can't restart the Mac.
        case restart, shutDown, logOut
        case settings(String)
    }

    let name: String
    let subtitle: String
    let symbol: String
    let actionName: String
    let kind: Kind

    static let all: [SystemCommand] = [
        SystemCommand(name: "Lock Screen", subtitle: "Lock the Mac now", symbol: "lock.fill", actionName: "Lock", kind: .lockScreen),
        SystemCommand(name: "Sleep", subtitle: "Put the Mac to sleep", symbol: "moon.zzz.fill", actionName: "Sleep", kind: .sleep),
        SystemCommand(name: "Sleep Displays", subtitle: "Turn the screens off, keep everything running", symbol: "display", actionName: "Sleep Displays", kind: .sleepDisplays),
        SystemCommand(name: "Toggle Dark Mode", subtitle: "Switch between light and dark appearance", symbol: "circle.lefthalf.filled", actionName: "Toggle", kind: .toggleDarkMode),
        SystemCommand(name: "Restart", subtitle: "macOS asks to confirm first", symbol: "restart", actionName: "Restart\u{2026}", kind: .restart),
        SystemCommand(name: "Shut Down", subtitle: "macOS asks to confirm first", symbol: "power", actionName: "Shut Down\u{2026}", kind: .shutDown),
        SystemCommand(name: "Log Out", subtitle: "macOS asks to confirm first", symbol: "rectangle.portrait.and.arrow.right", actionName: "Log Out\u{2026}", kind: .logOut),
    ] + settingsPanes.map { name, id in
        SystemCommand(name: name + " Settings", subtitle: "Open in System Settings", symbol: "gearshape", actionName: "Open Settings", kind: .settings(id))
    }

    /// System Settings panes by their URL identifiers (x-apple.systempreferences:<id>).
    static let settingsPanes: [(String, String)] = [
        ("Wi-Fi", "com.apple.wifi-settings-extension"),
        ("Bluetooth", "com.apple.BluetoothSettings"),
        ("Network", "com.apple.Network-Settings.extension"),
        ("Displays", "com.apple.Displays-Settings.extension"),
        ("Sound", "com.apple.Sound-Settings.extension"),
        ("Battery", "com.apple.Battery-Settings.extension"),
        ("Keyboard", "com.apple.Keyboard-Settings.extension"),
        ("Desktop & Dock", "com.apple.Desktop-Settings.extension"),
        ("Notifications", "com.apple.Notifications-Settings.extension"),
        ("Privacy & Security", "com.apple.settings.PrivacySecurity.extension"),
        ("Accessibility Permissions", "com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"),
        ("Language & Region", "com.apple.Localization-Settings.extension"),
        ("Software Update", "com.apple.Software-Update-Settings.extension"),
    ]
}

extension LauncherModel {
    func run(_ command: SystemCommand) {
        hide()
        switch command.kind {
        case .lockScreen:
            if !Self.lockScreen() { Task { _ = try? await Shell.run("/usr/bin/pmset", ["displaysleepnow"]) } }
        case .sleep:
            Task { _ = try? await Shell.run("/usr/bin/pmset", ["sleepnow"]) }
        case .sleepDisplays:
            Task { _ = try? await Shell.run("/usr/bin/pmset", ["displaysleepnow"]) }
        case .toggleDarkMode:
            runAppleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
        case .restart:
            runAppleScript("tell application \"loginwindow\" to \u{00AB}event aevtrrst\u{00BB}")
        case .shutDown:
            runAppleScript("tell application \"loginwindow\" to \u{00AB}event aevtrsdn\u{00BB}")
        case .logOut:
            runAppleScript("tell application \"loginwindow\" to \u{00AB}event aevtlogo\u{00BB}")
        case .settings(let id):
            if let url = URL(string: "x-apple.systempreferences:" + id) { NSWorkspace.shared.open(url) }
        }
    }

    /// The first run asks permission to control System Events / loginwindow
    /// (Privacy & Security ▸ Automation); after that it just works.
    private func runAppleScript(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 { // -128: the user cancelled
            NSLog("Hop AppleScript failed: \(error)")
        }
    }

    /// Locks immediately, like Control-Command-Q, via the private SACLockScreenImmediate
    /// in login.framework (what the menu bar's Lock Screen item uses). Returns false if
    /// a future macOS removes it, so the caller can fall back to sleeping the display.
    private static func lockScreen() -> Bool {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return false }
        typealias Lock = @convention(c) () -> Int32
        _ = unsafeBitCast(symbol, to: Lock.self)()
        return true
    }
}
