import AppKit
import HopCore

/// The error helper: while it's on and a terminal or IDE is in front, reads that
/// window every few seconds for error output. A new error turns the menu bar hare
/// orange, and its menu offers to have Claude explain it.
@MainActor
final class ErrorWatcher {
    struct Found {
        let app: String?
        let shot: ScreenCapture.Shot
        /// The first error line, for the menu.
        let preview: String
    }

    private(set) var found: Found? {
        didSet { onChange(found) }
    }

    var onChange: (Found?) -> Void = { _ in }

    var isOn = UserDefaults.standard.bool(forKey: "watchErrors") {
        didSet {
            UserDefaults.standard.set(isOn, forKey: "watchErrors")
            if isOn { start() } else { stop() }
        }
    }

    private var task: Task<Void, Never>?
    /// Errors already flagged, so the same one isn't flagged again while it's on screen.
    private var seen: Set<String> = []

    init() {
        if isOn { start() }
    }

    /// The error to explain, cleared from the menu bar.
    func take() -> Found? {
        defer { found = nil }
        return found
    }

    private func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.look()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
        found = nil
    }

    private func look() async {
        // Only developer apps are ever captured.
        guard let app = NSWorkspace.shared.frontmostApplication, ErrorScan.isDeveloperApp(app.bundleIdentifier) else { return }
        let shot: ScreenCapture.Shot
        do {
            shot = try await ScreenCapture.capture(.frontWindow)
        } catch {
            isOn = false
            Toast.show("Error helper is off: Hop needs Screen Recording permission", symbol: "exclamationmark.triangle.fill")
            return
        }
        let lines = await TextRecognition.lines(in: shot.image, fast: true)
        let errors = ErrorScan.errorLines(lines)
        guard !errors.isEmpty else {
            // Cleared or scrolled away: stop offering it.
            if found?.app == app.localizedName { found = nil }
            return
        }
        let signature = ErrorScan.signature(lines, errors: errors)
        guard seen.insert(signature).inserted else { return }
        if seen.count > 200 { seen = [signature] }
        found = Found(app: app.localizedName, shot: shot, preview: lines[errors[0]].trimmingCharacters(in: .whitespaces))
    }
}
