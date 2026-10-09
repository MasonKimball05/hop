import Foundation

/// Decides when Ask Claude's watch mode shows Claude the screen again: once it has
/// stopped changing (not mid-scroll) and differs from what Claude last saw, either
/// in its text (the next question) or in most of its pixels (another app, a picture).
///
/// Pixels are compared on small grayscale thumbnails (`width` × `height` bytes, one per
/// pixel); text is the lines Vision reads from the window.
public struct ScreenWatch: Sendable {
    public static let width = 160
    public static let height = 100

    /// How far a pixel's brightness (0–255) must move to count as changed.
    static let pixelTolerance = 16
    /// Under this share of pixels changing between two looks, the screen has settled.
    /// Typing or a blinking cursor stays under it; scrolling doesn't.
    static let settledBelow = 0.01
    /// Any change at all since the last check: worth reading the text again.
    static let recheckAbove = 0.0015
    /// Mostly different pixels from what Claude saw: new, whatever the text says.
    static let redrawnAbove = 0.3

    private var lastSent: (thumbnail: [UInt8], lines: Set<String>)?
    private var previous: [UInt8]?
    private var lastChecked: [UInt8]?

    public init() {}

    /// Share of pixels that changed noticeably; 1 when the sizes differ.
    public static func changedFraction(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var changed = 0
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) > pixelTolerance { changed += 1 }
        return Double(changed) / Double(a.count)
    }

    /// Each line as lowercased words and numbers, so "Question 4:" and "question 4"
    /// match. Whole lines rather than loose words: "Question 5 of 10" is a new line even
    /// when "5" already appears elsewhere on the page.
    public static func lines(in text: [String]) -> Set<String> {
        Set(text.map { $0.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ") }.filter { !$0.isEmpty })
    }

    /// Step one, for each new thumbnail: true when the screen has settled on something
    /// not yet checked, so it's worth reading its text and calling `isNew`.
    public mutating func needsCheck(_ thumbnail: [UInt8]) -> Bool {
        defer { previous = thumbnail }
        guard lastSent != nil else { return true }
        guard let previous, Self.changedFraction(previous, thumbnail) < Self.settledBelow else { return false }
        if let lastChecked, Self.changedFraction(lastChecked, thumbnail) <= Self.recheckAbove { return false }
        lastChecked = thumbnail
        return true
    }

    /// Step two: whether this screen differs from the last one Claude saw. New text
    /// means a line went away and a different one appeared. A line that only grew or
    /// shrank (typing or deleting an answer) doesn't count, and neither do lines that
    /// only appeared (the answer box filling in).
    public func isNew(_ thumbnail: [UInt8], lines: Set<String>) -> Bool {
        guard let lastSent else { return true }
        if Self.changedFraction(lastSent.thumbnail, thumbnail) >= Self.redrawnAbove { return true }
        let gone = lastSent.lines.subtracting(lines)
        let appeared = lines.subtracting(lastSent.lines)
        func edited(_ a: String, _ b: String) -> Bool { a.hasPrefix(b) || b.hasPrefix(a) }
        let replaced = gone.filter { old in !appeared.contains { edited(old, $0) } }
        let added = appeared.filter { new in !gone.contains { edited(new, $0) } }
        return !replaced.isEmpty && !added.isEmpty
    }

    /// Records the screen Claude was just shown.
    public mutating func sent(_ thumbnail: [UInt8], lines: Set<String>) {
        lastSent = (thumbnail, lines)
        previous = thumbnail
        lastChecked = thumbnail
    }
}
