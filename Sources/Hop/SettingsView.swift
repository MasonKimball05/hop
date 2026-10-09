import AppKit
import HopCore
import SwiftUI

/// What the Settings window changes that lives outside user defaults: the shortcuts
/// (registered by the app delegate) and the state of models already running.
@MainActor
@Observable
final class SettingsModel {
    private(set) var shortcuts = Shortcuts.load()
    /// Shortcuts another app already has, so Hop couldn't register them.
    var taken: Set<ShortcutAction> = []
    private(set) var recording: ShortcutAction?
    var recordingMessage: String?

    /// Set by the app delegate.
    @ObservationIgnored var applyShortcuts: () -> Set<ShortcutAction> = { [] }
    @ObservationIgnored var pauseShortcuts: () -> Void = {}
    @ObservationIgnored private var monitor: Any?

    func startRecording(_ action: ShortcutAction) {
        stopRecording()
        recording = action
        recordingMessage = nil
        // Hop's own shortcuts would otherwise catch the keys before they get here.
        pauseShortcuts()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) }
            return nil
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording != nil else { return }
        recording = nil
        taken = applyShortcuts()
    }

    func resetToDefaults() {
        stopRecording()
        shortcuts = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, .some($0.defaultShortcut)) })
        Shortcuts.save(shortcuts)
        taken = applyShortcuts()
    }

    private static let functionKeys: [Int: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
    private static let namedKeys: [Int: String] = [
        49: "Space", 36: "\u{21A9}", 48: "\u{21E5}", 123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
    ]

    private func record(_ event: NSEvent) {
        guard let action = recording else { return }
        let code = Int(event.keyCode)
        switch code {
        case 53: return stopRecording() // Escape: leave it as it was
        case 51, 117:                   // Delete: no shortcut
            return set(action, to: nil)
        default: break
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers = 0
        if flags.contains(.control) { modifiers |= Shortcut.control }
        if flags.contains(.option) { modifiers |= Shortcut.option }
        if flags.contains(.shift) { modifiers |= Shortcut.shift }
        if flags.contains(.command) { modifiers |= Shortcut.command }
        let functionKey = Self.functionKeys[code]
        // Shift alone would steal a capital letter from every app.
        guard functionKey != nil || modifiers & (Shortcut.control | Shortcut.option | Shortcut.command) != 0 else {
            recordingMessage = "Include \u{2303}, \u{2325} or \u{2318} (or use a function key)."
            return
        }
        let key = functionKey ?? Self.namedKeys[code] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        let shortcut = Shortcut(keyCode: code, modifiers: modifiers, key: key)
        if let other = shortcuts.first(where: { $0.key != action && $0.value == shortcut })?.key {
            recordingMessage = "\(shortcut.display) is already \(other.title)."
            return
        }
        set(action, to: shortcut)
    }

    private func set(_ action: ShortcutAction, to shortcut: Shortcut?) {
        shortcuts[action] = .some(shortcut)
        Shortcuts.save(shortcuts)
        stopRecording()
    }
}

struct SettingsView: View {
    @Bindable var settings: SettingsModel
    @Bindable var ask: AskModel
    let errorHelper: Binding<Bool>

    @AppStorage("claudeModel") private var model = ""
    @AppStorage("askMemoryHours") private var memoryHours = 3.0
    @AppStorage("watchIdleMinutes") private var watchMinutes = 20
    @AppStorage("claudePath") private var claudePath = ""
    @AppStorage("notesFolder") private var notesFolder = ""

    var body: some View {
        Form {
            Section("Ask Claude") {
                Picker("Model", selection: $model) {
                    Text("Claude Code\u{2019}s default").tag("")
                    Text("Sonnet (fast, good for most)").tag("sonnet")
                    Text("Haiku (fastest)").tag("haiku")
                    Text("Opus (hardest problems)").tag("opus")
                }
                Stepper(value: $memoryHours, in: 1...24, step: 1) {
                    Text("Remember a conversation for \(Int(memoryHours)) hour\(memoryHours == 1 ? "" : "s") with nothing asked")
                }
                Stepper(value: $watchMinutes, in: 5...120, step: 5) {
                    Text("Stop watching after \(watchMinutes) minutes with nothing new")
                }
                Toggle("Tutor mode: guide and check instead of answering", isOn: $ask.isTutoring)
                LabeledContent("Claude Code") {
                    HStack {
                        Text(ClaudeCLI.locate(override: claudePath)?.path ?? "Not found")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose\u{2026}") { claudePath = choose(directory: false) ?? claudePath }
                        if !claudePath.isEmpty { Button("Use Default") { claudePath = "" } }
                    }
                }
            }

            Section("Study notes") {
                Toggle("Take notes: add each answer to today\u{2019}s file", isOn: $ask.isTakingNotes)
                LabeledContent("Folder") {
                    HStack {
                        Text(StudyNotes.defaultFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose\u{2026}") { notesFolder = choose(directory: true) ?? notesFolder }
                        if !notesFolder.isEmpty { Button("Use Default") { notesFolder = "" } }
                    }
                }
            }

            Section("Error helper") {
                Toggle("Watch terminals and IDEs for errors", isOn: errorHelper)
            }

            Section {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        HStack(spacing: 8) {
                            if settings.taken.contains(action) {
                                Text("Another app has this").font(.system(size: 11)).foregroundStyle(.red)
                            }
                            Button(settings.recording == action ? "Type a shortcut\u{2026}" : (settings.shortcuts[action] ?? nil)?.display ?? "None") {
                                if settings.recording == action { settings.stopRecording() } else { settings.startRecording(action) }
                            }
                            .monospacedDigit()
                            .frame(minWidth: 130)
                        }
                    }
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                HStack {
                    Text(settings.recordingMessage ?? "Click one, then press the new keys. Escape cancels; Delete turns it off.")
                        .font(.system(size: 11))
                        .foregroundStyle(settings.recordingMessage == nil ? Color.secondary : .orange)
                    Spacer()
                    Button("Reset to Defaults", action: settings.resetToDefaults)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { settings.stopRecording() }
    }

    private func choose(directory: Bool) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.canCreateDirectories = directory
        panel.showsHiddenFiles = !directory
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
