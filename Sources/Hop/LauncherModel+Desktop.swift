import AppKit
import HopCore
import Security

// My desktop's library (shelf) and Job Tracker.
extension LauncherModel {
    // MARK: Library (shelf)

    /// "play arrival" searches the library from the main search.
    static func libraryQuery(_ text: String) -> String? {
        for prefix in ["play ", "watch ", "listen "] where text.lowercased().hasPrefix(prefix) {
            let rest = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return rest.count >= 2 ? rest : nil
        }
        return nil
    }

    /// Rows for a library search, started (after a pause in typing) if needed.
    func libraryRows(for text: String, limit: Int = 50) -> [Row] {
        guard text.count >= 2 else {
            return [Row(id: "lib-hint", title: "Type a title to search the library", icon: .symbol("film.stack"))]
        }
        guard library.query == text else {
            scheduleLibrarySearch(text)
            return [Row(id: "lib-wait", title: "Searching the library\u{2026}", icon: .symbol("film.stack"))]
        }
        if let problem = library.problem {
            return [Row(id: "lib-problem", title: problem, icon: .symbol("exclamationmark.triangle"))]
        }
        guard let files = library.files else {
            return [Row(id: "lib-wait", title: "Searching the library\u{2026}", icon: .symbol("film.stack"))]
        }
        if files.isEmpty { return [Row(id: "lib-none", title: "Nothing in the library matches \u{201C}\(text)\u{201D}", icon: .symbol("film.stack"))] }
        return files.prefix(limit).map { file in
            var subtitle = file.root + "/" + file.path
            if let position = file.position, position > 0 { subtitle += " \u{00B7} resume at " + Self.timestamp(position) }
            return Row(id: "lib:" + file.id, title: file.name, subtitle: subtitle,
                       icon: .symbol(file.isVideo ? "film" : "music.note", .systemPurple), accessory: "Library",
                       actionName: "Play in Media Player") { [unowned self] in play(file) }
        }
    }

    private func play(_ file: ShelfSearchClient.File) {
        guard let url = file.itemURL else { return }
        hide()
        // Media Player handles shelf:// links: it fetches a fresh stream link with its
        // own token and resumes where any Mac left off.
        NSWorkspace.shared.open(url)
    }

    private func scheduleLibrarySearch(_ text: String) {
        library.pending?.cancel()
        library = LibraryState(query: text)
        library.pending = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            var problem: String?
            var files: [ShelfSearchClient.File] = []
            switch shelfToken() {
            case .failure(let error):
                problem = error.message
            case .success(let token):
                let base = UserDefaults.standard.string(forKey: "shelfURL").flatMap(URL.init(string:)) ?? ShelfSearchClient.defaultBase
                do {
                    files = try await ShelfSearchClient(base: base, token: token).search(text)
                } catch let error as ServiceError {
                    problem = error.localizedDescription
                } catch {
                    problem = "Can\u{2019}t reach the library. The desktop may be off or asleep."
                }
            }
            guard !Task.isCancelled, library.query == text else { return }
            library.files = files
            library.problem = problem
            refreshKeepingSelection()
        }
    }

    struct TokenProblem: Error { let message: String }

    /// The library token, read from Media Player's Keychain entry (Settings ▸ Library
    /// saves it there). macOS asks once whether Hop may use it. Kept in memory after.
    private func shelfToken() -> Result<String, TokenProblem> {
        if let token = cachedShelfToken { return .success(token) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.masonkimball.MediaPlayer",
            kSecAttrAccount as String: "shelf-token",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
                return .failure(TokenProblem(message: "Media Player's library token is empty"))
            }
            cachedShelfToken = token
            return .success(token)
        case errSecItemNotFound:
            return .failure(TokenProblem(message: "Set up the library in Media Player first (Settings \u{25B8} Library)"))
        case errSecUserCanceled, errSecAuthFailed:
            return .failure(TokenProblem(message: "Hop wasn\u{2019}t allowed to read the library token"))
        default:
            return .failure(TokenProblem(message: "Couldn\u{2019}t read the library token (error \(status))"))
        }
    }

    static func timestamp(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Job Tracker

    private var jobTracker: JobTrackerClient {
        JobTrackerClient(base: UserDefaults.standard.string(forKey: "jobTrackerURL").flatMap(URL.init(string:)) ?? JobTrackerClient.defaultBase)
    }

    /// With no query: follow-ups coming due, then Radar matches. With one: a board search.
    func jobRows() -> [Row] {
        let text = query.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            guard jobs.searchQuery == text, let found = jobs.searchResults else {
                if jobs.searchQuery != text { scheduleJobSearch(text) }
                return [Row(id: "jobs-wait", title: "Searching your board\u{2026}", icon: .symbol("briefcase"))]
            }
            if found.isEmpty { return [Row(id: "jobs-none", title: "No applications match \u{201C}\(text)\u{201D}", icon: .symbol("briefcase"))] }
            return found.map { app in
                var subtitle = app.status
                if let score = app.matchScore { subtitle += " \u{00B7} \(score)% match" }
                if let date = app.followUpOn { subtitle += " \u{00B7} follow up \(date)" }
                return Row(id: "job:\(app.id)", title: "\(app.role) at \(app.company)", subtitle: subtitle, icon: .symbol("briefcase"),
                           actionName: "Open in Job Tracker") { [unowned self] in open(jobTracker.page(for: app.id)) }
            }
        }

        if let problem = jobs.problem, jobs.followUps == nil {
            return [Row(id: "jobs-problem", title: problem, icon: .symbol("exclamationmark.triangle"))]
        }
        guard let followUps = jobs.followUps, let matches = jobs.matches else {
            return [Row(id: "jobs-wait", title: "Asking Job Tracker\u{2026}", icon: .symbol("briefcase"))]
        }
        var out: [Row] = followUps.map { item in
            Row(id: "fu:\(item.id)", title: "Follow up: \(item.role) at \(item.company)",
                subtitle: (item.due ? "Due " : "Coming up ") + item.followUpOn + " \u{00B7} " + item.status,
                icon: .symbol(item.due ? "bell.badge.fill" : "bell", item.due ? .systemOrange : nil),
                actionName: "Open in Job Tracker") { [unowned self] in open(jobTracker.page(for: item.id)) }
        }
        out += matches.map { match in
            let place = [match.location, match.remote ? "Remote" : nil].compactMap { $0 }.joined(separator: " \u{00B7} ")
            return Row(id: "rm:\(match.id)", title: "\(match.title) at \(match.company)",
                       subtitle: "\(match.score)% \u{00B7} " + (match.verdict ?? place), icon: .symbol("scope", .systemGreen),
                       accessory: place.isEmpty ? nil : place, actionName: "Open Posting") { [unowned self] in
                if let url = URL(string: match.url) { open(url) }
            }
        }
        out.append(Row(id: "jobs-radar", title: "Open Radar in Job Tracker", icon: .symbol("scope"),
                       actionName: "Open") { [unowned self] in open(jobTracker.base.appending(path: "radar")) })
        if followUps.isEmpty && matches.isEmpty {
            out.insert(Row(id: "jobs-quiet", title: "No follow-ups this week and no new matches", icon: .symbol("checkmark.circle")), at: 0)
        }
        return out
    }

    func loadJobs() {
        jobs = JobsState()
        Task {
            do {
                async let followUps = jobTracker.followUps()
                async let matches = jobTracker.matches()
                (jobs.followUps, jobs.matches) = try await (followUps, matches)
            } catch {
                jobs.problem = "Can\u{2019}t reach Job Tracker. The desktop may be off or asleep."
            }
            if mode == .jobs { refreshKeepingSelection() }
        }
    }

    private func scheduleJobSearch(_ text: String) {
        jobs.pending?.cancel()
        jobs.searchQuery = text
        jobs.searchResults = nil
        jobs.pending = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = (try? await jobTracker.applications(matching: text)) ?? []
            guard !Task.isCancelled, jobs.searchQuery == text else { return }
            jobs.searchResults = found
            if mode == .jobs { refreshKeepingSelection() }
        }
    }

    /// Opens Job Tracker's new-job form, with the posting link filled in when the
    /// clipboard holds one.
    func addJobFromClipboard() {
        let copied = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = copied.flatMap { text -> String? in
            guard let url = URL(string: text), url.scheme == "https" || url.scheme == "http", url.host() != nil else { return nil }
            return text
        }
        open(jobTracker.newJobPage(postingURL: link))
    }
}

/// A library search in progress or done.
struct LibraryState {
    var query = ""
    var files: [ShelfSearchClient.File]?
    var problem: String?
    var pending: Task<Void, Never>?
}

/// What the Jobs view has loaded.
struct JobsState {
    var followUps: [JobTrackerClient.FollowUp]?
    var matches: [JobTrackerClient.Match]?
    var problem: String?
    var searchQuery = ""
    var searchResults: [JobTrackerClient.Application]?
    var pending: Task<Void, Never>?
}
