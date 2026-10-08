import Foundation

// Clients for my own services, reached from Hop's commands.

/// homebase, the process supervisor on my desktop (github.com/MasonKimball05/homebase).
public struct HomebaseClient: Sendable {
    public struct App: Decodable, Identifiable, Hashable, Sendable {
        public let name: String
        public let title: String
        public let state: String
        public let message: String?
        public let restarts: Int
        public let url: String?

        public var id: String { name }
        public var displayName: String { title.isEmpty ? name : title }
        public var isRunning: Bool { state == "running" || state == "external" }
    }

    public enum Action: String, Sendable, CaseIterable {
        case start, stop, restart
    }

    public let base: URL
    private let session: URLSession

    public init(base: URL, session: URLSession = .shared) {
        self.base = base
        self.session = session
    }

    public func apps() async throws -> [App] {
        struct Status: Decodable { let apps: [App] }
        var request = URLRequest(url: base.appending(path: "api/status"))
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        return try JSONDecoder().decode(Status.self, from: data).apps
    }

    public func perform(_ action: Action, on app: String) async throws {
        var request = URLRequest(url: base.appending(path: "api/apps/\(app)/\(action.rawValue)"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        // homebase only accepts actions carrying this header; browsers can't add it
        // to a cross-site request, which is what keeps other websites out.
        request.setValue("1", forHTTPHeaderField: "X-Homebase")
        let (_, response) = try await session.data(for: request)
        try Self.check(response)
    }

    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ServiceError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw ServiceError.status(http.statusCode) }
    }
}

/// The public site checkup from go-sentinel, running on Cloud Run.
public struct CheckupClient: Sendable {
    public struct Report: Decodable, Sendable {
        public struct Finding: Decodable, Hashable, Sendable {
            public let check: String
            public let status: String
            public let detail: String
            public let tip: String?
        }
        public let grade: String
        public let score: Int
        public let results: [Finding]
    }

    public static let defaultBase = URL(string: "https://checkup-1016486506373.us-central1.run.app")!

    public let base: URL
    private let session: URLSession

    public init(base: URL = defaultBase, session: URLSession = .shared) {
        self.base = base
        self.session = session
    }

    public func check(_ site: String) async throws -> Report {
        var components = URLComponents(url: base.appending(path: "api/check"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "url", value: site)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // The checkup explains rejections ("private and internal addresses can't be checked").
            struct Problem: Decodable { let error: String }
            if let problem = try? JSONDecoder().decode(Problem.self, from: data) {
                throw ServiceError.message(problem.error)
            }
            throw ServiceError.status(http.statusCode)
        }
        return try JSONDecoder().decode(Report.self, from: data)
    }

    /// "check example.com" -> "example.com". nil when the text isn't a check command.
    public static func site(fromCommand text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("check ") else { return nil }
        let site = trimmed.dropFirst("check ".count).trimmingCharacters(in: .whitespaces)
        return site.contains(".") && !site.contains(" ") ? site : nil
    }
}

public enum ServiceError: LocalizedError, Equatable {
    case badResponse
    case status(Int)
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .badResponse: "Unexpected response."
        case .status(let code): "The server returned HTTP \(code)."
        case .message(let text): text.prefix(1).uppercased() + text.dropFirst() + "."
        }
    }
}

/// Job Tracker on my desktop (github.com/MasonKimball05/job-tracker): its
/// read-only feed for Hop (/api/hop/...).
public struct JobTrackerClient: Sendable {
    public struct FollowUp: Decodable, Hashable, Sendable {
        public let id: Int
        public let company: String
        public let role: String
        public let status: String
        public let followUpOn: String // yyyy-MM-dd
        public let due: Bool
    }

    public struct Match: Decodable, Hashable, Sendable {
        public let id: Int
        public let company: String
        public let title: String
        public let location: String?
        public let remote: Bool
        public let score: Int
        public let verdict: String?
        public let url: String
    }

    public struct Application: Decodable, Hashable, Sendable {
        public let id: Int
        public let company: String
        public let role: String
        public let status: String
        public let matchScore: Int?
        public let followUpOn: String?
    }

    public static let defaultBase = URL(string: "http://arkans-pc1:5206")!

    public let base: URL
    private let session: URLSession

    public init(base: URL = defaultBase, session: URLSession = .shared) {
        self.base = base
        self.session = session
    }

    public func followUps() async throws -> [FollowUp] { try await get("api/hop/followups") }
    public func matches() async throws -> [Match] { try await get("api/hop/matches") }

    public func applications(matching query: String) async throws -> [Application] {
        try await get("api/hop/applications", query: [URLQueryItem(name: "q", value: query)])
    }

    /// The page for one application, e.g. http://arkans-pc1:5206/applications/12.
    public func page(for applicationID: Int) -> URL { base.appending(path: "applications/\(applicationID)") }

    /// The new-job form, with the posting link filled in when one is given.
    public func newJobPage(postingURL: String?) -> URL {
        var components = URLComponents(url: base.appending(path: "new"), resolvingAgainstBaseURL: false)!
        if let postingURL { components.queryItems = [URLQueryItem(name: "url", value: postingURL)] }
        return components.url!
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 6
        let (data, response) = try await session.data(for: request)
        try HomebaseClient.check(response)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// shelf, the media server on my desktop (github.com/MasonKimball05/shelf).
/// Search needs the same bearer token Media Player uses; playing goes through
/// Media Player itself, by opening a shelf:// link.
public struct ShelfSearchClient: Sendable {
    public struct File: Decodable, Hashable, Sendable {
        public let id: String
        public let root: String
        public let path: String
        public let name: String
        public let kind: String
        public let size: Int64
        public let position: Double?
        public let duration: Double?

        public var isVideo: Bool { kind == "video" }

        /// What Media Player plays: shelf://<id>/<name>, its stable form for a library item.
        public var itemURL: URL? {
            var components = URLComponents()
            components.scheme = "shelf"
            components.host = id
            components.path = "/" + name
            return components.url
        }
    }

    public static let defaultBase = URL(string: "http://arkans-pc1:8095")!

    public let base: URL
    let token: String
    private let session: URLSession

    public init(base: URL = defaultBase, token: String, session: URLSession = .shared) {
        self.base = base
        self.token = token
        self.session = session
    }

    public func search(_ query: String) async throws -> [File] {
        struct Results: Decodable { let results: [File] }
        var components = URLComponents(url: base.appending(path: "api/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 6
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 401 { throw ServiceError.message("the library rejected the token") }
        try HomebaseClient.check(response)
        return try JSONDecoder().decode(Results.self, from: data).results
    }
}
