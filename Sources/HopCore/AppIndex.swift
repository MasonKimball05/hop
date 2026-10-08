import Foundation

/// An installed app the launcher can open.
public struct AppEntry: Hashable, Sendable {
    public let name: String
    public let url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}

/// Finds installed apps by looking where macOS keeps them. A folder like
/// /Applications/Utilities is searched one level down; app bundles themselves
/// aren't opened (apps inside other apps are helpers, not things to launch).
public enum AppIndex {
    public static let defaultFolders: [URL] = [
        URL(filePath: "/Applications"),
        URL(filePath: "/System/Applications"),
        URL(filePath: "/System/Applications/Utilities"),
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications"),
    ]

    /// Apps that live outside the usual folders but people expect to find.
    static let extras = [URL(filePath: "/System/Library/CoreServices/Finder.app")]

    public static func scan(_ folders: [URL] = defaultFolders) -> [AppEntry] {
        var seen = Set<String>()
        var apps: [AppEntry] = []
        func add(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return }
            apps.append(AppEntry(name: displayName(url), url: url))
        }

        for folder in folders {
            for item in contents(folder) {
                if item.pathExtension == "app" {
                    add(item)
                } else if isFolder(item) {
                    for nested in contents(item) where nested.pathExtension == "app" { add(nested) }
                }
            }
        }
        for extra in extras where FileManager.default.fileExists(atPath: extra.path) { add(extra) }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The name Finder shows ("Visual Studio Code", not "Visual Studio Code.app").
    static func displayName(_ url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Dot-files are skipped by name. The `.skipsHiddenFiles` option isn't used:
    /// it also drops /Applications/Safari.app, which on recent macOS is a symlink
    /// into a system cryptex.
    private static func contents(_ folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.map { folder.appending(path: $0) }
    }

    private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
