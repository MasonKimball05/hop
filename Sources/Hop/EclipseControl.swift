import AppKit
import HopCore

/// Tells Eclipse what to do: its AppleScript commands (sent as plain Apple events, so
/// no script is compiled) for an exact tab, and eclipse-browser:// links for the rest.
/// macOS asks once to let Hop control Eclipse.
@MainActor
enum EclipseControl {
    /// The Eclipse that's running (release or Dev), else the installed release.
    static var app: (bundleID: String, url: URL)? {
        for id in Eclipse.bundleIDs {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first, let url = running.bundleURL {
                return (id, url)
            }
        }
        for id in Eclipse.bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return (id, url) }
        }
        return nil
    }

    static var isInstalled: Bool { app != nil }

    static var isRunning: Bool {
        Eclipse.bundleIDs.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    /// Opens an eclipse-browser:// link in that Eclipse (both register the scheme, so
    /// it's named rather than left to macOS).
    static func open(_ link: URL) {
        guard let app else { return Toast.show("Eclipse isn\u{2019}t installed", symbol: "exclamationmark.triangle.fill") }
        NSWorkspace.shared.open([link], withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    /// Brings a tab on screen, in its Space. If Eclipse isn't running it's started first;
    /// if the tab can't be found (closed since), its page opens in a new tab instead.
    static func focus(_ tab: Eclipse.Tab) {
        Task {
            // Running: one try, and a failure means the tab has gone. Just started: it
            // takes a few seconds to restore its tabs and answer, so keep trying a while.
            let wasRunning = isRunning
            if !wasRunning, let app {
                NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            }
            let deadline = Date.now.addingTimeInterval(wasRunning ? 0 : 15)
            repeat {
                switch await send("FcTb", tab.id, timeout: wasRunning ? 5 : 2) {
                case .done: return
                case .notAllowed: return explainPermission()
                case .failed: if !wasRunning { try? await Task.sleep(for: .milliseconds(500)) }
                }
            } while Date.now < deadline
            if let link = Eclipse.openLink(tab.url, space: tab.space) { open(link) }
        }
    }

    static func close(_ tab: Eclipse.Tab) {
        guard isRunning else { return Toast.show("Eclipse isn\u{2019}t running", symbol: "xmark.circle") }
        Task {
            switch await send("ClTb", tab.id, timeout: 5) {
            case .done: Toast.show("Closed \u{201C}\(ClaudeCLI.selectionPreview(tab.title, length: 40))\u{201D}", symbol: "xmark.circle")
            case .notAllowed: explainPermission()
            case .failed: Toast.show("Eclipse couldn\u{2019}t close that tab", symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    // MARK: The page on screen

    /// The tab Eclipse is showing (its "current tab" command); nil when Eclipse isn't
    /// running or isn't showing one.
    static func currentTab() async -> (url: String, title: String)? {
        guard isRunning, let bundleID = app?.bundleID else { return nil }
        return await Task.detached { () -> (url: String, title: String)? in
            let event = NSAppleEventDescriptor(eventClass: fourCharCode("Eclp"), eventID: fourCharCode("CrTb"),
                                               targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: bundleID),
                                               returnID: AEReturnID(kAutoGenerateReturnID),
                                               transactionID: AETransactionID(kAnyTransactionID))
            guard let reply = try? event.sendEvent(options: [.waitForReply], timeout: 5),
                  let tab = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)),
                  let url = tab.forKeyword(fourCharCode("pURL"))?.stringValue else { return nil }
            return (url, tab.forKeyword(fourCharCode("Ettl"))?.stringValue ?? url)
        }.value
    }

    /// A page's text from Eclipse's index, trying the address as Eclipse may have kept it
    /// (with or without its #fragment or a trailing slash).
    static func pageText(_ url: String) async -> (title: String, text: String)? {
        await Task.detached {
            var tries = [url]
            let base = url.split(separator: "#", maxSplits: 1).first.map(String.init) ?? url
            tries += [base, base.hasSuffix("/") ? String(base.dropLast()) : base + "/"]
            for address in NSOrderedSet(array: tries).array as! [String] {
                if let found = Eclipse.pageText(for: address) { return found }
            }
            return nil
        }.value
    }

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier.map(Eclipse.bundleIDs.contains) ?? false
    }

    // MARK: Apple events

    private enum Outcome { case done, notAllowed, failed }

    /// One of Eclipse's commands (suite "Eclp"), with a text direct parameter. Sent off
    /// the main thread, since it waits for Eclipse's reply.
    private static func send(_ command: String, _ parameter: String, timeout: TimeInterval) async -> Outcome {
        guard let bundleID = app?.bundleID else { return .failed }
        return await Task.detached {
            let event = NSAppleEventDescriptor(eventClass: fourCharCode("Eclp"), eventID: fourCharCode(command),
                                               targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: bundleID),
                                               returnID: AEReturnID(kAutoGenerateReturnID),
                                               transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(NSAppleEventDescriptor(string: parameter), forKeyword: AEKeyword(keyDirectObject))
            do {
                let reply = try event.sendEvent(options: [.waitForReply], timeout: timeout)
                // Eclipse reports a problem (no such tab) as an error number in the reply.
                if let number = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, number != 0 { return .failed }
                return .done
            } catch let error as NSError where error.code == Int(errAEEventNotPermitted) {
                return .notAllowed
            } catch {
                return .failed
            }
        }.value
    }

    private static func explainPermission() {
        Toast.show("Allow Hop to control Eclipse: System Settings \u{25B8} Privacy & Security \u{25B8} Automation", symbol: "lock.fill")
    }

    nonisolated private static func fourCharCode(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
