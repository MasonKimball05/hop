import AppKit
import Carbon.HIToolbox
import HopCore
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = LauncherModel()
    private var panel: LauncherPanel!
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var clipboard: ClipboardMonitor!
    private let ask = AskModel()
    private var askPanel: AskPanel!
    private var askHotKey: HotKey?
    private var explainHotKey: HotKey?
    private var copyTextHotKey: HotKey?
    private var askAreaHotKey: HotKey?
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
        model.explainSelection = { [weak self] in self?.explainSelection() }
        model.copyTextFromScreen = { [weak self] in self?.copyTextFromScreen() }
        model.askAboutArea = { [weak self] in self?.askAboutArea() }
        model.findDeadlines = { [weak self] in self?.findDeadlines() }
        model.explainError = { [weak self] in self?.explainError() }

        hotKey = HotKey(keyCode: kVK_Space, modifiers: optionKey) { [weak self] in self?.togglePanel() }
        askHotKey = HotKey(keyCode: kVK_Space, modifiers: optionKey | shiftKey, id: 2) { [weak self] in self?.toggleAsk() }
        explainHotKey = HotKey(keyCode: kVK_ANSI_E, modifiers: controlKey | optionKey, id: 3) { [weak self] in self?.explainSelection() }
        copyTextHotKey = HotKey(keyCode: kVK_ANSI_C, modifiers: controlKey | optionKey, id: 4) { [weak self] in self?.copyTextFromScreen() }
        askAreaHotKey = HotKey(keyCode: kVK_ANSI_A, modifiers: controlKey | optionKey, id: 5) { [weak self] in self?.askAboutArea() }
        setUpStatusItem()
        errorWatcher.onChange = { [weak self] found in self?.showError(found) }
        showError(errorWatcher.found)
        if hotKey == nil {
            showAlert("\u{2325} Space is already in use",
                      "Another app has claimed \u{2325} Space. Hop still works from its menu bar icon.")
        }
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
        menu.addItem(withTitle: "Open Hop", action: #selector(openFromMenu), keyEquivalent: " ")
            .keyEquivalentModifierMask = [.option]
        menu.addItem(withTitle: "Ask Claude About Screen", action: #selector(openAsk), keyEquivalent: " ")
            .keyEquivalentModifierMask = [.option, .shift]
        menu.addItem(withTitle: "Explain Selection", action: #selector(explainFromMenu), keyEquivalent: "e")
            .keyEquivalentModifierMask = [.control, .option]
        menu.addItem(withTitle: "Ask About Area\u{2026}", action: #selector(askAboutAreaFromMenu), keyEquivalent: "a")
            .keyEquivalentModifierMask = [.control, .option]
        menu.addItem(withTitle: "Copy Text from Screen\u{2026}", action: #selector(copyTextFromMenu), keyEquivalent: "c")
            .keyEquivalentModifierMask = [.control, .option]
        menu.addItem(withTitle: "Due Dates to Daybook", action: #selector(findDeadlinesFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Clipboard History", action: #selector(openClipboard), keyEquivalent: "")
        menu.addItem(withTitle: "Clear Clipboard History", action: #selector(clearClipboard), keyEquivalent: "")
        menu.addItem(.separator())
        errorToggle = menu.addItem(withTitle: "Watch for Coding Errors", action: #selector(toggleErrorWatching(_:)), keyEquivalent: "")
        errorToggle.state = errorWatcher.isOn ? .on : .off
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
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
