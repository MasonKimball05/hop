import Foundation

/// A repo's pull request and latest CI run for the current branch, from the `gh`
/// command (GitHub's CLI), shown in a repo's actions in the launcher.
public enum GitHubStatus {
    public enum Outcome: Equatable, Sendable {
        case passing, failing, running, none

        public var word: String {
            switch self {
            case .passing: "passing"
            case .failing: "failing"
            case .running: "running"
            case .none: "no checks"
            }
        }
    }

    public struct PullRequest: Equatable, Sendable {
        public let number: Int
        public let title: String
        public let url: String
        /// OPEN, MERGED or CLOSED.
        public let state: String
        public let checks: Outcome
        public let passed: Int
        public let total: Int
    }

    public struct Run: Equatable, Sendable {
        public let workflow: String
        public let outcome: Outcome
        public let url: String
        public let started: Date?
    }

    /// `gh pr view --json number,title,url,state,statusCheckRollup`
    public static func pullRequest(from json: Data) -> PullRequest? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let number = object["number"] as? Int, let title = object["title"] as? String,
              let url = object["url"] as? String else { return nil }
        let checks = object["statusCheckRollup"] as? [[String: Any]] ?? []
        let outcomes = checks.map(outcome)
        let overall: Outcome = outcomes.isEmpty ? .none
            : outcomes.contains(.failing) ? .failing
            : outcomes.contains(.running) ? .running : .passing
        return PullRequest(number: number, title: title, url: url, state: object["state"] as? String ?? "OPEN",
                           checks: overall, passed: outcomes.filter { $0 == .passing }.count, total: outcomes.count)
    }

    /// `gh run list --branch … --limit 1 --json workflowName,status,conclusion,url,createdAt`
    public static func latestRun(from json: Data) -> Run? {
        guard let runs = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]], let run = runs.first,
              let url = run["url"] as? String else { return nil }
        let started = (run["createdAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return Run(workflow: run["workflowName"] as? String ?? "CI", outcome: outcome(run), url: url, started: started)
    }

    /// One check or run: still going, or how it ended. A skipped or neutral check
    /// doesn't count against the rest.
    private static func outcome(_ item: [String: Any]) -> Outcome {
        let status = (item["status"] as? String ?? "").uppercased()
        if ["QUEUED", "IN_PROGRESS", "PENDING", "WAITING", "REQUESTED"].contains(status) { return .running }
        // Checks report "conclusion"; commit statuses report "state".
        let result = ((item["conclusion"] as? String) ?? (item["state"] as? String) ?? "").uppercased()
        switch result {
        case "SUCCESS", "NEUTRAL", "SKIPPED": return .passing
        case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR": return .failing
        case "PENDING", "EXPECTED", "": return .running
        default: return .none
        }
    }

    /// Where the `gh` command is; a GUI app doesn't get the shell's PATH.
    public static func locateGH(isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> URL? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first(where: isExecutable).map { URL(filePath: $0) }
    }
}
