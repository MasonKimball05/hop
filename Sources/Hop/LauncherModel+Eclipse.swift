import AppKit
import HopCore

// Eclipse, my browser: its tabs, Spaces, history and the pages it has indexed, read
// from its session.json and pages.db; switching and closing tabs through EclipseControl.
extension LauncherModel {
    /// Reads Eclipse's session in the background when it has changed since the last
    /// read (Eclipse saves it half a second after any change).
    func loadEclipse() {
        let file = Eclipse.folder.appending(path: "session.json")
        guard let saved = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              saved != eclipseSaved else { return }
        eclipseSaved = saved
        Task {
            let session = await Task.detached { (try? Data(contentsOf: file)).flatMap(Eclipse.session(from:)) }.value
            guard let session else { return }
            eclipse = session
            if mode == .search { refreshKeepingSelection() }
        }
    }

    /// Eclipse's session now, read straight from disk when the launcher hasn't yet (a
    /// focus started from a hop:// link).
    var eclipseSession: Eclipse.Session? {
        eclipse ?? (try? Data(contentsOf: Eclipse.folder.appending(path: "session.json"))).flatMap(Eclipse.session(from:))
    }

    /// The Space a focus session moves Eclipse to, and the one to return to; nil when
    /// Eclipse isn't running (a timer doesn't open the browser) or there's none to use.
    func focusSpace(for label: String?) -> (name: String, returnTo: String?)? {
        guard EclipseControl.isRunning, let session = eclipseSession,
              let name = Eclipse.focusSpace(label: label, setting: UserDefaults.standard.string(forKey: "focusSpace") ?? "",
                                            spaces: session.spaces) else { return nil }
        return (name, session.activeSpace == name ? nil : session.activeSpace)
    }

    /// For the main search: "tab …", "space …", "h …" and "page …", and otherwise a few
    /// tabs and Spaces whose names match what's typed.
    func eclipseRows(for text: String) -> (leading: [Row], trailing: [Row]) {
        guard let session = eclipse else { return ([], []) }
        if let query = Eclipse.tabQuery(text) {
            let tabs = Eclipse.tabs(matching: query, in: session)
            return (tabs.isEmpty ? [status("No Eclipse tabs match \u{201C}\(query)\u{201D}")] : tabs.prefix(60).map(tabRow), [])
        }
        if let query = Eclipse.spaceQuery(text) {
            let spaces = session.spaces.filter { query.isEmpty || $0.name.lowercased().contains(query.lowercased()) }
            return (spaces.map { spaceRow($0, in: session) }, [])
        }
        if let query = Eclipse.historyQuery(text) {
            let visits = Eclipse.history(matching: query, in: session)
            return (visits.isEmpty ? [status("Nothing in Eclipse\u{2019}s history matches \u{201C}\(query)\u{201D}")] : visits.map(visitRow), [])
        }
        if let query = Eclipse.archiveQuery(text) {
            let tabs = Eclipse.archived(matching: query, in: session)
            return (tabs.isEmpty ? [status(session.archived.isEmpty ? "Eclipse hasn\u{2019}t archived any tabs"
                                                                    : "No archived tab matches \u{201C}\(query)\u{201D}")]
                                 : tabs.prefix(60).map(archivedRow), [])
        }
        if let query = Eclipse.noteQuery(text) {
            let notes = Eclipse.notes(matching: query, in: Eclipse.notes())
            return (notes.isEmpty ? [status(query.isEmpty ? "No Eclipse notes yet" : "No Eclipse note mentions \u{201C}\(query)\u{201D}")]
                                  : notes.prefix(40).map(noteRow), [])
        }
        if let query = Eclipse.pageQuery(text) {
            if pageHits.isEmpty {
                return ([status(pageSearching ? "Searching pages you\u{2019}ve read\u{2026}"
                                              : "No page you\u{2019}ve read in Eclipse mentions \u{201C}\(query)\u{201D}")], [])
            }
            return (pageHits.map(pageRow), [])
        }
        // Plain typing: a few matching tabs and Spaces after apps and commands.
        guard text.count >= 3 else { return ([], []) }
        let tabs = Eclipse.tabs(matching: text, in: session).prefix(3).map(tabRow)
        let spaces = session.spaces.filter { $0.name.lowercased().hasPrefix(text.lowercased()) }.map { spaceRow($0, in: session) }
        return ([], spaces + tabs)
    }

    /// Starts (or stops) the search of page text when the query is "page …".
    func searchPagesIfAsked() {
        guard mode == .search, eclipse != nil, let text = Eclipse.pageQuery(query) else {
            pageQuery = nil
            pageHits = []
            return
        }
        guard text != pageQuery else { return }
        pageQuery = text
        pageSearching = true
        Task {
            try? await Task.sleep(for: .milliseconds(150)) // let typing pause
            guard pageQuery == text else { return }
            let hits = await Task.detached { Eclipse.searchPages(text) }.value
            guard pageQuery == text else { return }
            pageHits = hits
            pageSearching = false
            refreshKeepingSelection()
        }
    }

    // MARK: Rows

    private func tabRow(_ tab: Eclipse.Tab) -> Row {
        Row(id: "eclipse-tab:" + tab.id, title: tab.title, subtitle: "\(tab.space ?? "Favorites") \u{00B7} \(tab.host)",
            icon: favicon(tab.host), accessory: "Eclipse", actionName: "Switch to Tab",
            action: { [unowned self] in
                hide()
                EclipseControl.focus(tab)
            },
            actions: [
                RowAction(title: "Copy Link", symbol: "link") { [unowned self] in copyAndClose(tab.url) },
                RowAction(title: "Close Tab", symbol: "xmark.circle") { [unowned self] in
                    hide()
                    EclipseControl.close(tab)
                },
            ])
    }

    private func spaceRow(_ space: Eclipse.Space, in session: Eclipse.Session) -> Row {
        let count = session.tabs.filter { $0.space == space.name }.count
        // An emoji icon goes in the title; Eclipse's named icons have no match here.
        let emoji = space.icon.flatMap { $0.unicodeScalars.first?.properties.isEmojiPresentation == true || $0.count == 1 ? $0 : nil }
        return Row(id: "eclipse-space:" + space.id, title: [emoji, space.name].compactMap { $0 }.joined(separator: " "),
                   subtitle: "Space in Eclipse \u{00B7} \(count) tab\(count == 1 ? "" : "s")",
                   icon: .symbol("square.stack.3d.up", .systemPurple), accessory: "Eclipse", actionName: "Switch to Space") { [unowned self] in
            hide()
            if let link = Eclipse.spaceLink(space.name) { EclipseControl.open(link) }
        }
    }

    private func visitRow(_ visit: Eclipse.Visit) -> Row {
        let host = URL(string: visit.url)?.host() ?? visit.url
        return Row(id: "eclipse-visit:" + visit.url, title: visit.title, subtitle: "\(host) \u{00B7} \(Self.relative(visit.date))",
                   icon: favicon(host), accessory: "History", actionName: "Open in Eclipse",
                   action: { [unowned self] in openInEclipse(visit.url) },
                   actions: [RowAction(title: "Copy Link", symbol: "link") { [unowned self] in copyAndClose(visit.url) }])
    }

    private func pageRow(_ hit: Eclipse.PageHit) -> Row {
        let host = URL(string: hit.url)?.host() ?? hit.url
        return Row(id: "eclipse-page:" + hit.url, title: hit.title, subtitle: hit.snippet,
                   icon: favicon(host), accessory: host, actionName: "Open in Eclipse",
                   action: { [unowned self] in openInEclipse(hit.url) },
                   actions: [RowAction(title: "Copy Link", symbol: "link") { [unowned self] in copyAndClose(hit.url) }])
    }

    private func archivedRow(_ tab: Eclipse.Archived) -> Row {
        let host = URL(string: tab.url)?.host() ?? tab.url
        return Row(id: "eclipse-archived:" + tab.url, title: tab.title,
                   subtitle: "\(tab.space.map { "\($0) \u{00B7} " } ?? "")archived \(Self.relative(tab.date)) \u{00B7} \(host)",
                   icon: favicon(host), accessory: "Archived", actionName: "Bring Back",
                   action: { [unowned self] in
                       hide()
                       if let link = Eclipse.openLink(tab.url, space: tab.space) { EclipseControl.open(link) }
                   },
                   actions: [RowAction(title: "Copy Link", symbol: "link") { [unowned self] in copyAndClose(tab.url) }])
    }

    private func noteRow(_ note: Eclipse.Note) -> Row {
        let body = note.text.split(whereSeparator: \.isNewline).dropFirst().joined(separator: " ")
        let file = Eclipse.folder.appending(path: "notes/\(note.id).md")
        return Row(id: "eclipse-note:" + note.id, title: note.title,
                   subtitle: [Self.relative(note.modified), body.isEmpty ? nil : String(body.prefix(120))].compactMap { $0 }.joined(separator: " \u{00B7} "),
                   icon: .symbol("note.text", .systemYellow), accessory: "Eclipse Note", actionName: "Open in Eclipse",
                   action: { [unowned self] in
                       hide()
                       if let link = Eclipse.noteLink(note.id) { EclipseControl.open(link) }
                   },
                   actions: [
                       RowAction(title: "Copy Text", symbol: "doc.on.doc") { [unowned self] in copyAndClose(note.text) },
                       RowAction(title: "Open in Text Editor", symbol: "square.and.pencil") { [unowned self] in open(file) },
                   ])
    }

    private func status(_ text: String) -> Row {
        Row(id: "eclipse-status", title: text, icon: .symbol("safari"))
    }

    private func openInEclipse(_ page: String) {
        hide()
        if let link = Eclipse.openLink(page) { EclipseControl.open(link) } else if let url = URL(string: page) { NSWorkspace.shared.open(url) }
    }

    /// The site's icon as Eclipse saved it, else a globe.
    private func favicon(_ host: String) -> Icon {
        let file = Eclipse.folder.appending(path: "favicons/\(host).png")
        return FileManager.default.fileExists(atPath: file.path) ? .image(file) : .symbol("globe")
    }
}
