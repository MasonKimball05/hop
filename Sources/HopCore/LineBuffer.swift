import Foundation

/// Turns chunks of a pipe's output into whole lines: a chunk can end partway through a
/// line, or partway through a UTF-8 character, so the rest waits for the next chunk.
public struct LineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    /// The lines completed by this chunk, without their newlines.
    public mutating func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending = Data(pending[pending.index(after: newline)...])
        }
        return lines
    }

    /// What's left when the output ends without a final newline.
    public mutating func finish() -> String? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }
}
