import AppKit
import HopCore

// Repos: my projects in ~/Documents/GitHub, and ports: what's listening where.
extension LauncherModel {
    // MARK: Repos

    /// "repo hop", "repos hop" or "r hop" -> "hop".
    static func repoQuery(_ text: String) -> String? {
        for prefix in ["repo ", "repos ", "r "] where text.lowercased().hasPrefix(prefix) {
            let rest = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        return nil
    }

    func repoRows(matching text: String) -> [Row] {
        if repos.isEmpty && mode == .repos {
            return [Row(id: "repos-empty", title: isLoading ? "Looking in ~/Documents/GitHub\u{2026}" : "No git repos in ~/Documents/GitHub",
                        icon: .symbol("folder"))]
        }
        return Ranking.rank(repos, query: text, name: \.name, key: { "repo:" + $0.url.path }, usage: usage, limit: 60).map { repo in
            let ide = ide(for: repo)
            return Row(id: "repo:" + repo.url.path, title: repo.name, subtitle: repoStatus[repo.url]?.summary,
                       icon: .symbol("folder.fill", .systemBlue), accessory: ide.rawValue,
                       actionName: "Show Actions") { [unowned self] in enter(.repo(repo)) }
        }
    }

    func repoActionRows(_ repo: Repo) -> [Row] {
        let preferred = ide(for: repo)
        let path = repo.url.path
        var out: [Row] = [
            Row(id: "open-ide", title: "Open in \(preferred.rawValue)", icon: .symbol("chevron.left.forwardslash.chevron.right"),
                actionName: "Open") { [unowned self] in openWith(preferred.rawValue, repo.url) },
        ]
        if preferred != .vscode {
            out.append(Row(id: "open-vscode", title: "Open in Visual Studio Code", icon: .symbol("chevron.left.forwardslash.chevron.right"),
                           actionName: "Open") { [unowned self] in openWith("Visual Studio Code", repo.url) })
        }
        out += [
            Row(id: "open-term", title: "Open in WezTerm", subtitle: "A new window in the repo folder", icon: .symbol("terminal"),
                actionName: "Open") { [unowned self] in openTerminal(at: repo.url) },
            Row(id: "open-ghd", title: "Open in GitHub Desktop", icon: .symbol("arrow.triangle.branch"),
                actionName: "Open") { [unowned self] in openWith("GitHub Desktop", repo.url) },
            Row(id: "finder", title: "Show in Finder", icon: .symbol("folder"), actionName: "Show") { [unowned self] in
                hide()
                NSWorkspace.shared.activateFileViewerSelecting([repo.url])
            },
        ]
        if let web = repoStatus[repo.url]?.webURL {
            out.append(Row(id: "web", title: "Open on GitHub", subtitle: web.absoluteString, icon: .symbol("globe"),
                           actionName: "Open") { [unowned self] in open(web) })
        }
        out.append(Row(id: "copy-path", title: "Copy Path", subtitle: path, icon: .symbol("doc.on.doc"),
                       actionName: "Copy") { [unowned self] in copyAndClose(path) })
        return out.filter { query.isEmpty || FuzzyMatcher.score(query, in: $0.title) != nil }
    }

    func loadRepos() {
        repos = Repos.scan()
        isLoading = true
        refresh()
        Task {
            defer { isLoading = false }
            // Up to 8 git processes at a time; the list fills in as they answer.
            await withTaskGroup(of: (URL, RepoStatus?).self) { group in
                var pending = repos.makeIterator()
                func next() {
                    guard let repo = pending.next() else { return }
                    group.addTask { (repo.url, await Self.status(of: repo.url)) }
                }
                for _ in 0..<8 { next() }
                for await (url, status) in group {
                    if let status { repoStatus[url] = status }
                    if mode == .repos { refreshKeepingSelection() }
                    if case .repo(let open) = mode, open.url == url { refreshKeepingSelection() }
                    next()
                }
            }
        }
    }

    /// GIT_OPTIONAL_LOCKS=0 keeps `git status` from writing .git/index.lock,
    /// which in an iCloud-synced folder can be left behind.
    nonisolated static func status(of repo: URL) async -> RepoStatus? {
        let env = ["GIT_OPTIONAL_LOCKS": "0"]
        guard let out = try? await Shell.run("/usr/bin/git", ["-C", repo.path, "status", "--porcelain=v1", "--branch"], environment: env) else { return nil }
        var status = Repos.parseStatus(out)
        if let remote = try? await Shell.run("/usr/bin/git", ["-C", repo.path, "config", "--get", "remote.origin.url"], environment: env) {
            status.webURL = Repos.webURL(fromRemote: remote)
        }
        return status
    }

    private func ide(for repo: Repo) -> Repos.IDE {
        if let known = repoIDE[repo.url] { return known }
        let files = Set((try? FileManager.default.contentsOfDirectory(atPath: repo.url.path)) ?? [])
        let ide = Repos.preferredIDE(forFilesAt: files)
        repoIDE[repo.url] = ide
        return ide
    }

    private func openWith(_ appName: String, _ url: URL) {
        hide()
        guard let app = apps.first(where: { $0.name == appName })?.url else {
            message = "\(appName) isn\u{2019}t installed"
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// `wezterm start --cwd` opens a window in the running WezTerm, or starts it.
    private func openTerminal(at url: URL) {
        hide()
        let wezterm = "/Applications/WezTerm.app/Contents/MacOS/wezterm"
        guard FileManager.default.isExecutableFile(atPath: wezterm) else {
            NSWorkspace.shared.open([url], withApplicationAt: URL(filePath: "/System/Applications/Utilities/Terminal.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
            return
        }
        Task { _ = try? await Shell.run(wezterm, ["start", "--cwd", url.path]) }
    }

    // MARK: Ports

    func portRows(_ port: Int) -> [Row] {
        var matches = port == 0 ? ports : ports.filter { $0.port == port }
        if !query.isEmpty {
            matches = matches.filter { "\($0.port) \($0.command)".localizedCaseInsensitiveContains(query) }
        }
        if matches.isEmpty {
            let text = isLoading ? "Checking\u{2026}" : (port == 0 ? "Nothing is listening" : "Nothing is listening on port \(port)")
            return [Row(id: "ports-empty", title: text, icon: .symbol("network"))]
        }
        return matches.map { item in
            Row(id: "port:\(item.pid):\(item.port)", title: ":\(item.port)  \(item.command)",
                subtitle: "pid \(item.pid) \u{00B7} " + (item.isLocalOnly ? "this Mac only" : "reachable from the network (\(item.address))"),
                icon: .symbol("network", item.isLocalOnly ? nil : .systemOrange),
                actionName: "Show Actions") { [unowned self] in enter(.port(item)) }
        }
    }

    func portActionRows(_ item: ListeningPort) -> [Row] {
        let url = URL(string: "http://localhost:\(item.port)")!
        return [
            Row(id: "open", title: "Open localhost:\(item.port) in Browser", icon: .symbol("safari"), actionName: "Open") { [unowned self] in open(url) },
            Row(id: "quit", title: "Quit \(item.command)", subtitle: "Asks it to stop (SIGTERM)", icon: .symbol("stop.circle"),
                actionName: "Quit") { [unowned self] in signal(item, SIGTERM) },
            Row(id: "kill", title: "Force Quit \(item.command)", subtitle: "Stops it immediately (SIGKILL); unsaved work is lost",
                icon: .symbol("xmark.octagon", .systemRed), actionName: "Force Quit") { [unowned self] in signal(item, SIGKILL) },
            Row(id: "pid", title: "Copy PID", subtitle: String(item.pid), icon: .symbol("doc.on.doc"),
                actionName: "Copy") { [unowned self] in copyAndClose(String(item.pid)) },
        ]
    }

    func loadPorts() {
        isLoading = true
        refresh()
        Task {
            defer { isLoading = false; if case .ports = mode { refreshKeepingSelection() } }
            // lsof exits 1 when nothing matches; that's an empty list, not an error.
            let out = (try? await Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"])) ?? ""
            ports = Ports.parse(out)
        }
    }

    private func signal(_ item: ListeningPort, _ sig: Int32) {
        if kill(item.pid, sig) == 0 {
            let done = sig == SIGKILL ? "Force quit \(item.command) (pid \(item.pid))" : "Asked \(item.command) (pid \(item.pid)) to quit"
            enter(.ports(0)) // reloads the list
            message = done
        } else {
            message = errno == EPERM ? "\(item.command) belongs to another user; Hop can't stop it" : "Couldn\u{2019}t stop \(item.command)"
        }
    }
}
