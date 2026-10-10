import AppKit
import HopCore
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = LauncherModel()
    private var panel: LauncherPanel!
    private var statusItem: NSStatusItem!
    private var clipboard: ClipboardMonitor!
    private let ask = AskModel()
    private var askPanel: AskPanel!
    private var hotKeys: [ShortcutAction: HotKey] = [:]
    /// Menu items that show a shortcut, kept in step with Settings.
    private var shortcutItems: [ShortcutAction: NSMenuItem] = [:]
    private let settings = SettingsModel()
    private var settingsWindow: NSWindow?
    private let errorWatcher = ErrorWatcher()
    private var errorItem: NSMenuItem!
    private var errorToggle: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = LauncherPanel(rootView: LauncherView(model: model))
        panel.onResignKey = { [weak self] in self?.hidePanel() }

        clipboard = ClipboardMonitor { [weak self] text in self?.model.addClip(text) }
        model.hide = { [weak self] in self?.hidePanel() }
        model.paste = { [weak self] text in self?.paste(text) }

        askPanel = AskPanel(rootView: AskView(model: ask))
        ask.close = { [weak self] in self?.askPanel.orderOut(nil) }
        ask.isPanelVisible = { [weak self] in self?.askPanel.isVisible ?? false }
        model.ask = { [weak self] question in self?.showAsk(question) }
        ask.pasteIntoApp = { [weak self] text in self?.pasteFromAsk(text) }
        model.explainSelection = { [weak self] in self?.explainSelection() }
        model.copyTextFromScreen = { [weak self] in self?.copyTextFromScreen() }
        model.askAboutArea = { [weak self] in self?.askAboutArea() }
        model.findDeadlines = { [weak self] in self?.findDeadlines() }
        model.explainError = { [weak self] in self?.explainError() }

        model.openSettings = { [weak self] in self?.openSettings() }
        model.askAboutFile = { [weak self] url in
            self?.showAsk()
            self?.ask.attach(file: url)
        }
        model.askHistory = { [weak self] in
            self?.showAsk()
            if self?.ask.showingHistory == false { self?.ask.toggleHistory() }
        }
        model.quiz = { [weak self] in
            guard let self else { return }
            showAsk()
            // Today's notes when there are some, else what's been asked so far.
            if let today = ask.recentNotes.first, Calendar.current.isDateInToday(
                (try? today.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) {
                ask.startQuiz(.notes(today))
            } else {
                ask.startQuiz(.conversation)
            }
        }
        model.rewrite = { [weak self] kind, text in
            self?.showAsk()
            self?.ask.rewrite(kind, text)
        }

        setUpStatusItem()
        settings.applyShortcuts = { [weak self] in self?.registerShortcuts() ?? [] }
        settings.pauseShortcuts = { [weak self] in self?.hotKeys = [:] }
        let taken = registerShortcuts()
        settings.taken = taken
        errorWatcher.onChange = { [weak self] found in self?.showError(found) }
        showError(errorWatcher.found)
        if !taken.isEmpty {
            let names = taken.map { "\($0.title) (\(Shortcuts.display($0)))" }.sorted().joined(separator: ", ")
            showAlert("Some shortcuts are already in use",
                      "Another app has claimed: \(names). Pick different keys in Hop\u{2019}s Settings; everything also works from the menu bar icon.")
        }
    }

    // MARK: Shortcuts

    /// Registers every shortcut from Settings; returns the ones another app already has.
    @discardableResult
    private func registerShortcuts() -> Set<ShortcutAction> {
        hotKeys = [:] // unregisters the old ones first
        var taken: Set<ShortcutAction> = []
        for (index, action) in ShortcutAction.allCases.enumerated() {
            let shortcut = Shortcuts.load()[action] ?? nil
            updateMenu(action, shortcut)
            guard let shortcut else { continue }
            let id = UInt32(index + 1)
            let hotKey = switch action {
            case .launcher: HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, id: id) { [weak self] in self?.togglePanel() }
            case .ask: HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, id: id) { [weak self] in self?.toggleAsk() }
            case .explain: HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, id: id) { [weak self] in self?.explainSelection() }
            case .askArea: HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, id: id) { [weak self] in self?.askAboutArea() }
            case .copyText: HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, id: id) { [weak self] in self?.copyTextFromScreen() }
            case .pasteAnswer: HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, id: id) { [weak self] in self?.ask.pasteLatestAnswer() }
            // Hold to talk: listens while held, asks when let go.
            case .talk: HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, id: id,
                               action: { [weak self] in self?.showAsk(); self?.ask.startListening() },
                               release: { [weak self] in self?.ask.stopListening(send: true) })
            }
            if let hotKey { hotKeys[action] = hotKey } else { taken.insert(action) }
        }
        return taken
    }

    /// Shows a shortcut next to its menu item (menus only show single-character keys).
    private func updateMenu(_ action: ShortcutAction, _ shortcut: Shortcut?) {
        guard let item = shortcutItems[action] else { return }
        guard let shortcut, shortcut.key == "Space" || shortcut.key.count == 1 else {
            item.keyEquivalent = ""
            return
        }
        item.keyEquivalent = shortcut.key == "Space" ? " " : shortcut.key.lowercased()
        var flags: NSEvent.ModifierFlags = []
        if shortcut.modifiers & Shortcut.control != 0 { flags.insert(.control) }
        if shortcut.modifiers & Shortcut.option != 0 { flags.insert(.option) }
        if shortcut.modifiers & Shortcut.shift != 0 { flags.insert(.shift) }
        if shortcut.modifiers & Shortcut.command != 0 { flags.insert(.command) }
        item.keyEquivalentModifierMask = flags
    }

    // MARK: Settings

    @objc private func openSettings() {
        if settingsWindow == nil {
            let errorHelper = Binding<Bool>(
                get: { [weak self] in self?.errorWatcher.isOn ?? false },
                set: { [weak self] on in
                    self?.errorWatcher.isOn = on
                    self?.errorToggle.state = on ? .on : .off
                })
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(settings: settings, ask: ask, errorHelper: errorHelper)))
            window.title = "Hop Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        hidePanel()
        // Hop has no Dock icon, so it has to come forward for the window to take typing.
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Panel

    private func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    private func showPanel() {
        model.didOpen()
        panel.show()
    }

    private func hidePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// Puts the text on the clipboard, then sends ⌘V to the app that was in front.
    /// The panel never activated Hop, so that app is still frontmost.
    private func paste(_ text: String) {
        clipboard.write(text)
        guard Paster.isAllowed else {
            Paster.requestPermission()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Paster.pressCommandV() }
    }

    /// Pastes an Ask Claude answer where you were typing. The Ask window steps aside so
    /// the keyboard goes back to that app, then comes back without taking it.
    private func pasteFromAsk(_ text: String) {
        let wasVisible = askPanel.isVisible
        askPanel.orderOut(nil)
        paste(text)
        if !Paster.isAllowed { Toast.show("Copied. Allow Hop under Accessibility to paste it for you", symbol: "doc.on.clipboard") }
        if wasVisible {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.askPanel.orderFront(nil) }
        }
    }

    // MARK: Ask Claude

    /// Shows the Ask window, and sends `question` with a screenshot when there is one.
    private func showAsk(_ question: String? = nil) {
        hidePanel()
        askPanel.show()
        ask.didShow()
        if let question { ask.send(question) }
    }

    /// Reads the selection in the app you're using and asks Claude to explain it.
    private func explainSelection() {
        // The selection has to be read from that app, so Hop's own windows give up
        // the keyboard first; the Ask window comes back with the answer.
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        let wasFocused = panel.isKeyWindow || askPanel.isKeyWindow
        hidePanel()
        if askPanel.isKeyWindow { askPanel.orderOut(nil) }
        Task {
            if wasFocused { try? await Task.sleep(for: .milliseconds(150)) }
            let text = await Selection.read(clipboard: clipboard)
            showAsk()
            ask.explain(text, from: app)
        }
    }

    // MARK: Areas of the screen

    /// Drag over anything on screen and its text goes to the clipboard, read on this Mac.
    private func copyTextFromScreen() {
        hidePanel()
        Task {
            guard let image = await ScreenRegion.pick() else { return }
            let lines = await TextRecognition.lines(in: image, fast: false)
            guard !lines.isEmpty else { return Toast.show("No text found there", symbol: "text.badge.xmark") }
            let text = lines.joined(separator: "\n")
            // Through the clipboard as usual, so it lands in clipboard history too.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Toast.show(lines.count == 1 ? "Copied: \(ClaudeCLI.selectionPreview(text, length: 40))" : "Copied \(lines.count) lines")
        }
    }

    /// Drag over part of the screen and attach it to the next Ask Claude question:
    /// for an equation, a diagram, or one question out of a busy page.
    private func askAboutArea() {
        hidePanel()
        Task {
            guard let image = await ScreenRegion.pick() else { return }
            showAsk()
            ask.attach(area: image)
        }
    }

    /// Due dates on the window you're using, listed in Ask Claude to add to Daybook.
    private func findDeadlines() {
        showAsk()
        ask.findDeadlines()
    }

    // MARK: Error helper

    /// A spotted error turns the hare orange and puts "Explain Error" at the top of its menu.
    private func showError(_ found: ErrorWatcher.Found?) {
        statusItem.button?.image = NSImage(systemSymbolName: found == nil ? "hare" : "hare.fill", accessibilityDescription: "Hop")
        statusItem.button?.contentTintColor = found == nil ? nil : .systemOrange
        errorItem.isHidden = found == nil
        if let found {
            let place = found.app.map { " in \($0)" } ?? ""
            errorItem.title = "Explain Error\(place): \(ClaudeCLI.selectionPreview(found.preview, length: 50))"
        }
    }

    private func explainError() {
        guard let found = errorWatcher.take() else {
            return Toast.show(errorWatcher.isOn ? "No error spotted" : "Turn on Watch for Coding Errors in the menu bar first",
                              symbol: "checkmark.circle")
        }
        showAsk()
        ask.explainError(found)
    }

    @objc private func explainErrorFromMenu() { explainError() }

    @objc private func toggleErrorWatching(_ item: NSMenuItem) {
        errorWatcher.isOn.toggle()
        item.state = errorWatcher.isOn ? .on : .off
    }

    private func toggleAsk() {
        if askPanel.isVisible && askPanel.isKeyWindow { askPanel.orderOut(nil) } else { showAsk() }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "hare", accessibilityDescription: "Hop")
        let menu = NSMenu()
        errorItem = menu.addItem(withTitle: "Explain Error", action: #selector(explainErrorFromMenu), keyEquivalent: "")
        errorItem.image = NSImage(systemSymbolName: "exclamationmark.bubble.fill", accessibilityDescription: nil)
        errorItem.isHidden = true
        shortcutItems[.launcher] = menu.addItem(withTitle: "Open Hop", action: #selector(openFromMenu), keyEquivalent: "")
        shortcutItems[.ask] = menu.addItem(withTitle: "Ask Claude About Screen", action: #selector(openAsk), keyEquivalent: "")
        shortcutItems[.explain] = menu.addItem(withTitle: "Explain Selection", action: #selector(explainFromMenu), keyEquivalent: "")
        shortcutItems[.askArea] = menu.addItem(withTitle: "Ask About Area\u{2026}", action: #selector(askAboutAreaFromMenu), keyEquivalent: "")
        shortcutItems[.copyText] = menu.addItem(withTitle: "Copy Text from Screen\u{2026}", action: #selector(copyTextFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Due Dates to Daybook", action: #selector(findDeadlinesFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Clipboard History", action: #selector(openClipboard), keyEquivalent: "")
        menu.addItem(withTitle: "Clear Clipboard History", action: #selector(clearClipboard), keyEquivalent: "")
        menu.addItem(.separator())
        errorToggle = menu.addItem(withTitle: "Watch for Coding Errors", action: #selector(toggleErrorWatching(_:)), keyEquivalent: "")
        errorToggle.state = errorWatcher.isOn ? .on : .off
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Hop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
    }

    @objc private func openFromMenu() { showPanel() }

    @objc private func openAsk() { showAsk() }

    @objc private func explainFromMenu() { explainSelection() }

    @objc private func askAboutAreaFromMenu() { askAboutArea() }

    @objc private func copyTextFromMenu() { copyTextFromScreen() }

    @objc private func findDeadlinesFromMenu() { findDeadlines() }

    @objc private func openClipboard() {
        showPanel()
        model.enter(.clipboard)
    }

    @objc private func clearClipboard() { model.clearClipboardHistory() }

    @objc private func toggleLaunchAtLogin(_ item: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert("Couldn\u{2019}t change Launch at Login", error.localizedDescription)
        }
        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func showAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate()
        alert.runModal()
    }
}
