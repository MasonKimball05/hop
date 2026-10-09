import Foundation
import HopCore

/// Runs file-name searches against Spotlight's index, for `f …` in the launcher. A
/// new search replaces the one before it, and typing is given a moment to pause first.
@MainActor
final class FileFinder {
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var progress: NSObjectProtocol?
    private var pending: Task<Void, Never>?

    func search(_ text: String, found: @escaping @MainActor ([FileSearch.Hit]) -> Void) {
        cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.start(text, found: found)
        }
    }

    func cancel() {
        pending?.cancel()
        for token in [observer, progress].compactMap({ $0 }) { NotificationCenter.default.removeObserver(token) }
        observer = nil
        progress = nil
        query?.stop()
        query = nil
    }

    private func start(_ text: String, found: @escaping @MainActor ([FileSearch.Hit]) -> Void) {
        let query = NSMetadataQuery()
        // The words go in as arguments, never into the format string.
        let words = FileSearch.namePatterns(text).map { NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, $0) }
        guard !words.isEmpty else { return }
        // Spotlight throws (and takes Hop down) on an AND of just one condition.
        query.predicate = words.count == 1 ? words[0] : NSCompoundPredicate(andPredicateWithSubpredicates: words)
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]
        // Common words match thousands of files and Spotlight takes seconds to gather
        // them all; a thousand is plenty to rank (under a second), so it stops there.
        progress = NotificationCenter.default.addObserver(forName: .NSMetadataQueryGatheringProgress, object: query, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let query = self.query, query.resultCount >= Self.enough else { return }
                self.finish(text, found: found)
            }
        }
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(text, found: found) }
        }
        self.query = query
        query.start()
    }

    private static let enough = 1000

    private func finish(_ text: String, found: @MainActor ([FileSearch.Hit]) -> Void) {
        guard let query else { return }
        query.disableUpdates()
        var hits: [FileSearch.Hit] = []
        for index in 0..<min(query.resultCount, Self.enough) {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let name = item.value(forAttribute: NSMetadataItemFSNameKey) as? String ?? (path as NSString).lastPathComponent
            hits.append(FileSearch.Hit(name: name, path: path, lastUsed: item.value(forAttribute: "kMDItemLastUsedDate") as? Date))
        }
        cancel()
        found(FileSearch.rank(hits, query: text))
    }
}
