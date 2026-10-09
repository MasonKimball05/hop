import AppKit
import HopCore

// Clipboard history, homebase and the site checkup.
extension LauncherModel {
    // MARK: Clipboard

    func clipboardRows() -> [Row] {
        let entries = clipboard.search(query)
        if entries.isEmpty {
            let text = clipboard.entries.isEmpty ? "Nothing copied since Hop started" : "No matches"
            return [Row(id: "empty", title: text, icon: .symbol("doc.on.clipboard"))]
        }
        return entries.map { entry in
            let lines = entry.text.split(whereSeparator: \.isNewline)
            let firstLine = lines.first.map(String.init) ?? entry.text
            let size = lines.count > 1 ? "\(lines.count) lines" : "\(entry.text.count) characters"
            return Row(id: entry.id.uuidString, title: firstLine.trimmingCharacters(in: .whitespaces),
                       subtitle: "\(Self.relative(entry.copiedAt)) \u{00B7} \(size)", icon: .symbol("text.alignleft"),
                       actionName: "Paste", action: { [unowned self] in hide(); paste(entry.text) },
                       delete: { [unowned self] in clipboard.remove(entry.id) }, actions: textActions(entry.text))
        }
    }

    func addClip(_ text: String) {
        clipboard.add(text)
        if mode == .clipboard { refreshKeepingSelection() }
    }

    func clearClipboardHistory() {
        clipboard.clear()
        if mode == .clipboard { refresh() }
    }

    // MARK: Homebase

    private var homebase: HomebaseClient {
        let fallback = URL(string: "http://arkans-pc1:8090")!
        let raw = UserDefaults.standard.string(forKey: "homebaseURL")
        return HomebaseClient(base: raw.flatMap(URL.init(string:)) ?? fallback)
    }

    func homebaseRows() -> [Row] {
        if homebaseApps.isEmpty {
            let text = isLoading ? "Asking the desktop\u{2026}" : (message ?? "homebase has no apps")
            return [Row(id: "hb-status", title: text, icon: .symbol("server.rack"))]
        }
        let apps = query.isEmpty ? homebaseApps
            : Ranking.rank(homebaseApps, query: query, name: \.displayName, key: \.name, usage: UsageCounts())
        return apps.map { app in
            var subtitle = app.state
            if let detail = app.message, !detail.isEmpty { subtitle += " \u{00B7} " + detail }
            if app.restarts > 0 { subtitle += " \u{00B7} \(app.restarts) restart\(app.restarts == 1 ? "" : "s")" }
            return Row(id: "hb:" + app.name, title: app.displayName, subtitle: subtitle,
                       icon: .symbol("circle.fill", Self.color(forState: app.state)),
                       actionName: "Show Actions") { [unowned self] in enter(.homebaseApp(app)) }
        }
    }

    func homebaseActionRows(_ app: HomebaseClient.App) -> [Row] {
        let busy = app.state == "backoff" || app.state == "starting"
        let actions: [HomebaseClient.Action] = app.isRunning || busy ? [.restart, .stop] : [.start]
        var out = actions.map { action in
            Row(id: "hba:" + action.rawValue, title: action.rawValue.capitalized + " " + app.displayName,
                icon: .symbol(action == .stop ? "stop.fill" : action == .start ? "play.fill" : "arrow.clockwise"),
                actionName: action.rawValue.capitalized) { [unowned self] in runHomebase(action, on: app) }
        }
        if let raw = app.url, let url = URL(string: raw) {
            out.append(Row(id: "hb-open", title: "Open \(app.displayName) in Browser", subtitle: raw,
                           icon: .symbol("safari"), actionName: "Open") { [unowned self] in open(url) })
        }
        return out.filter { query.isEmpty || FuzzyMatcher.score(query, in: $0.title) != nil }
    }

    func loadHomebase() {
        isLoading = true
        refresh()
        Task {
            defer { isLoading = false; if mode == .homebase { refreshKeepingSelection() } }
            do {
                homebaseApps = try await homebase.apps()
                message = nil
            } catch {
                homebaseApps = []
                message = "Can\u{2019}t reach homebase. The desktop may be off or asleep."
            }
        }
    }

    private func runHomebase(_ action: HomebaseClient.Action, on app: HomebaseClient.App) {
        let verb = switch action { case .start: "Starting"; case .stop: "Stopping"; case .restart: "Restarting" }
        message = "\(verb) \(app.displayName)\u{2026}"
        Task {
            do {
                try await homebase.perform(action, on: app.name)
                enter(.homebase)
                message = "\(app.displayName): \(action.rawValue) requested"
            } catch {
                message = "\(action.rawValue.capitalized) failed: \(error.localizedDescription)"
            }
        }
    }

    static func color(forState state: String) -> NSColor {
        switch state {
        case "running", "external": .systemGreen
        case "starting", "stopping", "backoff": .systemYellow
        case "crashed": .systemRed
        default: .systemGray
        }
    }

    // MARK: Site checkup

    func checkupRows() -> [Row] {
        guard let report = checkupReport else {
            let text = isLoading ? "Checking\u{2026}" : (message ?? "No result")
            return [Row(id: "checking", title: text, icon: .symbol("checkmark.shield"))]
        }
        let gradeColor: NSColor = report.grade == "A" ? .systemGreen : ["B", "C"].contains(report.grade) ? .systemYellow : .systemRed
        let summary = "\(mode.title ?? ""): grade \(report.grade) (\(report.score)/100)"
        var out = [Row(id: "grade", title: "Grade \(report.grade)", subtitle: "Score \(report.score)/100",
                       icon: .symbol("checkmark.shield.fill", gradeColor), actionName: "Copy Summary") { [unowned self] in copyAndClose(summary) }]
        for finding in report.results where query.isEmpty || FuzzyMatcher.score(query, in: finding.check + " " + finding.detail) != nil {
            let (symbol, color): (String, NSColor) = switch finding.status {
            case "ok": ("checkmark.circle.fill", .systemGreen)
            case "warn": ("exclamationmark.triangle.fill", .systemYellow)
            default: ("xmark.octagon.fill", .systemRed)
            }
            var row = Row(id: "f:" + finding.check + finding.detail, title: finding.detail, subtitle: finding.tip,
                          icon: .symbol(symbol, color), accessory: finding.check)
            if let tip = finding.tip {
                row.actionName = "Copy Tip"
                row.action = { [unowned self] in copyAndClose(tip) }
            }
            out.append(row)
        }
        return out
    }

    func runCheckup(_ site: String) {
        checkupReport = nil
        isLoading = true
        refresh()
        Task {
            defer { isLoading = false; if case .checkup = mode { refreshKeepingSelection() } }
            do {
                checkupReport = try await CheckupClient().check(site)
                message = nil
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
