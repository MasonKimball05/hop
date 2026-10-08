import Foundation

/// A process listening on a TCP port: a dev server, a database, an app's local API.
public struct ListeningPort: Hashable, Sendable {
    public let port: Int
    public let pid: Int32
    public let command: String
    public let address: String

    /// True when only this Mac can reach it (127.0.0.1 or ::1).
    public var isLocalOnly: Bool { address.hasPrefix("127.") || address == "[::1]" || address == "localhost" }
}

public enum Ports {
    /// Parses `lsof -nP -iTCP -sTCP:LISTEN -Fpcn`: lines starting with p (pid),
    /// c (command) and n (address:port), one p/c pair per process.
    public static func parse(_ output: String) -> [ListeningPort] {
        var pid: Int32 = 0
        var command = ""
        var seen = Set<String>()
        var ports: [ListeningPort] = []
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let address = String(value[..<colon])
                // The same process often listens on IPv4 and IPv6; list it once.
                guard seen.insert("\(pid):\(port)").inserted else { continue }
                ports.append(ListeningPort(port: port, pid: pid, command: command, address: address))
            default: break
            }
        }
        return ports.sorted { $0.port < $1.port }
    }

    /// "port 3000" -> 3000, "port" or "ports" -> 0 (meaning all). nil when not a port command.
    public static func query(fromCommand text: String) -> Int? {
        let words = text.lowercased().split(separator: " ")
        guard let first = words.first, first == "port" || first == "ports" else { return nil }
        if words.count == 1 { return 0 }
        guard words.count == 2, let port = Int(words[1]), (1...65535).contains(port) else { return nil }
        return port
    }
}
