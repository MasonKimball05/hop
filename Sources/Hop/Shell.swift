import Foundation

/// Runs a command-line tool off the main thread and returns what it printed.
enum Shell {
    struct Failure: Error {
        let status: Int32
        let output: String
    }

    static func run(_ tool: String, _ arguments: [String], in directory: URL? = nil,
                    environment: [String: String] = [:]) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: tool)
            process.arguments = arguments
            if let directory { process.currentDirectoryURL = directory }
            if !environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
            }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            // Read before waiting: a full pipe would otherwise block the tool forever.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0 else { throw Failure(status: process.terminationStatus, output: output) }
            return output
        }.value
    }
}
