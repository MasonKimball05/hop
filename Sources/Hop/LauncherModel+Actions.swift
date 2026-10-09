import AppKit
import HopCore

// ⌘K actions on the selected row, and file search ("f syllabus").
extension LauncherModel {
    // MARK: ⌘K

    /// Everything the selected row can do: what Return does first, then the rest.
    var selectedActions: [RowAction] {
        guard let row = selectedRow else { return [] }
        var out: [RowAction] = []
        if let action = row.action, !row.actionName.isEmpty {
            out.append(RowAction(title: row.actionName, symbol: "return", run: action))
        }
        out += row.actions
        if let delete = row.delete {
            out.append(RowAction(title: "Delete", symbol: "trash") { [unowned self] in
                delete()
                refresh()
            })
        }
        return out
    }

    func toggleActions() {
        guard !actionsShown else { return closeActions() }
        guard selectedActions.count > 1 else { return }
        actionSelection = 0
        actionsShown = true
    }

    func closeActions() {
        actionsShown = false
    }

    func moveActionSelection(_ delta: Int) {
        let count = selectedActions.count
        guard count > 0 else { return }
        actionSelection = min(max(actionSelection + delta, 0), count - 1)
    }

    func performAction(at index: Int? = nil) {
        let actions = selectedActions
        let index = index ?? actionSelection
        guard actions.indices.contains(index) else { return }
        closeActions()
        if index == 0, let row = selectedRow, let key = usageKey(row) { record(key) }
        actions[index].run()
    }

    // MARK: Actions for each kind of row

    func fileActions(_ url: URL) -> [RowAction] {
        [
            RowAction(title: "Show in Finder", symbol: "folder") { [unowned self] in
                hide()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
            RowAction(title: "Ask Claude About It", symbol: "sparkles") { [unowned self] in
                hide()
                askAboutFile(url)
            },
            RowAction(title: "Copy File", symbol: "doc.on.doc") { [unowned self] in
                // As a file, to paste into Finder, Mail or Messages.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
                hide()
            },
            RowAction(title: "Copy Path", symbol: "link") { [unowned self] in copyAndClose(url.path) },
        ]
    }

    func appActions(_ url: URL) -> [RowAction] {
        var out = [
            RowAction(title: "Show in Finder", symbol: "folder") { [unowned self] in
                hide()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
        ]
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL == url }
        if !running.isEmpty {
            out.append(RowAction(title: "Quit", symbol: "xmark.circle") { [unowned self] in
                running.forEach { $0.terminate() }
                hide()
            })
            out.append(RowAction(title: "Force Quit", symbol: "exclamationmark.octagon") { [unowned self] in
                running.forEach { $0.forceTerminate() }
                hide()
            })
        }
        out.append(RowAction(title: "Copy Path", symbol: "link") { [unowned self] in copyAndClose(url.path) })
        return out
    }

    /// Copy, plus Claude rewriting it (the result opens in Ask Claude, to paste).
    func textActions(_ text: String) -> [RowAction] {
        [RowAction(title: "Copy", symbol: "doc.on.doc") { [unowned self] in copyAndClose(text) }]
            + ClaudeCLI.Rewrite.allCases.map { kind in
                RowAction(title: kind.title, symbol: kind.symbol, isClaude: true) { [unowned self] in
                    hide()
                    rewrite(kind, text)
                }
            }
    }

    // MARK: File search

    /// Starts (or stops) a Spotlight search when the query is "f …".
    func searchFilesIfAsked() {
        guard mode == .search, let text = FileSearch.query(fromCommand: query.trimmingCharacters(in: .whitespaces)) else {
            finder.cancel()
            fileQuery = nil
            return
        }
        guard text != fileQuery else { return }
        fileQuery = text
        fileSearching = true
        finder.search(text) { [weak self] hits in
            guard let self, fileQuery == text else { return }
            fileHits = hits
            fileSearching = false
            refreshKeepingSelection()
        }
    }

    func fileRows() -> [Row] {
        guard let text = fileQuery else { return [] }
        if fileHits.isEmpty {
            let title = fileSearching ? "Searching for \u{201C}\(text)\u{201D}\u{2026}" : "No files named like \u{201C}\(text)\u{201D}"
            return [Row(id: "files-status", title: title, subtitle: "Names in your home folder, from Spotlight", icon: .symbol("doc.text.magnifyingglass"))]
        }
        let home = NSHomeDirectory()
        return fileHits.map { hit in
            let url = URL(filePath: hit.path)
            let folder = url.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~")
            return Row(id: "file:" + hit.path, title: hit.name, subtitle: folder, icon: .app(url),
                       accessory: hit.lastUsed.map(Self.relative), actionName: "Open",
                       action: { [unowned self] in open(url) }, actions: fileActions(url))
        }
    }
}
