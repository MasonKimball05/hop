import Foundation

/// A git repository in my projects folder.
public struct Repo: Hashable, Sendable {
    public let name: String
    public let url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}

/// What `git status` says about a repo, for the list's subtitle.
public struct RepoStatus: Hashable, Sendable {
    public var branch: String?
    public var changed = 0
    public var ahead = 0
    public var behind = 0
    /// The repo's page on GitHub, from its "origin" remote.
    public var webURL: URL?

    public init() {}

    public var summary: String {
        var parts = [branch ?? "detached"]
        if changed > 0 { parts.append("\(changed) changed") }
        if ahead > 0 { parts.append("\(ahead) to push") }
        if behind > 0 { parts.append("\(behind) to pull") }
        if changed == 0 && ahead == 0 && behind == 0 { parts.append("clean") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

public enum Repos {
    public static let defaultFolder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/GitHub")

    /// Folders directly inside `folder` that contain a .git entry.
    public static func scan(_ folder: URL = defaultFolder) -> [Repo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") }
            .map { folder.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: ".git").path) }
            .map { Repo(name: $0.lastPathComponent, url: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Parses `git status --porcelain=v1 --branch`.
    public static func parseStatus(_ output: String) -> RepoStatus {
        var status = RepoStatus()
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("## ") {
                // "## main...origin/main [ahead 2, behind 1]", "## No commits yet on main", "## HEAD (no branch)"
                var header = String(line.dropFirst(3))
                if header.hasPrefix("No commits yet on ") { header = String(header.dropFirst("No commits yet on ".count)) }
                let branchPart = header.split(separator: " ").first.map(String.init) ?? header
                let branch = branchPart.components(separatedBy: "...").first ?? branchPart
                status.branch = branch == "HEAD" ? nil : branch
                if let bracket = header.range(of: "[") {
                    let inside = header[bracket.upperBound...].replacingOccurrences(of: "]", with: "")
                    for part in inside.split(separator: ",") {
                        let words = part.trimmingCharacters(in: .whitespaces).split(separator: " ")
                        guard words.count == 2, let n = Int(words[1]) else { continue }
                        if words[0] == "ahead" { status.ahead = n }
                        if words[0] == "behind" { status.behind = n }
                    }
                }
            } else {
                status.changed += 1
            }
        }
        return status
    }

    /// "git@github.com:me/repo.git" or "https://github.com/me/repo.git" -> https://github.com/me/repo
    public static func webURL(fromRemote remote: String) -> URL? {
        var r = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.hasSuffix(".git") { r = String(r.dropLast(4)) }
        if r.hasPrefix("git@") {
            // git@host:owner/repo
            let rest = r.dropFirst(4)
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            r = "https://" + rest[..<colon] + "/" + rest[rest.index(after: colon)...]
        } else if r.hasPrefix("ssh://git@") {
            r = "https://" + r.dropFirst("ssh://git@".count)
        }
        guard let url = URL(string: r), url.scheme == "https", url.host() != nil else { return nil }
        return url
    }

    /// The IDE that suits a project, by the files at its top level.
    public enum IDE: String, CaseIterable, Sendable {
        case xcode = "Xcode"
        case goland = "GoLand"
        case pycharm = "PyCharm"
        case intellij = "IntelliJ IDEA"
        case vscode = "Visual Studio Code"
    }

    public static func preferredIDE(forFilesAt names: Set<String>) -> IDE {
        if names.contains("Package.swift") || names.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            return .xcode
        }
        if names.contains("go.mod") { return .goland }
        if names.contains("manage.py") || names.contains("pyproject.toml") || names.contains("requirements.txt") || names.contains("setup.py") {
            return .pycharm
        }
        if names.contains("pom.xml") || names.contains("build.gradle") || names.contains("build.gradle.kts") {
            return .intellij
        }
        return .vscode
    }
}
