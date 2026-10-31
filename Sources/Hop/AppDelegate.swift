import AppKit
import HopCore
import ServiceManagement
import SwiftUI
import UserNotifications

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
    private let focus = FocusTimer()
    private let eclipseWatcher = EclipseWatcher()
    /// The Eclipse updates at the top of the menu (with their heading and a separator).
    private var eclipseItems: [NSMenuItem] = []
    private var focusItems: [NSMenuItem] = []
    private var errorItem: NSMenuItem!
    private var errorToggle: NSMenuItem!
    private var spottedError: ErrorWatcher.Found?
    private var answerItem: NSMenuItem!
    private var watchItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        TextRecognition.warmUp()
        panel = LauncherPanel(rootView: LauncherView(model: model))
        panel.onResignKey = { [weak self] in self?.hidePanel() }

        clipboard = ClipboardMonitor { [weak self] text in self?.model.addClip(text) }
        model.hide = { [weak self] in self?.hidePanel() }
        model.paste = { [weak self] text in self?.paste(text) }

        askPanel = AskPanel(rootView: AskView(model: ask))
        ask.close = { [weak self] in self?.askPanel.orderOut(nil) }
        ask.isPanelVisible = { [weak self] in self?.askPanel.isVisible ?? false }
        ask.statusChanged = { [weak self] in self?.updateStatusItem() }
        ask.repliedWhileHidden = { [weak self] isError in self?.notifyReply(isError: isError) }
        UNUserNotificationCenter.current().delegate = self
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
        model.startFocus = { [weak self] minutes, label in self?.startFocus(minutes: minutes, label: label) }
        model.endFocus = { [weak self] in self?.focus.finish() }
        model.cancelFocus = { [weak self] in self?.focus.cancel() }
        model.focusStatus = { [weak self] in
            guard let self, let session = focus.session else { return nil }
            return (session.label, focus.remaining)
        }
        model.showBrief = { [weak self] in self?.showBrief() }
        model.askAboutPage = { [weak self] in
            self?.showAsk()
            self?.ask.attachEclipsePage()
        }
        model.quizOnPage = { [weak self] in
            self?.showAsk()
            self?.ask.startQuiz(.page(url: nil, title: nil))
        }
        focus.onTick = { [weak self] session, remaining in self?.showFocus(session, remaining) }
        eclipseWatcher.onChange = { [weak self] updates in self?.showEclipseUpdates(updates) }
        eclipseWatcher.start()
        focus.resume()
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
            let eclipseUpdates = Binding<Bool>(
                get: { [weak self] in self?.eclipseWatcher.isOn ?? false },
                set: { [weak self] on in self?.eclipseWatcher.isOn = on })
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(settings: settings, ask: ask, errorHelper: errorHelper, eclipseUpdates: eclipseUpdates)))
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
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.replyNotification])
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

    // MARK: Focus timer

    /// The countdown next to the hare, and its menu items, while a focus runs.
    private func showFocus(_ session: FocusTimer.Session?, _ remaining: Int) {
        guard let button = statusItem.button else { return }
        if let session {
            statusItem.length = NSStatusItem.variableLength
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(string: " " + Focus.clock(remaining), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)])
            let what = session.label.map { " on \($0)" } ?? ""
            focusItems.first?.title = "Focus\(what): \(Focus.clock(remaining)) left"
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            statusItem.length = NSStatusItem.squareLength
        }
        focusItems.forEach { $0.isHidden = session == nil }
    }

    private func startFocus(minutes: Int, label: String?) {
        focus.start(minutes: minutes, label: label, space: model.focusSpace(for: label))
    }

    @objc private func endFocusFromMenu() { focus.finish() }

    @objc private func cancelFocusFromMenu() { focus.cancel() }

    // MARK: Today's brief

    private var briefPanel: BriefPanel?

    /// Today's Daybook brief, in a window of its own.
    private func showBrief() {
        hidePanel()
        let panel = briefPanel ?? BriefPanel()
        briefPanel = panel
        panel.load()
        panel.show()
    }

    @objc private func showBriefFromMenu() { showBrief() }

    // MARK: Error helper

    /// A spotted error turns the hare orange and puts "Explain Error" at the top of its menu.
    private func showError(_ found: ErrorWatcher.Found?) {
        spottedError = found
        updateStatusItem()
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

    // MARK: Watching from the menu bar

    /// The hare, filled and orange for a spotted error, with a ring while Claude is
    /// watching the screen and a dot when it has answered something you haven't seen.
    // MARK: hop:// links

    /// hop:// links from other apps (Eclipse's ⌘T, Shortcuts, Daybook). None sends anything
    /// to Claude by itself: an "ask" link attaches the page and fills in the question.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let link = HopLink.parse(url) else {
                Toast.show("Hop doesn\u{2019}t know the link \(url.absoluteString.prefix(60))", symbol: "questionmark.circle")
                continue
            }
            switch link {
            case .open(let query):
                showPanel()
                if let query { model.query = query }
            case .ask(let question, let page, let title, let text):
                showAsk()
                if let page {
                    ask.attachEclipsePage((page, title), question: question)
                } else if let text {
                    ask.attach(text: text, name: title ?? "Text", question: question)
                } else if let question {
                    ask.draft = question
                }
            case .focus(let minutes, let label):
                startFocus(minutes: minutes, label: label)
            case .deadlines(let page, let title):
                showAsk()
                ask.findDeadlines(page: page.map { ($0, title) })
            case .brief:
                showBrief()
            }
        }
    }

    // MARK: Eclipse updates

    /// Eclipse's page changes and new Live Folder items, at the top of the menu.
    private func showEclipseUpdates(_ updates: [EclipseWatcher.Update]) {
        if let menu = statusItem.menu {
            eclipseItems.forEach(menu.removeItem)
            eclipseItems = []
            if !updates.isEmpty {
                var items = [NSMenuItem.sectionHeader(title: "Eclipse")]
                for update in updates.prefix(8) {
                    let item = NSMenuItem(title: update.title, action: #selector(openEclipseUpdate(_:)), keyEquivalent: "")
                    item.subtitle = update.detail
                    item.image = NSImage(systemSymbolName: update.kind == .page ? "eye" : "folder.badge.plus", accessibilityDescription: nil)
                    item.representedObject = update.id
                    item.target = self
                    items.append(item)
                }
                let clear = NSMenuItem(title: "Mark All as Read", action: #selector(markEclipseRead), keyEquivalent: "")
                clear.target = self
                items += [clear, .separator()]
                for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
                eclipseItems = items
            }
        }
        updateStatusItem()
    }

    @objc private func openEclipseUpdate(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let update = eclipseWatcher.updates.first(where: { $0.id == id }) else { return }
        eclipseWatcher.open(update)
    }

    @objc private func markEclipseRead() { eclipseWatcher.markAllRead() }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        // Filled for something to look at: orange for a coding error, blue for Eclipse news.
        let news = !eclipseWatcher.updates.isEmpty
        let hare = NSImage(systemSymbolName: spottedError == nil && !news ? "hare" : "hare.fill", accessibilityDescription: "Hop")!
        let mark: StatusMark? = ask.hasUnseenReply ? .dot : ask.isWatching ? .ring : nil
        button.image = mark.map { Self.marked(hare, $0) } ?? hare
        button.contentTintColor = spottedError != nil ? .systemOrange : news ? .systemBlue : nil
        answerItem.isHidden = !ask.hasUnseenReply
        watchItem.state = ask.isWatching ? .on : .off
    }

    private enum StatusMark { case ring, dot }

    /// `image` with a small mark at its top right, cut out of the hare so it reads
    /// clearly. A template image, so it follows the menu bar's light or dark look.
    private static func marked(_ image: NSImage, _ mark: StatusMark) -> NSImage {
        let diameter: CGFloat = 6
        let size = NSSize(width: image.size.width + 2, height: max(image.size.height, 15))
        let marked = NSImage(size: size, flipped: false) { rect in
            image.draw(in: NSRect(x: 0, y: (rect.height - image.size.height) / 2,
                                  width: image.size.width, height: image.size.height))
            let spot = NSRect(x: rect.maxX - diameter, y: rect.maxY - diameter, width: diameter, height: diameter)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: spot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.set()
            switch mark {
            case .dot:
                NSBezierPath(ovalIn: spot).fill()
            case .ring:
                let ring = NSBezierPath(ovalIn: spot.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            return true
        }
        marked.isTemplate = true
        return marked
    }

    @objc private func showAnswerFromMenu() { showAsk() }

    private static let replyNotification = "ask-reply"

    /// A notification that says only that Claude replied, never what it said, so
    /// nothing from the screen shows up in a banner. Silent, and each one replaces the
    /// last, so they don't pile up in Notification Center.
    private func notifyReply(isError: Bool) {
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = "Ask Claude"
            content.body = isError ? "Something went wrong while watching." : "Claude has an answer."
            try? await center.add(UNNotificationRequest(identifier: Self.replyNotification, content: content, trigger: nil))
        }
    }

    @objc private func toggleQuietWatching() {
        if ask.isWatching { ask.stopWatching() } else { ask.watchQuietly() }
    }

    private func toggleAsk() {
        if askPanel.isVisible && askPanel.isKeyWindow { askPanel.orderOut(nil) } else { showAsk() }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "hare", accessibilityDescription: "Hop")
        let menu = NSMenu()
        errorItem = menu.addItem(withTitle: "Explain Error", action: #selector(explainErrorFromMenu), keyEquivalent: "")
        errorItem.image = NSImage(systemSymbolName: "exclamationmark.bubble.fill", accessibilityDescription: nil)
        errorItem.isHidden = true
        focusItems = [
            menu.addItem(withTitle: "Focus", action: nil, keyEquivalent: ""),
            menu.addItem(withTitle: "End Focus and Log It", action: #selector(endFocusFromMenu), keyEquivalent: ""),
            menu.addItem(withTitle: "Cancel Focus", action: #selector(cancelFocusFromMenu), keyEquivalent: ""),
            .separator(),
        ]
        focusItems[0].image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        focusItems.forEach { $0.isHidden = true }
        answerItem = menu.addItem(withTitle: "Show Claude\u{2019}s Answer", action: #selector(showAnswerFromMenu), keyEquivalent: "")
        answerItem.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        answerItem.isHidden = true
        shortcutItems[.launcher] = menu.addItem(withTitle: "Open Hop", action: #selector(openFromMenu), keyEquivalent: "")
        shortcutItems[.ask] = menu.addItem(withTitle: "Ask Claude About Screen", action: #selector(openAsk), keyEquivalent: "")
        shortcutItems[.explain] = menu.addItem(withTitle: "Explain Selection", action: #selector(explainFromMenu), keyEquivalent: "")
        shortcutItems[.askArea] = menu.addItem(withTitle: "Ask About Area\u{2026}", action: #selector(askAboutAreaFromMenu), keyEquivalent: "")
        shortcutItems[.copyText] = menu.addItem(withTitle: "Copy Text from Screen\u{2026}", action: #selector(copyTextFromMenu), keyEquivalent: "")
        watchItem = menu.addItem(withTitle: "Watch Screen Quietly", action: #selector(toggleQuietWatching), keyEquivalent: "")
        menu.addItem(withTitle: "Today\u{2019}s Brief", action: #selector(showBriefFromMenu), keyEquivalent: "")
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

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Clicking the notification opens Ask Claude.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        await MainActor.run { showAsk() }
    }

    /// Shows it even when Hop counts as the active app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
