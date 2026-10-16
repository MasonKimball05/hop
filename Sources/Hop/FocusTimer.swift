import AppKit
import HopCore

/// The study timer. Counts down in the menu bar; when it ends (or you end it early) the
/// time goes to Daybook's time log, and a chime and a note say so. It's saved, so a
/// session carries on if Hop restarts, and one that ran out while Hop was off still
/// gets logged.
@MainActor
final class FocusTimer {
    struct Session: Codable {
        let label: String?
        let start: Date
        let end: Date
    }

    private(set) var session: Session?
    /// Called every second while running (and once with nil when it stops).
    var onTick: (Session?, Int) -> Void = { _, _ in }

    private var ticker: Timer?
    private static let key = "focusSession"

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let saved = try? JSONDecoder().decode(Session.self, from: data) else { return }
        session = saved
    }

    var remaining: Int { session.map { max(0, Int($0.end.timeIntervalSinceNow.rounded(.up))) } ?? 0 }

    /// Picks a saved session back up after launch (separate from init, so the menu bar
    /// exists by then). One that ran out while Hop wasn't running is logged as planned.
    func resume() {
        guard let session else { return }
        if session.end <= .now { finish(at: session.end, quietly: true) } else { startTicking() }
    }

    func start(minutes: Int, label: String?) {
        if session != nil { finish(at: .now) }
        let now = Date.now
        session = Session(label: label, start: now, end: now.addingTimeInterval(TimeInterval(minutes * 60)))
        save()
        startTicking()
        Toast.show("Focus\(label.map { " on \($0)" } ?? ""): \(Focus.length(minutes))", symbol: "timer")
    }

    /// Ends now (or at `end`) and logs the time spent to Daybook.
    func finish(at end: Date = .now, quietly: Bool = false) {
        guard let session else { return }
        stop()
        let spent = end.timeIntervalSince(session.start)
        let what = session.label.map { " on \($0)" } ?? ""
        guard spent >= Focus.minimumLogged else {
            if !quietly { Toast.show("Focus ended; under 5 minutes, so not logged", symbol: "timer") }
            return
        }
        let link = Daybook.link(for: .log(title: Focus.logTitle(session.label), start: session.start, end: end))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(link, configuration: configuration) { _, error in
            guard error != nil else { return }
            Task { @MainActor in Toast.show("Couldn\u{2019}t reach Daybook to log the focus time", symbol: "exclamationmark.triangle.fill") }
        }
        let minutes = Int((spent / 60).rounded())
        if !quietly { NSSound(named: "Glass")?.play() }
        Toast.show("Focus done\(what): \(Focus.length(minutes)), logged to Daybook", symbol: "checkmark.circle.fill")
    }

    /// Stops without logging anything.
    func cancel() {
        guard session != nil else { return }
        stop()
        Toast.show("Focus cancelled", symbol: "xmark.circle")
    }

    private func stop() {
        ticker?.invalidate()
        ticker = nil
        session = nil
        UserDefaults.standard.removeObject(forKey: Self.key)
        onTick(nil, 0)
    }

    private func startTicking() {
        ticker?.invalidate()
        tick()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Keep counting while a menu is open.
        if let ticker { RunLoop.main.add(ticker, forMode: .common) }
    }

    private func tick() {
        guard let session else { return }
        if session.end <= .now { return finish(at: session.end) }
        onTick(session, remaining)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(session) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
