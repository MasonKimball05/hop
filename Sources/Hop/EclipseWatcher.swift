import AppKit
import HopCore

/// Eclipse's news in the menu bar: a watched page that changed, and Live Folders with
/// items you haven't looked at. Checks once a minute whether Eclipse has saved its
/// session (one file date) and reads it only then.
@MainActor
final class EclipseWatcher {
    struct Update: Identifiable, Equatable {
        enum Kind: Equatable { case page, folder }
        let id: String
        let kind: Kind
        /// "Camera" or "3 new in COSC 470 Feed".
        let title: String
        /// The summary of the change, or the new items' titles.
        let detail: String
        let url: String
        /// What reading it marks as read: a page change's time, or a folder's item addresses.
        fileprivate let changed: Date?
        fileprivate let items: [String]
    }

    private(set) var updates: [Update] = [] {
        didSet { if updates != oldValue { onChange(updates) } }
    }

    var onChange: ([Update]) -> Void = { _ in }

    var isOn = UserDefaults.standard.object(forKey: "eclipseUpdates") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isOn, forKey: "eclipseUpdates")
            if isOn { start() } else { stop() }
        }
    }

    private var timer: Timer?
    private var saved: Date?
    /// Per page watch, the change last shown or opened.
    private var seenChanges: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: "eclipseSeenChanges") as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "eclipseSeenChanges") }
    }
    /// Live Folder items opened from Hop (Eclipse marks them seen too, once it shows them).
    private var openedItems: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "eclipseOpenedItems") ?? []) }
        set { UserDefaults.standard.set(Array(newValue.suffix(500)), forKey: "eclipseOpenedItems") }
    }

    func start() {
        guard isOn, timer == nil else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        saved = nil
        updates = []
    }

    /// Opens an update in Eclipse and marks it read.
    func open(_ update: Update) {
        markRead(update)
        if let link = Eclipse.openLink(update.url) { EclipseControl.open(link) }
    }

    func markAllRead() {
        updates.forEach(markRead)
    }

    private func markRead(_ update: Update) {
        if let changed = update.changed { seenChanges[update.id] = changed.timeIntervalSince1970 }
        openedItems.formUnion(update.items)
        updates.removeAll { $0.id == update.id }
    }

    private func check() {
        let file = Eclipse.folder.appending(path: "session.json")
        guard let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              date != saved else { return }
        saved = date
        Task {
            guard let session = await Task.detached(operation: { (try? Data(contentsOf: file)).flatMap(Eclipse.session(from:)) }).value,
                  isOn else { return }
            update(from: session)
        }
    }

    private func update(from session: Eclipse.Session) {
        // First time: page changes from before Hop was watching aren't news.
        if UserDefaults.standard.dictionary(forKey: "eclipseSeenChanges") == nil {
            seenChanges = Dictionary(session.pageWatches.compactMap { watch in watch.changed.map { (watch.id, $0.timeIntervalSince1970) } },
                                     uniquingKeysWith: { first, _ in first })
        }
        let seen = seenChanges
        let opened = openedItems
        let pages = session.pageWatches.compactMap { watch -> Update? in
            guard !watch.paused, let changed = watch.changed, changed.timeIntervalSince1970 > (seen[watch.id] ?? 0) else { return nil }
            return Update(id: watch.id, kind: .page, title: watch.title,
                          detail: watch.summary.isEmpty ? "Changed \(LauncherModel.relative(changed))" : watch.summary,
                          url: watch.url, changed: changed, items: [])
        }
        let folders = session.liveFolders.compactMap { folder -> Update? in
            let new = folder.new.filter { !opened.contains($0.url) }
            guard let first = new.first else { return nil }
            return Update(id: "folder:" + folder.id, kind: .folder, title: "\(new.count) new in \(folder.name)",
                          detail: new.prefix(3).map(\.title).joined(separator: " \u{00B7} "), url: first.url, changed: nil,
                          items: new.map(\.url))
        }
        let fresh = (pages + folders).filter { next in !updates.contains { $0.id == next.id && $0.title == next.title } }
        updates = pages + folders
        // A note for what's new since the last check (not on Hop's own first look).
        if hasLooked, let first = fresh.first {
            let more = fresh.count > 1 ? " (+\(fresh.count - 1) more)" : ""
            Toast.show("Eclipse: \(first.title): \(ClaudeCLI.selectionPreview(first.detail, length: 50))\(more)",
                       symbol: first.kind == .page ? "eye" : "folder.badge.plus")
        }
        hasLooked = true
    }

    /// After the first check, new updates get a note on screen.
    private var hasLooked = false
}
