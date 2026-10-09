import AppKit
import HopCore
import Observation

/// What the launcher shows and what Enter does, for every mode. Each feature's
/// rows and actions live in its own file (LauncherModel+Repos.swift, ...); this
/// file has the shared state, navigation, and the main search that combines them.
@MainActor
@Observable
final class LauncherModel {
    enum Mode: Equatable {
        case search
        case clipboard
        case snippets
        case homebase
        case homebaseApp(HomebaseClient.App)
        case checkup(String)
        case repos
        case repo(Repo)
        case ports(Int) // 0 = every port
        case port(ListeningPort)
        case library
        case jobs
        case daybook

        var title: String? {
            switch self {
            case .search: nil
            case .clipboard: "Clipboard"
            case .snippets: "Snippets"
            case .homebase: "Homebase"
            case .homebaseApp(let app): app.displayName
            case .checkup(let site): site
            case .repos: "Repos"
            case .repo(let repo): repo.name
            case .ports(let port): port == 0 ? "Ports" : "Port \(port)"
            case .port(let port): ":\(port.port) \(port.command)"
            case .library: "Library"
            case .jobs: "Jobs"
            case .daybook: "Daybook"
            }
        }

        /// Where Escape goes from here.
        var parent: Mode? {
            switch self {
            case .search: nil
            case .homebaseApp: .homebase
            case .repo: .repos
            case .port: .ports(0)
            default: .search
            }
        }
    }

    enum Icon {
        case app(URL)
        case symbol(String, NSColor? = nil)
    }

    struct Row: Identifiable {
        let id: String
        var title: String
        var subtitle: String?
        var icon: Icon
        var accessory: String?
        /// What Enter does, shown in the footer. Empty for rows that do nothing.
        var actionName: String = ""
        var action: (@MainActor () -> Void)?
        /// ⌘⌫ on this row, when it can be deleted.
        var delete: (@MainActor () -> Void)?
        /// More it can do, listed by ⌘K after what Return does.
        var actions: [RowAction] = []
    }

    struct RowAction: Identifiable {
        var id: String { title }
        let title: String
        let symbol: String
        /// Asks Claude (shown with a sparkle, since it uses Claude usage).
        var isClaude = false
        let run: @MainActor () -> Void
    }

    // MARK: Shared state

    private(set) var mode: Mode = .search
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            refresh()
            searchFilesIfAsked()
        }
    }
    private(set) var rows: [Row] = []
    var selection = 0
    var message: String?
    var isLoading = false
    /// The ⌘K list for the selected row.
    var actionsShown = false
    var actionSelection = 0
    /// Bumped every time the panel opens, so the view can refocus the field.
    private(set) var openCount = 0

    /// Set by the app delegate.
    var hide: () -> Void = {}
    var paste: (String) -> Void = { _ in }
    var askAboutFile: (URL) -> Void = { _ in }
    var rewrite: (ClaudeCLI.Rewrite, String) -> Void = { _, _ in }
    /// Opens Ask Claude, sending the question with a screenshot when there is one.
    var ask: (String?) -> Void = { _ in }
    var explainSelection: () -> Void = {}
    var copyTextFromScreen: () -> Void = {}
    var askAboutArea: () -> Void = {}
    var findDeadlines: () -> Void = {}
    var explainError: () -> Void = {}
    var openSettings: () -> Void = {}

    // Feature state, used by the extensions.
    var apps: [AppEntry] = []
    var usage: UsageCounts
    var clipboard = ClipboardHistory()
    var homebaseApps: [HomebaseClient.App] = []
    var checkupReport: CheckupClient.Report?
    var repos: [Repo] = []
    var repoStatus: [URL: RepoStatus] = [:]
    var repoIDE: [URL: Repos.IDE] = [:]
    var ports: [ListeningPort] = []
    var snippets: [Snippet] = []
    var quicklinks: [Quicklink] = Quicklinks.defaults
    var translation = TranslationState()
    var library = LibraryState()
    var jobs = JobsState()
    var repoGitHub: [URL: GitHubState] = [:]
    var fileHits: [FileSearch.Hit] = []
    var fileQuery: String?
    var fileSearching = false
    @ObservationIgnored let finder = FileFinder()
    @ObservationIgnored var cachedShelfToken: String?
    @ObservationIgnored var iconCache: [URL: NSImage] = [:]

    private static let usageKey = "usageCounts"

    init() {
        usage = UsageCounts(UserDefaults.standard.dictionary(forKey: Self.usageKey) as? [String: Int] ?? [:])
        apps = AppIndex.scan()
        loadQuicklinks()
    }

    var selectedRow: Row? { rows.indices.contains(selection) ? rows[selection] : nil }

    var placeholder: String {
        switch mode {
        case .search: "Search apps and commands, or calculate\u{2026}"
        case .clipboard: "Search clipboard history\u{2026}"
        case .snippets: "Search snippets, or type a name to save the clipboard\u{2026}"
        case .homebase: "Filter desktop apps\u{2026}"
        case .homebaseApp, .repo, .port: "Choose an action\u{2026}"
        case .checkup: "Filter findings\u{2026}"
        case .repos: "Search repos\u{2026}"
        case .ports: "Filter by port or process\u{2026}"
        case .library: "Search the desktop\u{2019}s media library\u{2026}"
        case .jobs: "Search your applications\u{2026}"
        case .daybook: "Filter today, or type \u{201C}task \u{2026}\u{201D} in the main search\u{2026}"
        }
    }

    // MARK: Opening and navigation

    func didOpen() {
        openCount += 1
        message = nil
        mode = .search
        query = ""
        loadQuicklinks()
        refresh()
        // Pick up newly installed apps without slowing down the open itself.
        Task {
            apps = AppIndex.scan()
            if mode == .search { refreshKeepingSelection() }
        }
    }

    func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selection = min(max(selection + delta, 0), rows.count - 1)
    }

    /// Escape: close ⌘K, clear the query, then go back a level, then close.
    func escape() {
        if actionsShown {
            closeActions()
        } else if !query.isEmpty {
            query = ""
        } else if let parent = mode.parent {
            enter(parent)
        } else {
            hide()
        }
    }

    func enter(_ newMode: Mode) {
        mode = newMode
        message = nil
        query = ""
        refresh()
        switch newMode {
        case .homebase: loadHomebase()
        case .checkup(let site): runCheckup(site)
        case .repos: loadRepos()
        case .repo(let repo): loadGitHub(repo)
        case .ports: loadPorts()
        case .snippets: loadSnippets()
        case .jobs: loadJobs()
        default: break
        }
    }

    func performSelected() {
        guard let row = selectedRow, let action = row.action else { return }
        if let key = usageKey(row) { record(key) }
        action()
    }

    func deleteSelected() {
        guard let delete = selectedRow?.delete else { return }
        let keep = selection
        delete()
        refresh()
        selection = min(keep, max(rows.count - 1, 0))
    }

    // MARK: Rows

    func refresh() {
        actionsShown = false
        selection = 0
        rows = rowsForMode()
    }

    func refreshKeepingSelection() {
        let keep = selectedRow?.id
        rows = rowsForMode()
        selection = rows.firstIndex { $0.id == keep } ?? 0
    }

    private func rowsForMode() -> [Row] {
        switch mode {
        case .search: searchRows()
        case .clipboard: clipboardRows()
        case .snippets: snippetRows()
        case .homebase: homebaseRows()
        case .homebaseApp(let app): homebaseActionRows(app)
        case .checkup: checkupRows()
        case .repos: repoRows(matching: query)
        case .repo(let repo): repoActionRows(repo)
        case .ports(let port): portRows(port)
        case .port(let port): portActionRows(port)
        case .library: libraryRows(for: query.trimmingCharacters(in: .whitespaces))
        case .jobs: jobRows()
        case .daybook: daybookRows()
        }
    }

    /// Commands found by name in the main search, like apps.
    struct Command {
        let name: String
        let subtitle: String
        let symbol: String
        let run: @MainActor (LauncherModel) -> Void
    }

    var commands: [Command] {
        [
            Command(name: "Ask Claude", subtitle: "About what's on your screen; \(Shortcuts.display(.ask)) opens it from anywhere", symbol: "sparkles") { $0.ask(nil) },
            Command(name: "Explain Selection", subtitle: "Claude explains the text selected in the app you were using; \(Shortcuts.display(.explain)) from anywhere", symbol: "text.magnifyingglass") { $0.explainSelection() },
            Command(name: "Ask About Area", subtitle: "Drag over part of the screen (an equation, a diagram) and ask Claude about it; \(Shortcuts.display(.askArea))", symbol: "rectangle.dashed.and.paperclip") { $0.askAboutArea() },
            Command(name: "Copy Text from Screen", subtitle: "Drag over anything (a PDF, a video, an image) and copy its text; \(Shortcuts.display(.copyText))", symbol: "text.viewfinder") { $0.copyTextFromScreen() },
            Command(name: "Explain Error", subtitle: "The error the error helper spotted in your terminal or IDE (turn it on in the menu bar)", symbol: "exclamationmark.bubble") { $0.hide(); $0.explainError() },
            Command(name: "Search Files", subtitle: "By name, from Spotlight: type \u{201C}f syllabus\u{201D}", symbol: "doc.text.magnifyingglass") { $0.query = "f " },
            Command(name: "Clipboard History", subtitle: "Search and paste recent copies", symbol: "doc.on.clipboard") { $0.enter(.clipboard) },
            Command(name: "Snippets", subtitle: "Saved text to paste, with {date} and {clipboard}", symbol: "text.quote") { $0.enter(.snippets) },
            Command(name: "Repos", subtitle: "Projects in ~/Documents/GitHub: open in the right IDE, terminal, GitHub", symbol: "folder.badge.gearshape") { $0.enter(.repos) },
            Command(name: "Ports", subtitle: "What's listening on which port; quit it", symbol: "network") { $0.enter(.ports(0)) },
            Command(name: "Library", subtitle: "Search the desktop's movies and music, play in Media Player", symbol: "film.stack") { $0.enter(.library) },
            Command(name: "Jobs", subtitle: "Follow-ups due, Radar matches, and a search of your board", symbol: "briefcase") { $0.enter(.jobs) },
            Command(name: "Add Job", subtitle: "Job Tracker's new-job form, with the link from the clipboard", symbol: "plus.rectangle.on.rectangle") { $0.addJobFromClipboard() },
            Command(name: "Homebase", subtitle: "Apps on the desktop: status, start, stop, restart", symbol: "server.rack") { $0.enter(.homebase) },
            Command(name: "Due Dates to Daybook", subtitle: "Claude reads the due dates on a syllabus or assignment page; check them, then add them as tasks", symbol: "calendar.badge.plus") { $0.findDeadlines() },
            Command(name: "Daybook", subtitle: "Today's events, tasks due and countdowns; check tasks off", symbol: "calendar") { $0.enter(.daybook) },
            Command(name: "Add Task", subtitle: "To Daybook: type \u{201C}task submit report friday 3pm\u{201D}", symbol: "checklist") { $0.query = "task " },
            Command(name: "Log Activity", subtitle: "Time spent, to Daybook: type \u{201C}log study 10-11pm\u{201D}", symbol: "clock.badge.checkmark") { $0.query = "log " },
            Command(name: "Time Recap", subtitle: "This week in Daybook: free time, coding, logged", symbol: "chart.bar") {
                $0.sendToDaybook(Daybook.showLink("time"), activate: true)
            },
            Command(name: "Check Site", subtitle: "Grade a site's HTTPS and headers: type \u{201C}check example.com\u{201D}", symbol: "checkmark.shield") { $0.query = "check " },
            Command(name: "Hop Settings", subtitle: "Shortcuts, Claude\u{2019}s model, memory, notes folder, the error helper", symbol: "gearshape") { $0.openSettings() },
            Command(name: "Edit Quicklinks", subtitle: "Bookmarks and search keywords (quicklinks.json)", symbol: "link") { $0.editConfig("quicklinks.json") },
            Command(name: "Edit Snippets", subtitle: "snippets.json, for longer edits", symbol: "square.and.pencil") { $0.editConfig(Snippets.fileName) },
        ]
    }

    private enum Candidate {
        case app(AppEntry)
        case command(Command)
        case system(SystemCommand)
        case link(Quicklink)
        case snippet(Snippet)

        var name: String {
            switch self {
            case .app(let app): app.name
            case .command(let command): command.name
            case .system(let command): command.name
            case .link(let link): link.name
            case .snippet(let snippet): snippet.name
            }
        }

        var key: String {
            switch self {
            case .app(let app): "app:" + app.url.path
            case .command(let command): "cmd:" + command.name
            case .system(let command): "sys:" + command.name
            case .link(let link): "link:" + link.name
            case .snippet(let snippet): "snip:" + snippet.id.uuidString
            }
        }
    }

    /// The main search: special inputs first (a site check, a calculation, a
    /// translation, a web search), then everything findable by name, then a
    /// web search as the fallback.
    private func searchRows() -> [Row] {
        let text = query.trimmingCharacters(in: .whitespaces)
        var out: [Row] = []

        if let question = ClaudeCLI.question(fromCommand: text) {
            out.append(Row(id: "ask", title: "Ask Claude: \u{201C}\(question)\u{201D}", subtitle: "Sends a screenshot of your screen with the question",
                           icon: .symbol("sparkles", .systemOrange), actionName: "Ask") { [unowned self] in ask(question) })
        }
        if let row = daybookCommandRow(for: text) {
            out.append(row)
        }
        if text.isEmpty, let next = nextEventRow() {
            out.append(next)
        }
        if let site = CheckupClient.site(fromCommand: text) {
            out.append(Row(id: "checkup:" + site, title: "Check \(site)", subtitle: "Grade its HTTPS, post-quantum TLS and security headers",
                           icon: .symbol("checkmark.shield"), actionName: "Run Check") { [unowned self] in enter(.checkup(site)) })
        }
        if let port = Ports.query(fromCommand: text) {
            out.append(Row(id: "ports", title: port == 0 ? "Show Listening Ports" : "Show What's on Port \(port)", icon: .symbol("network"),
                           actionName: "Show") { [unowned self] in enter(.ports(port)) })
        }
        out += fileRows()
        if let repoQuery = Self.repoQuery(text) {
            if repos.isEmpty { repos = Repos.scan() }
            out += repoRows(matching: repoQuery).prefix(8)
        }
        if let title = Self.libraryQuery(text) {
            out += libraryRows(for: title, limit: 8)
        }
        out += translationRows(for: text)
        if let answer = Calculator.evaluate(text) ?? DateMath().evaluate(text) {
            out.append(Row(id: "answer", title: answer.text, subtitle: answer.detail, icon: .symbol("equal.square.fill", .systemOrange),
                           actionName: "Copy Answer") { [unowned self] in copyAndClose(answer.text) })
        }
        if let (link, search) = Quicklinks.search(text, in: quicklinks), let url = link.url(for: search) {
            out.append(Row(id: "search:" + link.name, title: "Search \(link.name) for \u{201C}\(search)\u{201D}", icon: .symbol("magnifyingglass"),
                           accessory: link.keyword, actionName: "Search") { [unowned self] in open(url) })
        }

        let empty = text.isEmpty
        var candidates = apps.map(Candidate.app)
        candidates += commands.map(Candidate.command) + SystemCommand.all.map(Candidate.system)
        if !empty { candidates += quicklinks.map(Candidate.link) + snippets.map(Candidate.snippet) }
        let ranked: [Candidate] = empty
            // Nothing typed yet: lead with the commands, then the most used apps.
            ? commands.map(Candidate.command) + Ranking.rank(apps.map(Candidate.app), query: "", name: \.name, key: \.key, usage: usage, limit: 40)
            : Ranking.rank(candidates, query: text, name: \.name, key: \.key, usage: usage, limit: 40)
        out += ranked.map(row(for:))

        // Always offer a web search for whatever was typed, last.
        if !empty, let google = quicklinks.first(where: { $0.keyword == "g" }), let url = google.url(for: text) {
            out.append(Row(id: "fallback", title: "Search Google for \u{201C}\(text)\u{201D}", icon: .symbol("globe"),
                           actionName: "Search") { [unowned self] in open(url) })
        }
        return out
    }

    private func row(for candidate: Candidate) -> Row {
        switch candidate {
        case .app(let app):
            return Row(id: candidate.key, title: app.name, icon: .app(app.url), accessory: "Application", actionName: "Open Application",
                       action: { [unowned self] in
                           hide()
                           NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
                       }, actions: appActions(app.url))
        case .command(let command):
            return Row(id: candidate.key, title: command.name, subtitle: command.subtitle, icon: .symbol(command.symbol),
                       accessory: "Command", actionName: "Open Command") { [unowned self] in command.run(self) }
        case .system(let command):
            return Row(id: candidate.key, title: command.name, subtitle: command.subtitle, icon: .symbol(command.symbol),
                       accessory: "System", actionName: command.actionName) { [unowned self] in run(command) }
        case .link(let link):
            if link.takesQuery {
                return Row(id: candidate.key, title: link.name, subtitle: "Type \u{201C}\(link.keyword ?? "") \u{2026}\u{201D} to search",
                           icon: .symbol("magnifyingglass"), accessory: link.keyword, actionName: "Search") { [unowned self] in
                    query = (link.keyword ?? link.name) + " "
                }
            }
            return Row(id: candidate.key, title: link.name, subtitle: link.url, icon: .symbol("link"), accessory: "Quicklink",
                       actionName: "Open Link") { [unowned self] in if let url = link.url() { open(url) } }
        case .snippet(let snippet):
            return Row(id: candidate.key, title: snippet.name, subtitle: snippet.text, icon: .symbol("text.quote"), accessory: "Snippet",
                       actionName: "Paste", action: { [unowned self] in pasteSnippet(snippet) }, actions: textActions(snippet.text))
        }
    }

    /// Rows whose use should count toward ranking.
    func usageKey(_ row: Row) -> String? {
        let prefixes = ["app:", "cmd:", "sys:", "link:", "snip:", "repo:"]
        return prefixes.contains { row.id.hasPrefix($0) } ? row.id : nil
    }

    // MARK: Shared helpers

    func record(_ key: String) {
        usage.record(key)
        UserDefaults.standard.set(usage.counts, forKey: Self.usageKey)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyAndClose(_ text: String) {
        copy(text)
        hide()
    }

    func open(_ url: URL) {
        hide()
        NSWorkspace.shared.open(url)
    }

    func icon(for url: URL) -> NSImage {
        if let cached = iconCache[url] { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[url] = image
        return image
    }

    func loadQuicklinks() {
        let loaded = ConfigFile.load("quicklinks.json", defaults: Quicklinks.defaults)
        quicklinks = loaded.value
        if let error = loaded.error { message = error }
        if snippets.isEmpty { snippets = ConfigFile.load(Snippets.fileName, defaults: Snippets.defaults).value }
    }

    /// Opens one of Hop's JSON files in its default app (TextEdit unless set otherwise).
    func editConfig(_ name: String) {
        if name == "quicklinks.json" { _ = ConfigFile.load(name, defaults: Quicklinks.defaults) }
        if name == Snippets.fileName { _ = ConfigFile.load(name, defaults: Snippets.defaults) }
        open(ConfigFile.folder.appending(path: name))
    }

    static func relative(_ date: Date) -> String {
        let seconds = Int(Date.now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 86400 { return "\(seconds / 3600) h ago" }
        return "\(seconds / 86400) d ago"
    }
}
