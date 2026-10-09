import Foundation

/// Spots error messages in a terminal or IDE window's text (as Vision reads it), for
/// the error helper.
public enum ErrorScan {
    /// Apps worth watching: terminals, IDEs and code editors.
    public static func isDeveloperApp(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        let apps: Set<String> = [
            "com.apple.Terminal", "com.googlecode.iterm2", "com.github.wez.wezterm", "dev.warp.Warp-Stable",
            "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "com.apple.dt.Xcode",
            "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
        ]
        return apps.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.")
    }

    /// What error output looks like, across compilers, runtimes and shells. Each
    /// needs more than the bare word, so prose like "error handling" doesn't match.
    nonisolated(unsafe) private static let patterns: [Regex<AnyRegexOutput>] = [
        #"(?i)\berror(\[[A-Z]?\d+\])?:"#,                 // error: … / Error: … / error[E0308]:
        #"\b[A-Z]\w*(Error|Exception)\b(:|$)"#,           // TypeError: … / NullPointerException
        #"Traceback \(most recent call last\)"#,
        #"(?i)\b(fatal|panic):"#,
        #"npm ERR!"#,
        #"(?i)command not found"#,
        #"(?i)no such file or directory"#,
        #"(?i)segmentation fault"#,
        #"(?i)\bbuild failed\b"#,
        #"\bFAILED\b"#,
        #"(?i)\buncaught\b"#,
    ].compactMap {
        // Simple word boundaries: Unicode ones treat "java.lang.NullPointerException"
        // as one word, so \b never matches before the class name.
        try? Regex($0).wordBoundaryKind(.simple)
    }

    /// Indices of the lines that look like errors.
    public static func errorLines(_ lines: [String]) -> [Int] {
        lines.indices.filter { index in patterns.contains { lines[index].contains($0) } }
    }

    /// The error lines with some lines around them (what led up to it, the stack
    /// below), as one block to explain.
    public static func excerpt(_ lines: [String], errors: [Int], before: Int = 6, after: Int = 10) -> String {
        var keep = IndexSet()
        for index in errors {
            keep.insert(integersIn: max(0, index - before)..<min(lines.count, index + after + 1))
        }
        return keep.map { lines[$0] }.joined(separator: "\n")
    }

    /// Stays the same while the same error is on screen, so it's only flagged once.
    public static func signature(_ lines: [String], errors: [Int]) -> String {
        errors.map { lines[$0].lowercased().trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }

    public static func explainPrompt(_ excerpt: String, app: String?) -> String {
        """
        This error is showing in \(app ?? "my terminal") (the text was read off the screen, \
        so expect a few misread characters; the screenshot shows the window). Explain in \
        plain terms what went wrong and the most likely fix, with the exact change or \
        command if there is one.

        ```
        \(excerpt)
        ```
        """
    }
}
