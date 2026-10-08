import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = LauncherModel()
    private var panel: LauncherPanel!
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var clipboard: ClipboardMonitor!

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = LauncherPanel(rootView: LauncherView(model: model))
        panel.onResignKey = { [weak self] in self?.hidePanel() }

        clipboard = ClipboardMonitor { [weak self] text in self?.model.addClip(text) }
        model.hide = { [weak self] in self?.hidePanel() }
        model.paste = { [weak self] text in self?.paste(text) }

        hotKey = HotKey(keyCode: kVK_Space, modifiers: optionKey) { [weak self] in self?.togglePanel() }
        setUpStatusItem()
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

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "hare", accessibilityDescription: "Hop")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Hop", action: #selector(openFromMenu), keyEquivalent: " ")
            .keyEquivalentModifierMask = [.option]
        menu.addItem(withTitle: "Clipboard History", action: #selector(openClipboard), keyEquivalent: "")
        menu.addItem(withTitle: "Clear Clipboard History", action: #selector(clearClipboard), keyEquivalent: "")
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Hop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
    }

    @objc private func openFromMenu() { showPanel() }

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
